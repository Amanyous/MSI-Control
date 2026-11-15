import CoreAudio
import ECControl
import Foundation

/// Queries control properties only. No audio capture or modification is performed.
final class AudioMuteIndicatorSync: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.shenying.mute-indicators", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastStates: [Bool: Bool] = [:]
    private var sampleCount = 0

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.synchronize() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    private func synchronize() {
        // Reconcile periodically after wake/firmware changes, even if mute is unchanged.
        sampleCount += 1
        let reconcile = sampleCount % 10 == 0
        guard let bridge = try? ECBridgeConnection(), bridge.apiVersion >= 8 else { return }
        for microphone in [false, true] {
            guard let muted = Self.defaultDeviceMute(input: microphone) else {
                lastStates.removeValue(forKey: microphone)
                continue
            }
            guard reconcile || lastStates[microphone] != muted else { continue }
            do {
                try bridge.setMuteIndicator(microphone: microphone, muted: muted)
                lastStates[microphone] = muted
            } catch {
                // No authorization prompts or speculative fallback writes.
                lastStates.removeValue(forKey: microphone)
            }
        }
    }

    static func defaultDeviceMute(input: Bool) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr,
              size == MemoryLayout<UInt32>.size, muted <= 1 else { return nil }
        return muted != 0
    }
}
