import AppKit
import Combine
import KeyboardLighting
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class KeyboardLightingModel: ObservableObject {
    @Published var configuration: LightingConfiguration {
        didSet {
            guard configuration != oldValue, configuration.isValid else { return }
            configurationRevision += 1
            if configuration.effect != .off { lastEnabledEffect = configuration.effect }
            stopAnimation(message: nil)
            status = "参数已修改，点击应用后发送到键盘"
            if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.settingsKey) }
        }
    }
    @Published var selectedZone: Int?
    @Published private(set) var report: LightingReport?
    @Published private(set) var lastOperation: LightingReport?
    @Published private(set) var status = "请在目标 MSI 上刷新灯控接口"
    @Published private(set) var isBusy = false
    @Published private(set) var isAnimating = false
    @Published private(set) var lastSentDescription: String?
    @Published private(set) var successfulApplyCount = 0
    private let defaults: UserDefaults
    private let scanDevices: @Sendable () async -> LightingReport
    private let sendAction: @Sendable (LightingAction, UInt64) async -> LightingReport
    private static let settingsKey = "keyboardLighting.configuration.v2"
    private static let legacySettingsKey = "keyboardLighting.configuration.v1"
    private static let appliedSettingsKey = "keyboardLighting.lastApplied.v1"
    private var hasAttemptedStartupRestore = false
    private var configurationRevision = 0
    private var lastEnabledEffect: LightingEffect = .solid
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    // Animation transport bookkeeping must not invalidate the SwiftUI page.
    private var latestFrameReport: LightingReport?
    private var subscriptions: [AnyCancellable] = []

    init(
        defaults: UserDefaults = .standard,
        scanDevices: @escaping @Sendable () async -> LightingReport = {
            await Task.detached(priority: .userInitiated) { KeyboardHIDService.scan() }.value
        },
        sendAction: @escaping @Sendable (LightingAction, UInt64) async -> LightingReport = { action, deviceID in
            await Task.detached(priority: .userInitiated) { KeyboardHIDService.perform(action, expectedDeviceID: deviceID) }.value
        }
    ) {
        self.defaults = defaults
        self.scanDevices = scanDevices
        self.sendAction = sendAction
        if let current = defaults.data(forKey: Self.settingsKey) {
            configuration = LightingConfiguration.restore(from: current)
        } else {
            var legacy = LightingConfiguration.restore(from: defaults.data(forKey: Self.legacySettingsKey))
            // Upgrade the former default speed once, preserving custom periods.
            if legacy.period == 6 { legacy.period = 2 }
            configuration = legacy
            if let data = try? JSONEncoder().encode(legacy) { defaults.set(data, forKey: Self.settingsKey) }
        }
        if configuration.effect != .off { lastEnabledEffect = configuration.effect }
        // Startup restoration is explicit; constructing the model never writes HID.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.stopAnimation(message: "系统进入睡眠，动画已停止；唤醒后可重新应用") }
            }.store(in: &subscriptions)
    }

    deinit { operationTask?.cancel() }

    var canControl: Bool { !isBusy && report?.scan.error == nil && report?.scan.candidates.count == 1 }
    var canExport: Bool { !isBusy && (lastOperation != nil || report != nil) }
    var editorColor: LightingRGB {
        let zone = selectedZone ?? 0
        return configuration.colors.indices.contains(zone) ? configuration.colors[zone] : .defaultColor
    }

    var editorCGColor: Color { editorColor.displayColor }

    func setColor(_ color: LightingRGB) { configuration.setColor(color, zone: selectedZone) }

    func restoreAtStartup() async {
        guard !hasAttemptedStartupRestore else { return }
        hasAttemptedStartupRestore = true
        guard !isBusy, operationTask == nil,
              let data = defaults.data(forKey: Self.appliedSettingsKey),
              let settings = try? JSONDecoder().decode(LightingConfiguration.self, from: data),
              settings.isValid else { return }
        let revision = configurationRevision
        await refresh()
        guard !Task.isCancelled, configurationRevision == revision, canControl else { return }
        let action: LightingAction = settings.effect == .off || settings.brightness == 0
            ? .turnOff : .frame(colors: settings.frame(at: 0))
        start(action, settings: settings)
    }

    func refresh() async {
        guard !isBusy else { return }
        let pendingOperation = operationTask
        stopAnimation(message: nil)
        let id = UUID()
        operationID = id
        isBusy = true
        defer { isBusy = false }
        status = "正在读取灯控接口…"
        // Finish the current frame before scanning or accepting another write.
        await pendingOperation?.value
        guard operationID == id else { return }
        operationTask = nil
        report = await scanDevices()
        status = report?.scan.status ?? "接口读取失败"
    }

    func apply() {
        guard configuration.isValid else { status = "灯光参数无效，未发送报文"; return }
        let settings = configuration
        if settings.effect == .off || settings.brightness == 0 {
            start(.turnOff, settings: settings, notifyApply: true)
        } else {
            start(.frame(colors: settings.frame(at: 0)), settings: settings, notifyApply: true)
        }
    }

    func turnOff() {
        guard canControl else { return }
        configuration.effect = .off
        start(.turnOff, settings: configuration)
    }

    func turnOn() {
        guard canControl else { return }
        if configuration.effect == .off { configuration.effect = lastEnabledEffect }
        if configuration.brightness == 0 { configuration.brightness = 4 }
        apply()
    }

    func loadSaved() { start(.loadSaved, settings: nil) }

    func stopAnimation(message: String? = "动画已暂停，键盘保留最后发送的颜色") {
        guard isAnimating else { return }
        operationTask?.cancel()
        isAnimating = false
        if let latestFrameReport { lastOperation = latestFrameReport }
        if let message { status = message }
    }

    func cycleBrightness(delta: Int? = nil) async {
        guard !isBusy else { return }
        if report == nil { await refresh() }
        guard canControl else {
            ShortcutOSD.shared.show(symbol: "exclamationmark.triangle",
                                    title: t("osdKeyboardBrightness"), detail: "N/A")
            return
        }
        configuration.brightness = delta.map { min(4, max(0, configuration.brightness + $0)) }
            ?? ((configuration.brightness + 1) % 5)
        if configuration.effect == .off, configuration.brightness > 0 {
            configuration.effect = lastEnabledEffect
        }
        let settings = configuration
        start(settings.brightness == 0 ? .turnOff : .frame(colors: settings.frame(at: 0)),
              settings: settings, notifyBrightness: true)
    }

    private func start(_ initialAction: LightingAction, settings: LightingConfiguration?, notifyApply: Bool = false,
                       notifyBrightness: Bool = false) {
        guard canControl, let device = report?.scan.candidates.first else { return }
        let pendingOperation = operationTask
        pendingOperation?.cancel()
        let id = UUID()
        operationID = id
        let animated = settings.map { $0.effect.isAnimated && $0.brightness > 0 } ?? false
        isAnimating = animated
        isBusy = true
        latestFrameReport = nil
        status = "正在发送灯光设置…"
        operationTask = Task { [weak self] in
            // Cancelling a task cannot interrupt IOHIDDeviceSetReport. Waiting
            // here keeps replacement settings / off behind that full transaction.
            await pendingOperation?.value
            guard let self else { return }
            guard !Task.isCancelled, self.operationID == id else { return }
            // Keep user-requested HID animation active when the window is hidden,
            // without preventing idle system sleep.
            let activity = animated ? ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Streaming keyboard lighting animation"
            ) : nil
            defer {
                if let activity { ProcessInfo.processInfo.endActivity(activity) }
                if self.operationID == id {
                    if self.isBusy { self.isBusy = false }
                    if self.isAnimating { self.isAnimating = false }
                    self.operationTask = nil
                }
            }
            let started = ProcessInfo.processInfo.systemUptime
            let clock = ContinuousClock()
            var previousFrame: [LightingRGB]?
            var hasPublishedStart = false
            while !Task.isCancelled, self.operationID == id {
                let frameStarted = clock.now
                let colors = settings?.frame(at: ProcessInfo.processInfo.systemUptime - started)
                if previousFrame == nil || previousFrame != colors {
                    let action = animated ? LightingAction.frame(colors: colors ?? [], previous: previousFrame) : initialAction
                    let result = await self.sendAction(action, device.id)
                    guard self.operationID == id else { return }
                    self.latestFrameReport = result
                    guard result.result?.allReportsSent == true else {
                        self.report = result
                        self.lastOperation = result
                        self.status = result.result?.message ?? result.scan.status
                        return
                    }
                    previousFrame = colors
                    guard !Task.isCancelled else {
                        self.lastOperation = result
                        return
                    }
                    if !hasPublishedStart {
                        if notifyBrightness, let settings {
                            ShortcutOSD.shared.show(symbol: settings.brightness == 0 ? "light.min" : "light.max", title: t("osdKeyboardBrightness"),
                                                    detail: "\(settings.brightness)/4",
                                                    level: Double(settings.brightness) / 4,
                                                    state: settings.brightness > 0)
                        }
                        if let settings, let data = try? JSONEncoder().encode(settings) {
                            self.defaults.set(data, forKey: Self.appliedSettingsKey)
                        }
                        if notifyApply { self.successfulApplyCount += 1 }
                        self.report = result
                        self.lastOperation = result
                        self.isBusy = false
                        let name = settings.map { $0.brightness == 0 ? "关闭" : $0.effect.title } ?? initialAction.title
                        self.lastSentDescription = "\(name) · \(result.createdAt.formatted(date: .omitted, time: .standard))"
                        self.status = animated ? "\(name)运行中 · 应用需保持运行" : (result.result?.message ?? result.scan.status)
                        hasPublishedStart = true
                    }
                }
                guard animated, !Task.isCancelled else { return }
                // Target 30 fps including transport time. When HID is slower,
                // generate the current frame next; never queue missed frames.
                let delay = Duration.milliseconds(33) - frameStarted.duration(to: clock.now)
                if delay > .zero { try? await Task.sleep(for: delay) }
                else { await Task.yield() }
            }
        }
    }

    func exportDiagnostics() async {
        guard canExport else { return }
        let pendingOperation = operationTask
        stopAnimation()
        isBusy = true
        await pendingOperation?.value
        isBusy = false
        if let latestFrameReport { lastOperation = latestFrameReport }
        guard let report = lastOperation ?? report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "M-Control-Keyboard-Diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.json().write(to: url, options: .atomic)
            status = "诊断已导出（最近一次发送时的接口和结果）"
        } catch { status = "导出失败：\(error.localizedDescription)" }
    }
}

extension LightingRGB {
    var displayColor: Color { Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }
}
