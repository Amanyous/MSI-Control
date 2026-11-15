import AppKit
import SwiftUI
import ECControl

@MainActor
final class ShortcutOSD {
    static let shared = ShortcutOSD()
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    private var monitor: Timer?
    private var fnLockMonitor: Task<Void, Never>?
    private var previous: [String: Double] = [:]
    private let presentation = OSDPresentation()
    private var generation = 0

    func show(icon: String, text: String, progress: Double? = nil) {
        show(symbol: icon, title: text, detail: "", level: progress)
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: "mcontrol.shortcutOSD") as? Bool ?? true
    }

    func start() {
        guard monitor == nil else { return }
        sample()
        monitor = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { Self.shared.sample() }
        }
        fnLockMonitor = Task { @MainActor [weak self] in
            var previousLock: Bool?
            while !Task.isCancelled {
                let locked = await Task.detached(priority: .utility) { () -> Bool? in
                    guard let bridge = try? ECBridgeConnection(),
                          // This register mapping has only been verified on this firmware.
                          (try? bridge.firmware()) == "15P2EMS1.110",
                          let flags = try? bridge.readByte(at: 0xD9) else { return nil }
                    return flags & 0x02 != 0
                }.value
                guard !Task.isCancelled else { return }
                if let locked {
                    if let previousLock, previousLock != locked {
                        self?.show(symbol: locked ? "lock.fill" : "lock.open.fill", title: t("osdFnLock"),
                                   detail: t(locked ? "osdOn" : "osdOff"), state: locked)
                    }
                    previousLock = locked
                } else {
                    previousLock = nil
                }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
        }
    }

    func stop() {
        monitor?.invalidate()
        monitor = nil
        fnLockMonitor?.cancel()
        fnLockMonitor = nil
        dismissal?.cancel()
        panel?.orderOut(nil)
        previous.removeAll()
    }

    private func sample() {
        let caps = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        update("caps", value: caps ? 1 : 0,
               symbol: caps ? "capslock.fill" : "capslock", title: t("osdCaps"))
        if let locked = WindowsNumLock.lockState() {
            let value: Double = locked ? 1 : 0
            if let old = previous.updateValue(value, forKey: "numLock"), old != value {
                show(symbol: locked ? "osd.numlock" : "osd.numlock.slash", title: "Num Lock",
                     detail: t(locked ? "osdOn" : "osdOff"), state: locked)
            }
        } else {
            previous.removeValue(forKey: "numLock")
        }
        if let muted = AudioMuteIndicatorSync.defaultDeviceMute(input: false) {
            update("speaker", value: muted ? 1 : 0, symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                   title: t("osdSpeaker"))
        }
        if let muted = AudioMuteIndicatorSync.defaultDeviceMute(input: true) {
            update("mic", value: muted ? 1 : 0, symbol: muted ? "mic.slash.fill" : "mic.fill",
                   title: t("osdMicrophone"))
        }
        if !enabled {
            dismissal?.cancel()
            panel?.orderOut(nil)
        }
    }

    private func update(_ key: String, value: Double, symbol: String, title: String, isLevel: Bool = false) {
        let old = previous.updateValue(value, forKey: key)
        guard let old, old != value else { return }
        show(symbol: symbol, title: title,
             detail: isLevel ? "\(Int(value))%" : t(value == 1 ? "osdOn" : "osdOff"),
             level: isLevel ? value / 100 : nil)
    }

    func show(symbol: String, title: String, detail: String, level: Double? = nil, state: Bool? = nil) {
        guard enabled else { return }
        dismissal?.cancel()
        generation += 1
        let currentGeneration = generation
        let hud: NSPanel
        if let panel { hud = panel }
        else {
            hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 252, height: 96),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            hud.isOpaque = false
            hud.backgroundColor = .clear
            hud.hasShadow = false
            hud.hidesOnDeactivate = false
            hud.isFloatingPanel = true
            hud.ignoresMouseEvents = true
            hud.level = .statusBar
            hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel = hud
            hud.contentView = NSHostingView(rootView: OSDView(presentation: presentation)
                .environment(\.appearsActive, true))
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let wasVisible = hud.isVisible
        presentation.symbol = symbol
        presentation.title = title
        presentation.detail = detail
        presentation.level = level.map { min(1, max(0, $0)) }
        presentation.state = state
        presentation.width = 280
        // Keep the capsule above the Dock, including when the Dock is hidden.
        let bottomEdge = max(screen.visibleFrame.minY, screen.frame.minY + 72) + 24
        hud.setFrame(NSRect(x: screen.frame.midX - (presentation.width + 48) / 2,
                           y: bottomEdge - 28,
                           width: presentation.width + 48, height: 112), display: true)
        if !wasVisible {
            presentation.appeared = false
            hud.alphaValue = 0
        }
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            hud.animator().alphaValue = 1
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        dismissal = Task { @MainActor [weak self] in
            // Allow the hosting view to render the initial scale before springing in.
            if !wasVisible {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
            guard let self, self.generation == currentGeneration else { return }
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                          ? nil : .spring(response: 0.35, dampingFraction: 0.65)) {
                self.presentation.appeared = true
            }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard self.generation == currentGeneration else { return }
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                          ? nil : .spring(response: 0.35, dampingFraction: 0.65)) {
                self.presentation.appeared = false
            }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                self.panel?.animator().alphaValue = 0
            }
            if !Task.isCancelled, self.generation == currentGeneration {
                self.panel?.orderOut(nil)
            }
        }
    }

}

typealias OSDManager = ShortcutOSD

@MainActor
private final class OSDPresentation: ObservableObject {
    @Published var symbol = ""
    @Published var title = ""
    @Published var detail = ""
    @Published var level: Double?
    @Published var state: Bool?
    @Published var appeared = false
    @Published var width: CGFloat = 220
}

private struct OSDView: View {
    @ObservedObject var presentation: OSDPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if presentation.appeared {
                OSDCapsule(presentation: presentation)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            }
        }
            .frame(width: presentation.width + 48, height: 112)
            .accessibilityElement(children: .combine)
    }
}

private struct OSDCapsule: View {
    @ObservedObject var presentation: OSDPresentation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        surface
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: contrast == .increased
                                ? [Color.primary.opacity(0.65), Color.primary.opacity(0.65)]
                                : [.white.opacity(0.8), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            .fixedSize()
    }

    @ViewBuilder
    private var surface: some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        } else if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 24) {
                content
                    .glassEffect(.clear.tint(Color.cyan.opacity(0)).interactive(false),
                                 in: .rect(cornerRadius: 28))
            }
        } else {
            content.background {
                Capsule().fill(.ultraThinMaterial)
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            OSDIcon(symbol: presentation.symbol)
                .frame(width: 26)
            Text(presentation.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
            if !presentation.detail.isEmpty {
                Text(presentation.detail)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 28)
        .frame(width: 280, height: 56)
    }
}

private struct OSDIcon: View {
    let symbol: String

    var body: some View {
        ZStack {
            if symbol.hasPrefix("osd.bluetooth") {
                BluetoothMark()
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 23)
            } else {
                Image(systemName: symbol.hasPrefix("osd.numlock") ? "123.rectangle" : symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 21, weight: .medium))
            }
            if symbol.hasPrefix("osd."), symbol.hasSuffix(".slash") {
                Path { path in
                    path.move(to: CGPoint(x: 3, y: 2))
                    path.addLine(to: CGPoint(x: 23, y: 24))
                }
                .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
        }
        .frame(width: 26, height: 26)
        .foregroundStyle(Color(nsColor: .labelColor))
        .accessibilityHidden(true)
    }
}

private struct BluetoothMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.75))
        return path
    }
}

