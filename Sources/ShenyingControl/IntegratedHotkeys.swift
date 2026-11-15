import AppKit
import CoreAudio
@preconcurrency import CoreBluetooth
import ApplicationServices
import Combine
import ECControl

@MainActor
final class IntegratedHotkeys: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    static let shared = IntegratedHotkeys()
    @Published private(set) var inputAllowed = CGPreflightListenEventAccess()
    @Published private(set) var bluetoothAllowed = CBManager.authorization == .allowedAlways
    @Published private(set) var standaloneRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var lastPress = Date.distantPast
    private var central: CBCentralManager?
    private var pendingBluetooth = false
    private var switching = false
    private var switchingTouchpad = false
    weak var lighting: KeyboardLightingModel?
    private let bluetooth = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void
    private var getPower: Getter? {
        guard let bluetooth, let symbol = dlsym(bluetooth, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(symbol, to: Getter.self)
    }
    private var setPower: Setter? {
        guard let bluetooth, let symbol = dlsym(bluetooth, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
        return unsafeBitCast(symbol, to: Setter.self)
    }

    func start() {
        guard timer == nil else { return }
        _ = WindowsNumLock.apply(UserDefaults.standard.bool(forKey: WindowsNumLock.preference))
        ShortcutOSD.shared.start()
        installTap()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { Self.shared.installTap() }
        }
    }

    func stop() {
        ShortcutOSD.shared.stop()
        timer?.invalidate()
        timer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    func requestPermission() {
        _ = CGRequestListenEventAccess()
        if !CGPreflightListenEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
        installTap()
    }

    private func installTap() {
        inputAllowed = CGPreflightListenEventAccess()
        bluetoothAllowed = CBManager.authorization == .allowedAlways
        standaloneRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "local.msi.hotkeys").isEmpty
        guard tap == nil, CGPreflightListenEventAccess() else { return }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << 14),
            callback: { _, type, event, _ in
                MainActor.assumeIsolated {
                    let owner = IntegratedHotkeys.shared
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else if type.rawValue == 14, let cocoaEvent = NSEvent(cgEvent: event),
                              cocoaEvent.subtype.rawValue == 8 {
                        // NX_SYSDEFINED illumination events may replace Fn+F8 keyDown.
                        let data = cocoaEvent.data1
                        let key = (data >> 16) & 0xffff
                        let isDown = ((data >> 8) & 0xff) == 0x0a
                        if isDown, [21, 22, 23].contains(key) {
                            owner.receiveBacklight(delta: key == 21 ? 1 : key == 22 ? -1 : nil)
                        }
                    } else if type == .keyDown,
                              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        if HotkeyRouting.isBacklightKey(event.getIntegerValueField(.keyboardEventKeycode),
                                                       fnPressed: event.flags.contains(.maskSecondaryFn)),
                           !owner.standaloneRunning {
                            owner.receiveBacklight()
                        }
                        owner.receive(event.getIntegerValueField(.keyboardEventKeycode))
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
        if let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func receiveBacklight(delta: Int? = nil) {
        guard !standaloneRunning, Date().timeIntervalSince(lastPress) > 0.2 else { return }
        lastPress = Date()
        Task { @MainActor in await lighting?.cycleBrightness(delta: delta) }
    }

    func requestBluetoothPermission() {
        if CBManager.authorization == .notDetermined {
            if central == nil {
                central = CBCentralManager(delegate: self, queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
        } else if CBManager.authorization != .allowedAlways {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
        }
        bluetoothAllowed = CBManager.authorization == .allowedAlways
    }

    private func receive(_ key: Int64) {
        // The standalone app owns these events while it is running.
        guard HotkeyRouting.accepts(key: key, repeating: false,
            standaloneRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: "local.msi.hotkeys").isEmpty,
            elapsed: Date().timeIntervalSince(lastPress)) else { return }
        lastPress = Date()
        // Keep the event-tap callback short; actions may talk to system services.
        DispatchQueue.main.async {
            if key == 64 {
                self.toggleTouchpad()
            } else if key == 79 {
                self.toggleMicrophone()
            } else {
                self.toggleBluetooth()
            }
        }
    }

    private func toggleTouchpad() {
        guard !switchingTouchpad else { return }
        switchingTouchpad = true
        Task {
            defer { switchingTouchpad = false }
            do {
                let enabled = try await Task.detached {
                    let connection = try ECBridgeConnection()
                    let current = try connection.touchpadEnabled()
                    return try connection.touchpadEnabled(!current)
                }.value
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                ShortcutOSD.shared.show(symbol: "rectangle.and.hand.point.up.left",
                    title: "Touchpad", detail: enabled ? "On" : "Off", state: enabled)
            } catch {
                NSLog("MSI touchpad hotkey failed: %@", error.localizedDescription)
                ShortcutOSD.shared.show(symbol: "exclamationmark.triangle",
                    title: "Touchpad", detail: "Unable to switch")
            }
        }
    }

    private func feedback(_ message: String) {
        NSLog("MSI shortcuts: %@", message)
        let alert = NSAlert()
        alert.messageText = "MSI Control"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
    }

    private func toggleMicrophone() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return }
        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                  let value = uid?.takeRetainedValue(),
                  value as String == "com.ohmydsp.InternalMicrophone" else { continue }
            var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var muted: UInt32 = 0
            var muteSize: UInt32 = 4
            guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted) == noErr else { break }
            let target: UInt32 = muted == 0 ? 1 : 0
            var desired = target
            guard AudioObjectSetPropertyData(device, &muteAddress, 0, nil, 4, &desired) == noErr,
                  AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted) == noErr,
                  muted == target else { break }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return
        }
        feedback("Unable to change the digital microphone mute state.")
    }

    private func toggleBluetooth() {
        guard !switching else { return }
        switch CBManager.authorization {
        case .notDetermined:
            pendingBluetooth = true
            if central == nil {
                central = CBCentralManager(delegate: self, queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            return
        case .denied, .restricted:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
            return
        case .allowedAlways: break
        @unknown default: return
        }
        guard let getPower, let setPower else { feedback("Bluetooth power interface unavailable."); return }
        let old = getPower()
        guard old == 0 || old == 1 else { return }
        switching = true
        let target: Int32 = old == 0 ? 1 : 0
        setPower(target)
        checkBluetooth(target, attempts: 20)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothAllowed = CBManager.authorization == .allowedAlways
        guard pendingBluetooth else { return }
        if CBManager.authorization == .allowedAlways {
            pendingBluetooth = false
            toggleBluetooth()
        } else if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            pendingBluetooth = false
        }
    }

    private func checkBluetooth(_ target: Int32, attempts: Int) {
        if getPower?() == target {
            switching = false
            ShortcutOSD.shared.show(symbol: target == 1 ? "osd.bluetooth" : "osd.bluetooth.slash",
                                   title: t("osdBluetooth"), detail: t(target == 1 ? "osdOn" : "osdOff"),
                                   state: target == 1)
        } else if attempts == 0 {
            switching = false
            feedback("The system did not confirm the Bluetooth power change.")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.checkBluetooth(target, attempts: attempts - 1)
            }
        }
    }
}
