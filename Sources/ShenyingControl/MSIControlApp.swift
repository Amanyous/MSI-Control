import AppKit
import Combine
import ECControl
import IOKit
import IOKit.ps
import KeyboardLighting
import PowerServiceProtocol
import SwiftUI
import SystemSensors

@main
struct MSIControlApp: App {
    @NSApplicationDelegateAdaptor(ControlAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = MSIControlModel()
    @StateObject private var localization = AppLocalization.shared
    @AppStorage("mcontrol.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup("MSI Control", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1_080, minHeight: 720)
                .environmentObject(localization)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(t("about_msi_control_center")) {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "MSI Control"
                    ])
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(t("settings_da9fc8ba")) { navigate(to: .settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            SidebarCommands()
            CommandGroup(after: .toolbar) {
                Button(t("refresh_data")) { model.monitor.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                ForEach(Array(AppSection.mainSections.enumerated()), id: \.element.id) { index, section in
                    Button(section.title) { navigate(to: section) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            CommandGroup(after: .newItem) {
                Button(t("export_diagnostic_log")) { model.exportDiagnostics() }
                    .keyboardShortcut("e", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(t("msi_control_center_help")) { model.showHelp() }
            }
        }
    }

    private func navigate(to section: AppSection) {
        model.section = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class ControlAppDelegate: NSObject, NSApplicationDelegate {
    static var terminating = false
    static var powerChangeInProgress = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        IntegratedHotkeys.shared.start()
    }
    func applicationWillTerminate(_ notification: Notification) {
        IntegratedHotkeys.shared.stop()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.terminating else { return .terminateLater }
        Self.terminating = true
        Task { @MainActor in
            do {
                for _ in 0..<150 where Self.powerChangeInProgress {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !Self.powerChangeInProgress else {
                    throw ECError.unavailable("档位切换尚未结束，请稍后再退出")
                }
                try await Task.detached {
                    let bridge = try ECBridgeConnection()
                    guard bridge.apiVersion >= 13 else { return }
                    let status = try bridge.powerControlStatus()
                    if status.owned {
                        _ = try PerformanceAdministrator.apply(
                            nil, eco: false, expected: status, allowRegistration: false)
                    }
                }.value
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                Self.terminating = false
                let failure = NSAlert()
                failure.messageText = "未能确认恢复，已取消退出"
                failure.informativeText = error.localizedDescription
                failure.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, fan, lighting, battery, drivers, settings, about
    static let mainSections: [AppSection] = [.dashboard, .fan, .lighting, .battery, .drivers]
    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .dashboard: t("dashboard_title")
        case .fan: t("fan")
        case .lighting: t("lighting")
        case .battery: t("battery")
        case .drivers: t("drivers")
        case .settings: t("settings")
        case .about: t("about")
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .fan: "fanblades.fill"
        case .lighting: "keyboard"
        case .battery: "battery.75percent"
        case .drivers: "wrench.and.screwdriver"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

enum PerformanceMode: String, CaseIterable, Identifiable {
    case energySaving = "节能", quiet = "安静", balanced = "平衡", performance = "高性能", extreme = "极致"
    var cpuPreset: CPUPowerPreset { CPUPowerPreset(rawValue: Self.allCases.firstIndex(of: self)!)! }
    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .energySaving: AppLocalization.shared.resolvedLanguage == .chinese ? "节能" : "Energy Saving"
        case .quiet: t("quiet")
        case .balanced: t("balanced")
        case .performance: t("highPerformance")
        case .extreme: AppLocalization.shared.resolvedLanguage == .chinese ? "极致" : "Extreme"
        }
    }
    @MainActor var subtitle: String {
        switch self {
        case .energySaving: "25 / 35 W"
        case .quiet: t("quietSubtitle")
        case .balanced: t("balancedSubtitle")
        case .performance: t("performanceSubtitle")
        case .extreme: t("extremeSubtitle")
        }
    }
    @MainActor var localizedSubtitle: String {
        switch self {
        case .energySaving: "25 / 35 W"
        case .quiet: t("quietSubtitle")
        case .balanced: t("balancedSubtitle")
        case .performance: t("performanceSubtitle")
        case .extreme: t("extremeSubtitle")
        }
    }
    var symbol: String {
        switch self {
        case .energySaving: "leaf.fill"
        case .quiet: "leaf"
        case .balanced: "scalemass"
        case .performance: "gauge.with.dots.needle.67percent"
        case .extreme: "rocket.fill"
        }
    }
}

enum FanPreset: CaseIterable {
    case silent, balanced, performance, custom

    var title: String {
        switch self {
        case .silent: "静音"
        case .balanced: "均衡"
        case .performance: "性能"
        case .custom: "自定义"
        }
    }
    var speeds: [Double]? {
        switch self {
        case .silent: [20, 30, 40, 55, 75, 100]
        case .balanced: [35, 45, 55, 70, 85, 100]
        case .performance: [50, 60, 75, 85, 95, 100]
        case .custom: nil
        }
    }
}

struct CurvePoint: Identifiable, Equatable {
    let id: Int
    var temperature: Double
    var speed: Double
}

@MainActor
final class MSIControlModel: ObservableObject {
    private let audioMuteIndicators = AudioMuteIndicatorSync()
    @Published private(set) var successfulSettingsApplyCount = 0
    func showHelp() {
        let alert = NSAlert()
        alert.messageText = t("msi_control_center_help")
        alert.informativeText = t("check_ec_status_in_hardware_drivers_before_first_use_fan_control_and_c")
        alert.addButton(withTitle: t("ok"))
        alert.runModal()
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = t("export_diagnostic_log")
        panel.nameFieldStringValue = "msi-control-diagnostics.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = """
        MSI Control \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
        \(t("system")): \(ProcessInfo.processInfo.operatingSystemVersionString)
        \(t("EC 驱动")): \(t(monitor.ecStatus))
        \(t("ec_identity")): \(t(monitor.ecIdentity))
        OpenCore: \(monitor.openCoreVersion ?? "—")
        \(t("performance_mode")): \(t(performanceStatus))
        \(t("风扇控制")): \(t(fanModeStatus))
        """
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = t("unable_to_export_diagnostic_log")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: t("ok"))
            alert.runModal()
        }
    }
    @Published private var navigation = NavigationHistory<AppSection>(initial: .dashboard)
    var section: AppSection {
        get { navigation.current }
        set { navigation.visit(newValue) }
    }
    var canGoBack: Bool { navigation.canGoBack }
    var canGoForward: Bool { navigation.canGoForward }
    func goBack() { navigation.goBack() }
    func goForward() { navigation.goForward() }
    @Published var performanceMode: PerformanceMode?
    @Published private(set) var performanceBusy = false
    @Published private(set) var performanceStatus = "正在读取 EC 性能档…"
    private var powerControlState: CPUPowerControlStatus?
    @Published private(set) var ecoPreference = UserDefaults.standard.bool(forKey: "mcontrol.energySavingEC")
    var powerControlAvailable: Bool {
        powerControlState.map { $0.available && !$0.conflict } ?? false
    }
    var canRestorePower: Bool {
        powerControlState.map { $0.owned && $0.available } ?? false
    }
    private var powerStateObserver: NSObjectProtocol?
    private var powerRefreshTimer: Timer?
    private var startupPowerAttempted = false
    @Published private(set) var powerServiceReady = PerformanceAdministrator.serviceEnabled
    @Published private(set) var powerAuthorizationBusy = false
    @Published private(set) var powerAuthorizationError: String?

    func authorizePowerService() {
        guard !powerAuthorizationBusy else { return }
        powerAuthorizationBusy = true
        powerAuthorizationError = nil
        do { try PerformanceAdministrator.requestAuthorization() }
        catch {
            powerAuthorizationError = error.localizedDescription
        }
        powerServiceReady = PerformanceAdministrator.serviceEnabled
        powerAuthorizationBusy = false
    }

    init() {
        powerStateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.readPerformance() }
        }
        powerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readPerformance() }
        }
        readPerformance()
        Task { @MainActor [weak self] in
            do {
                try await Task.detached { try PerformanceAdministrator.updateApprovedService() }.value
            } catch {
                self?.powerAuthorizationError = error.localizedDescription
            }
            self?.readPerformance()
        }
    }
    @Published var curvePoints: [CurvePoint] = [
        CurvePoint(id: 0, temperature: 0, speed: 40), CurvePoint(id: 1, temperature: 50, speed: 45), CurvePoint(id: 2, temperature: 57, speed: 55), CurvePoint(id: 3, temperature: 64, speed: 65), CurvePoint(id: 4, temperature: 70, speed: 75), CurvePoint(id: 5, temperature: 76, speed: 90)
    ]
    @Published var gpuCurvePoints: [CurvePoint] = []
    @Published var selectedCurveFan = 0
    @Published var fixedFanSpeed = false
    @Published private var fanPresets: [FanPreset] = [.custom, .custom]
    private var isApplyingPreset = false
    private var pendingPreset: FanPreset?
    var currentPreset: FanPreset { fanPresets[selectedCurveFan] }
    var presetsEnabled: Bool { selectedFanMode == .advanced && loadedFanMode == .advanced }
    func markFanCustom() {
        guard !isApplyingPreset else { return }
        fanPresets[selectedCurveFan] = .custom
        curveDirty = true
    }
    func setFanAdjustmentMode(_ fixed: Bool) {
        guard fixedFanSpeed != fixed else { return }
        fixedFanSpeed = fixed
        markFanCustom()
        if fixed { setFixedSpeed(editableCurve.first?.speed ?? 40) }
    }
    @Published private var zeroRPMEnabled = [false, false]
    var editableCurve: [CurvePoint] {
        get { selectedCurveFan == 0 ? curvePoints : gpuCurvePoints }
        set {
            if selectedCurveFan == 0 { curvePoints = newValue } else { gpuCurvePoints = newValue }
            curveDirty = true
            markFanCustom()
        }
    }
    var zeroRPM: Bool {
        zeroRPMEnabled[selectedCurveFan]
    }
    func setZeroRPM(_ enabled: Bool) {
        zeroRPMEnabled[selectedCurveFan] = enabled
        editableCurve = editableCurve.map { point in
            var point = point
            if point.temperature < 45 { point.speed = enabled ? 0 : max(20, point.speed) }
            return point
        }
    }
    func setFixedSpeed(_ speed: Double) {
        zeroRPMEnabled[selectedCurveFan] = false
        editableCurve = editableCurve.map { point in
            var point = point
            point.speed = min(100, max(20, speed.rounded()))
            return point
        }
    }
    func setFanPreset(_ preset: FanPreset) {
        if selectedFanMode != .advanced {
            pendingPreset = preset
            applyFanMode(.advanced)
            return
        }
        guard preset != .custom else {
            fanPresets[selectedCurveFan] = .custom
            return
        }
        guard let speeds = preset.speeds, editableCurve.count == speeds.count else { return }
        isApplyingPreset = true
        defer { isApplyingPreset = false }
        zeroRPMEnabled[selectedCurveFan] = false
        editableCurve = editableCurve.enumerated().map { offset, point in
            var point = point
            point.speed = speeds[offset]
            return point
        }
        fixedFanSpeed = false
        fanPresets[selectedCurveFan] = preset
    }
    @Published private(set) var coolerBoost = false
    private var loadedCurves: [ECFanCurve?] = [nil, nil]
    private var loadedMode: UInt8?
    var loadedFanMode: ECFanMode? { loadedMode.flatMap(ECFanMode.init(rawValueByte:)) }
    @Published var curveApplied = false
    @Published var curveDirty = false
    @Published var lastAction = "系统已就绪"
    @Published var selectedFanMode: ECFanMode = .automatic
    @Published private(set) var fanModeStatus = "正在读取 EC 风扇状态…"
    @Published private(set) var fanModeBusy = false
    @Published var showingInstallResult = false
    @Published var installMessage = ""
    let monitor = SystemMonitor()
    let battery = BatteryModel()
    let lighting = KeyboardLightingModel()
    func applyCurve() {
        guard !fanModeBusy, selectedFanMode == .advanced, loadedMode == ECFanMode.advanced.rawValueByte,
              let expected = loadedCurves[selectedCurveFan], let mode = loadedMode else {
            fanModeStatus = "请先读取 EC 曲线"
            return
        }
        let fan = selectedCurveFan
        let points = fan == 0 ? curvePoints : gpuCurvePoints
        guard points.allSatisfy({ $0.speed.isFinite && (0...100).contains($0.speed) }) else {
            fanModeStatus = "曲线百分比必须在 0–100% 之间"
            return
        }
        let speeds = points.map { UInt8(clamping: Int($0.speed)) }
        guard ECFanCurve(temperatures: expected.temperatures, speeds: speeds).isValid else {
            fanModeStatus = "曲线节点无效"
            return
        }
        fanModeBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fanModeBusy = false }
            do {
                let receipt = try await Task.detached { try ECFanAdministrator.applyCurve(fan: fan, expected: expected, speeds: speeds, mode: mode) }.value
                self.loadedCurves[fan] = ECFanCurve(temperatures: expected.temperatures, speeds: receipt.speeds)
                self.loadedMode = receipt.mode
                self.selectedFanMode = .advanced
                self.curveApplied = true
                self.curveDirty = false
                self.fanModeStatus = "风扇 \(fan + 1) 曲线及高级模式读回通过"
                self.successfulSettingsApplyCount += 1
            } catch {
                self.loadedCurves = [nil, nil]
                self.curveApplied = false
                self.loadedMode = nil
                self.fanModeStatus = error.localizedDescription
            }
            self.lastAction = self.fanModeStatus
        }
    }
    func readFan() {
        guard !fanModeBusy else { return }
        fanModeBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fanModeBusy = false }
            do {
                let state = try await Task.detached { try ECFanAdministrator.read() }.value
                self.loadedMode = state.1
                self.coolerBoost = state.2 & 0x80 != 0
                self.loadedCurves = [state.3, state.4]
                if let mode = ECFanMode(rawValueByte: state.1) {
                    self.selectedFanMode = mode
                }
                if let cpu = state.3 {
                    self.curvePoints = zip(cpu.temperatures, cpu.speeds).enumerated().map {
                        CurvePoint(id: $0.offset, temperature: Double($0.element.0), speed: Double(min(100, $0.element.1)))
                    }
                }
                if let gpu = state.4 {
                    self.gpuCurvePoints = zip(gpu.temperatures, gpu.speeds).enumerated().map {
                        CurvePoint(id: $0.offset, temperature: Double($0.element.0), speed: Double(min(100, $0.element.1)))
                    }
                }
                self.fanModeStatus = ""
                self.fixedFanSpeed = false
                self.fanPresets = [.custom, .custom]
                self.zeroRPMEnabled = [self.curvePoints, self.gpuCurvePoints].map {
                    $0.contains { $0.temperature < 45 && $0.speed == 0 }
                }
                self.curveDirty = false
            } catch {
                self.loadedCurves = [nil, nil]
                self.loadedMode = nil
                self.fanModeStatus = error.localizedDescription
            }
        }
    }
    func toggleBoost() {
        guard !fanModeBusy, selectedFanMode == .advanced, loadedMode == ECFanMode.advanced.rawValueByte else { return }
        let enabled = !coolerBoost
        fanModeBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fanModeBusy = false }
            do {
                let receipt = try await Task.detached { try ECFanAdministrator.applyBoost(enabled) }.value
                self.coolerBoost = receipt.after & 0x80 != 0
                self.fanModeStatus = "强冷\(self.coolerBoost ? "已开启" : "已关闭") · EC 读回通过"
                OSDManager.shared.show(symbol: "fanblades.fill", title: t("cooler_boost"),
                                       detail: t(self.coolerBoost ? "osdOn" : "osdOff"), state: self.coolerBoost)
                self.successfulSettingsApplyCount += 1
            } catch { self.fanModeStatus = error.localizedDescription }
            self.lastAction = self.fanModeStatus
        }
    }
    func applyFanMode(_ mode: ECFanMode) {
        guard !fanModeBusy, mode != .silent, let loadedMode else { return }
        guard loadedMode != mode.rawValueByte else { return }
        if mode != .advanced {
            fanPresets = [.custom, .custom]
        }
        fanModeBusy = true
        fanModeStatus = "正在读取 D4 并校验风扇模式…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fanModeBusy = false; self.pendingPreset = nil }
            do {
                let receipt = try await Task.detached { try ECFanAdministrator.apply(mode) }.value
                self.loadedMode = receipt.after
                self.selectedFanMode = mode
                if let pending = self.pendingPreset {
                    self.pendingPreset = nil
                    self.setFanPreset(pending)
                }
                self.curveApplied = false
                self.fanModeStatus = "EC 风扇模式 \(receipt.mode.rawValue) · D4 读回校验通过"
                OSDManager.shared.show(icon: "fanblades.fill", text: mode.rawValue)
                self.successfulSettingsApplyCount += 1
                self.lastAction = self.fanModeStatus
            } catch {
                let message = error.localizedDescription
                self.curveApplied = false
                do {
                    let state = try await Task.detached { try ECFanAdministrator.read() }.value
                    self.loadedMode = state.1
                    self.coolerBoost = state.2 & 0x80 != 0
                    self.loadedCurves = [state.3, state.4]
                    if let current = ECFanMode(rawValueByte: state.1) {
                        self.selectedFanMode = current
                    }
                } catch {
                    self.loadedMode = nil
                    self.loadedCurves = [nil, nil]
                }
                self.fanModeStatus = message
                self.lastAction = self.fanModeStatus
            }
        }
    }
    func applyPerformance(_ mode: PerformanceMode) {
        performPowerChange(mode)
    }
    func updateEcoPreference(_ enabled: Bool) {
        guard !performanceBusy else { return }
        ecoPreference = enabled
        UserDefaults.standard.set(enabled, forKey: "mcontrol.energySavingEC")
        if performanceMode == .energySaving { performPowerChange(.energySaving) }
    }
    func restorePower() { performPowerChange(nil) }
    private func performPowerChange(_ mode: PerformanceMode?, automatic: Bool = false, savedEco: Bool? = nil) {
        guard !performanceBusy, !ControlAppDelegate.terminating, let expected = powerControlState,
              mode == nil ? canRestorePower : powerControlAvailable else { return }
        startupPowerAttempted = true
        if mode == .extreme && !BatteryStatus.readSystem().externalPower {
            performanceStatus = "极致档仅支持接通电源时使用"
            return
        }
        performanceBusy = true
        ControlAppDelegate.powerChangeInProgress = true
        performanceStatus = "正在切换并校验功耗与 EC 状态…"
        let preset = mode?.cpuPreset
        let eco = mode == .energySaving && (savedEco ?? ecoPreference)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.performanceBusy = false
                ControlAppDelegate.powerChangeInProgress = false
            }
            do {
                let receipt = try await Task.detached {
                    try PerformanceAdministrator.apply(
                        preset, eco: eco, expected: expected, allowRegistration: !automatic)
                }.value
                self.powerControlState = receipt
                self.performanceMode = mode
                SavedPowerSelection.saveVerified(
                    preset.map { SavedPowerSelection(preset: $0, eco: eco) }, to: .standard)
                if automatic {
                    self.ecoPreference = savedEco ?? self.ecoPreference
                    UserDefaults.standard.set(self.ecoPreference, forKey: "mcontrol.energySavingEC")
                } else {
                    OSDManager.shared.show(icon: mode?.symbol ?? "arrow.uturn.backward",
                                           text: mode?.title ?? "已恢复原始设置")
                }
                self.performanceStatus = self.describePower(receipt)
                self.successfulSettingsApplyCount += 1
                self.readFan()
            } catch {
                self.powerControlState = nil
                self.performanceMode = nil
                self.performanceStatus = error.localizedDescription
            }
            self.lastAction = self.performanceStatus
        }
    }
    func readPerformance() {
        powerServiceReady = PerformanceAdministrator.serviceEnabled
        if powerServiceReady { powerAuthorizationError = nil }
        guard !performanceBusy, !ControlAppDelegate.terminating else { return }
        performanceBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.performanceBusy = false
                self.restoreStartupPowerIfReady()
            }
            do {
                let status = try await Task.detached { try PerformanceAdministrator.read() }.value
                self.powerControlState = status
                self.performanceMode = status.preset.map { PerformanceMode.allCases[$0.rawValue] }
                self.performanceStatus = self.describePower(status)
            } catch {
                self.performanceMode = nil
                self.powerControlState = nil
                self.performanceStatus = error.localizedDescription
            }
        }
    }
    private func restoreStartupPowerIfReady() {
        guard !startupPowerAttempted, !ControlAppDelegate.terminating,
              let saved = SavedPowerSelection.load(from: .standard),
              let preset = saved.preset, powerControlAvailable,
              PerformanceAdministrator.serviceEnabled else { return }
        performPowerChange(PerformanceMode.allCases[preset.rawValue], automatic: true, savedEco: saved.eco)
    }
    private func describePower(_ status: CPUPowerControlStatus) -> String {
        if status.conflict { return "检测到外部策略修改，已停止控制；原值恢复未确认" }
        guard status.available else { return "当前 CPU、EC 或功耗锁定状态不支持安全写入" }
        if status.preset == .energySaving && status.shift == 0xC2 {
            return "EC 原生节能 · 可能关闭键盘背光；软件功耗限制已退出"
        }
        let values = status.currentWatts
        let prefix = status.preset == nil ? "原始设置" : "功耗读回"
        return String(format: "%@ · PL1 %.0f W / PL2 %.0f W", prefix, values.0, values.1)
    }
    func installDriver() { installMessage = OpenCoreDriverInstaller.install(); showingInstallResult = true; monitor.refresh() }
}

@MainActor
final class SystemMonitor: ObservableObject {
    struct DiskInfo {
        let name: String
        let totalBytes: Int64
        let availableBytes: Int64
        let format: String
        var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
        var usageFraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
        }
    }
    // Session-only: navigating away must not replay the dashboard self-test.
    var hasPlayedBootAnimation = false
    var hasPlayedResourceBootAnimation = false
    @Published private(set) var cpuUsage = 0.0
    @Published private(set) var perCoreCPUUsage: [Double] = []
    @Published private(set) var physicalCPUs = 0
    @Published private(set) var logicalCPUs = 0
    @Published private(set) var thermalState = "读取中"
    @Published private(set) var powerSource = "读取中"
    @Published private(set) var cpuSpeedLimit: Int?
    @Published private(set) var schedulerLimit: Int?
    @Published private(set) var availableCPUs: Int?
    @Published private(set) var ecStatus = "驱动未加载"
    @Published private(set) var ecControlAvailable = false
    @Published private(set) var ecIdentity = "等待 EC 驱动"
    @Published private(set) var openCoreVersion: String?
    @Published private(set) var lastUpdated = Date()
    @Published private(set) var memoryUsedBytes: UInt64 = 0
    @Published private(set) var memoryTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var diskAvailableBytes: Int64?
    @Published private(set) var diskInfo: DiskInfo?
    @Published private(set) var gpuStatus: GPUStatus?
    @Published private(set) var systemUptime: TimeInterval = 0
    var memoryFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return min(1, max(0, Double(memoryUsedBytes) / Double(memoryTotalBytes)))
    }
    var memorySummary: String {
        "\(Self.gigabytes(memoryUsedBytes)) / \(Self.gigabytes(memoryTotalBytes))"
    }
    var diskSummary: String {
        guard let diskInfo else { return "—" }
        return "已用 \(Self.gigabytes(UInt64(diskInfo.usedBytes))) / \(Self.gigabytes(UInt64(diskInfo.totalBytes)))"
    }
    var uptimeSummary: String {
        let totalMinutes = Int(systemUptime / 60)
        return "\(totalMinutes / 60)小时 \(totalMinutes % 60)分"
    }
    @Published private(set) var sensors = SensorSnapshot.pending
    private let sensorSampler = SensorSampler()
    private var sensorTask: Task<Void, Never>?
    private var frequencyTask: Task<Void, Never>?
    private var dashboardVisible = false
    private var hasSensorSample = false
    @Published private(set) var coreFrequency = SensorReading.pending
    @Published private(set) var coreFrequencies: [CoreFrequency] = []
    @Published private(set) var coreFrequencyRows: [CoreFrequencyRow] = []
    @Published private(set) var coreDetailsIssue: String?
    private var frequencySamples = CoreFrequencySamples()
    private var frequencyReadIssue: String?
    var displayedFrequency: SensorReading {
        return coreFrequency
    }

    func dashboardDidAppear() {
        dashboardVisible = true
    }
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var previousCoreTicks: [(active: UInt64, total: UInt64)] = []
    private var refreshTask: Task<Void, Never>?

    init() {
        physicalCPUs = Self.sysctlInt("hw.physicalcpu") ?? 0
        logicalCPUs = Self.sysctlInt("hw.logicalcpu") ?? 0
        refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
        frequencyTask = Task.detached(priority: .utility) { [weak self] in
            let cpuCount = ProcessInfo.processInfo.processorCount
            while !Task.isCancelled {
                let counters: [CoreCounter]
                let issue: String?
                do {
                    let bridge = try ECBridgeConnection()
                    counters = bridge.counterCacheVersion == 1
                        ? try bridge.cachedCoreCounters(logicalCPUCount: cpuCount)
                        : try bridge.coreCounters()
                    issue = bridge.counterCacheVersion == 1
                        ? nil : "全核采样需要 MSIECBridge 0.4.9，请更新硬盘 EFI 并重启"
                } catch {
                    counters = []
                    issue = String(describing: error)
                }
                guard !Task.isCancelled else { return }
                await self?.recordFrequency(counters, issue: issue, at: ProcessInfo.processInfo.systemUptime)
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
    }
    deinit { refreshTask?.cancel(); sensorTask?.cancel(); frequencyTask?.cancel() }
    func refresh() {
        frequencySamples.expire(at: ProcessInfo.processInfo.systemUptime)
        publishFrequency()
        if sensorTask == nil {
            sensorTask = Task { [weak self, sensorSampler] in
                let snapshot = await sensorSampler.sample()
                let gpu = await Task.detached(priority: .utility) { GPUStatus.read() }.value
                let fans = await Task.detached(priority: .utility) {
                    do {
                        let raw = try ECBridgeConnection().fanCounters()
                        return (
                            ECFanReading.decode(high: raw[0], low: raw[1], address: "C8:C9"),
                            ECFanReading.decode(high: raw[2], low: raw[3], address: "CA:CB")
                        )
                    } catch {
                        let missing = SensorReading(value: nil, source: nil, issue: String(describing: error))
                        return (missing, missing)
                    }
                }.value
                guard !Task.isCancelled else { return }
                self?.sensors = SensorSnapshot(
                    timestamp: snapshot.timestamp, temperature: snapshot.temperature,
                    frequency: snapshot.frequency, fan: fans.0, fan2: fans.1, power: snapshot.power
                )
                self?.gpuStatus = gpu
                self?.hasSensorSample = true
                self?.sensorTask = nil
            }
        }
        let usage = readCPUUsage()
        cpuUsage = usage.total
        perCoreCPUUsage = usage.cores
        thermalState = Self.thermalDescription(ProcessInfo.processInfo.thermalState)
        powerSource = Self.readPowerSource()
        readThermalLimits()
        readECBridge()
        openCoreVersion = Self.readOpenCoreVersion()
        lastUpdated = Date()
        memoryUsedBytes = Self.readUsedMemory()
        memoryTotalBytes = ProcessInfo.processInfo.physicalMemory
        diskInfo = Self.readDiskInfo()
        diskAvailableBytes = diskInfo?.availableBytes
        systemUptime = ProcessInfo.processInfo.systemUptime
    }

    private func recordFrequency(_ counters: [CoreCounter], issue: String?, at timestamp: TimeInterval) {
        frequencyReadIssue = issue
        frequencySamples.update(counters, at: timestamp)
    }

    private func publishFrequency() {
        coreFrequencies = frequencySamples.frequencies
        coreFrequencyRows = frequencySamples.rows(logicalCPUCount: logicalCPUs)
        coreDetailsIssue = frequencyReadIssue ?? (frequencySamples.hasLogicalCPUIdentity
            ? nil : "等待后台逐核采样")
        let aggregate = frequencySamples.aggregateGHz
        let issue = coreFrequencies.isEmpty
            ? (frequencyReadIssue ?? "等待同一核心的有效区间采样")
            : (aggregate == nil ? "有效采样核心均处于空闲，暂无运行频率" : nil)
        let observed = coreFrequencyRows.filter { $0.frequency != nil }.count
        let coverage = frequencySamples.hasLogicalCPUIdentity
            ? "\(observed)/\(logicalCPUs) 个逻辑核心有效"
            : "\(coreFrequencies.count) 个核心有效，未提供逻辑编号"
        coreFrequency = SensorReading(value: aggregate,
            source: "APERF/MPERF · 活动加权 CPU 速度 · \(coverage) · 约每秒更新", issue: issue)
    }

    private static func readUsedMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(getpagesize())
        return UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * page
    }

    private static func readDiskInfo() -> DiskInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskInfo(
            name: values.volumeName ?? "主磁盘",
            totalBytes: Int64(total),
            availableBytes: max(0, available),
            format: values.volumeLocalizedFormatDescription ?? "—"
        )
    }
    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    private static func readOpenCoreVersion() -> String? {
        for path in ["IODeviceTree:/options", "IODeviceTree:/efi", "IODeviceTree:/efi/platform", "IODeviceTree:/chosen"] {
            let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
            guard entry != IO_OBJECT_NULL else { continue }
            defer { IOObjectRelease(entry) }
            for key in ["opencore-version", "4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version",
                        "4d1fda02-38c7-4a6a-9cc6-4bcca8b30102:opencore-version"] {
                guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { continue }
                let text = (value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? value as? String
                if let version = text?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)),
                   !version.isEmpty, version.count <= 80 {
                    return version
                }
            }
        }
        return nil
    }

    func copyPowerSampleCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sudo powermetrics --samplers cpu_power -i 1000 -n 360 > ~/Desktop/GB7-power.txt", forType: .string)
    }
    private func readCPUUsage() -> (total: Double, cores: [Double]) {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (cpuUsage, perCoreCPUUsage) }
        let values = info.cpu_ticks
        let current = (user: UInt32(truncatingIfNeeded: values.0), system: UInt32(truncatingIfNeeded: values.1), idle: UInt32(truncatingIfNeeded: values.2), nice: UInt32(truncatingIfNeeded: values.3))
        defer { previousTicks = current }
        if let previousTicks {
            let userDelta = current.user &- previousTicks.user
            let systemDelta = current.system &- previousTicks.system
            let idleDelta = current.idle &- previousTicks.idle
            let niceDelta = current.nice &- previousTicks.nice
            let totalDelta = UInt64(userDelta) + UInt64(systemDelta) + UInt64(idleDelta) + UInt64(niceDelta)
            let totalUsage = totalDelta > 0 ? min(1, max(0, Double(UInt64(userDelta) + UInt64(systemDelta) + UInt64(niceDelta)) / Double(totalDelta))) : cpuUsage
            return (totalUsage, readPerCoreCPUUsage())
        } else {
            return (0, [])
        }
    }

    private func readPerCoreCPUUsage() -> [Double] {
        var info: processor_info_array_t?
        var processorCount = mach_msg_type_number_t(0)
        var infoCount = mach_msg_type_number_t(0)
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return perCoreCPUUsage }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }
        let stride = Int(CPU_STATE_MAX)
        var current: [(active: UInt64, total: UInt64)] = []
        var usage: [Double] = []
        for core in 0..<Int(processorCount) {
            let offset = core * stride
            let active = UInt64(info[offset + Int(CPU_STATE_USER)])
                + UInt64(info[offset + Int(CPU_STATE_SYSTEM)])
                + UInt64(info[offset + Int(CPU_STATE_NICE)])
            let total = active + UInt64(info[offset + Int(CPU_STATE_IDLE)])
            let previous = previousCoreTicks.indices.contains(core) ? previousCoreTicks[core] : nil
            let activeDelta = previous.map { active >= $0.active ? active - $0.active : 0 } ?? 0
            let totalDelta = previous.map { total >= $0.total ? total - $0.total : 0 } ?? 0
            current.append((active, total))
            usage.append(totalDelta > 0 ? min(1, max(0, Double(activeDelta) / Double(totalDelta))) : 0)
        }
        previousCoreTicks = current
        return usage
    }
    private func readThermalLimits() {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); process.arguments = ["-g", "therm"]; let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return }; cpuSpeedLimit = Self.value(named: "CPU_Speed_Limit", in: output); schedulerLimit = Self.value(named: "CPU_Scheduler_Limit", in: output); availableCPUs = Self.value(named: "CPU_Available_CPUs", in: output) } catch { cpuSpeedLimit = nil; schedulerLimit = nil; availableCPUs = nil }
    }
    private func readECBridge() {
        ecControlAvailable = false
        guard let matching = IOServiceMatching("MSIEmbeddedControllerBridge") else { ecStatus = "驱动服务不可用"; ecIdentity = "—"; return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { ecStatus = "驱动未加载"; ecIdentity = "—"; return }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != IO_OBJECT_NULL else { ecStatus = "驱动未加载"; ecIdentity = "—"; return }
        defer { IOObjectRelease(service) }
        var rawProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &rawProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS, let properties = rawProperties?.takeRetainedValue() as? [String: Any] else { ecStatus = "驱动已加载，属性读取失败"; ecIdentity = "—"; return }
        ecControlAvailable = ((properties["MSIECAPI"] as? NSNumber)?.intValue ?? 0) >= 3
        let profile = properties["MSIECProfile"] as? String ?? "unknown"
        let api = (properties["MSIECAPI"] as? NSNumber)?.intValue ?? 0
        let version = properties["MSIECDriverVersion"] as? String
        let bridgeDescription = version.flatMap { $0.isEmpty ? nil : "MSIECBridge \($0)" } ?? "MSIECBridge · API \(api)"
        if profile == "not-probed" {
            ecStatus = ECChargePolicy.supportsAPI(api) ? bridgeDescription : "EC 驱动 API \(api) 不兼容"
            ecIdentity = (try? ECBridgeConnection().firmware()) ?? "EC 固件读取失败"
            return
        }
        let identity = properties["MSIECIdentityA0"] as? Data ?? Data(); let printable = identity.prefix { $0 >= 0x20 && $0 <= 0x7E }; ecIdentity = String(bytes: printable, encoding: .ascii).flatMap { $0.isEmpty ? nil : $0 } ?? "未识别"; ecStatus = bridgeDescription
    }
    private static func sysctlInt(_ name: String) -> Int? { var value: Int32 = 0; var size = MemoryLayout<Int32>.size; guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }; return Int(value) }
    private static func value(named name: String, in text: String) -> Int? { let escaped = NSRegularExpression.escapedPattern(for: name); guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\s*=\\s*(\\d+)"), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }; return Int(text[range]) }
    private static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String { switch state { case .nominal: "正常"; case .fair: "温热"; case .serious: "高温"; case .critical: "严重"; @unknown default: "未知" } }
    private static func readPowerSource() -> String { guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "未知" }; for source in sources { guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue(), let description = raw as? [String: Any], let state = description[kIOPSPowerSourceStateKey as String] as? String else { continue }; if state == kIOPSACPowerValue as String { return "已接电源" }; return "电池供电" }; return "未知" }
}

struct RootView: View {
    @ObservedObject var model: MSIControlModel
    @ObservedObject private var monitor: SystemMonitor
    @AppStorage("mcontrol.ecSetupPromptSeen") private var setupPromptSeen = false
    @AppStorage("mcontrol.ecConfiguredByApp") private var configuredByApp = false
    @State private var showingDriverSetup = false
    @ObservedObject private var hotkeys = IntegratedHotkeys.shared
    @EnvironmentObject var localization: AppLocalization

    init(model: MSIControlModel) {
        self.model = model
        self.monitor = model.monitor
    }

    private var needsDriverNotice: Bool {
        !monitor.ecControlAvailable && [.dashboard, .fan, .battery].contains(model.section)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $model.section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 280)
        } detail: {
            ContentView(model: model)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.section == .dashboard && (!hotkeys.inputAllowed || !hotkeys.bluetoothAllowed || !model.powerServiceReady) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(t("controlPermissions"), systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            if !hotkeys.inputAllowed || !hotkeys.bluetoothAllowed {
                                Text(t("shortcutPermissionContext"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !model.powerServiceReady {
                                Text(model.powerAuthorizationError ?? t("powerAuthorizationContext"))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 12) {
                                if !hotkeys.inputAllowed || !hotkeys.bluetoothAllowed {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                                        .resizable()
                                        .frame(width: 40, height: 40)
                                        .onDrag {
                                            NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                                        }
                                        .help(t(hotkeys.inputAllowed ? "dragAppForBluetooth" : "dragAppForInputMonitoring"))
                                        .accessibilityLabel(t(hotkeys.inputAllowed ? "dragAppForBluetooth" : "dragAppForInputMonitoring"))
                                }
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) { permissionButtons }
                                    VStack(alignment: .leading, spacing: 8) { permissionButtons }
                                }
                            }
                            Divider()
                        }
                        .padding(.horizontal, 24).padding(.top, 12)
                    }
                    if needsDriverNotice {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(t(configuredByApp ? "EC 已配置，等待加载" : "EC 驱动未就绪"),
                                  systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text(t(configuredByApp
                                ? "请重启电脑并从配置过的 OpenCore 启动，然后重新检测。"
                                : "风扇控制和充电上限需要兼容的 EC 驱动。未加载不代表未安装，请先查看硬件驱动状态。"))
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(t("open_hardware_drivers")) { model.section = .drivers }
                                Button(t("check_again")) { monitor.refresh() }
                            }
                            Divider()
                        }
                        .padding(.horizontal, 24).padding(.top, 12)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: model.goBack) {
                    Image(systemName: "chevron.left")
                }
                .help(t("back"))
                .accessibilityLabel(t("back"))
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)

                Button(action: model.goForward) {
                    Image(systemName: "chevron.right")
                }
                .help(t("forward"))
                .accessibilityLabel(t("forward"))
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
            }
        }
        .environment(\.locale, localization.locale)
        .task {
            hotkeys.lighting = model.lighting
            await model.lighting.restoreAtStartup()
        }
        .task {
            monitor.refresh()
            guard !setupPromptSeen, !monitor.ecControlAvailable else { return }
            setupPromptSeen = true
            showingDriverSetup = true
        }
        .alert(t("ec_driver_not_ready"), isPresented: $showingDriverSetup) {
            Button(t("open_hardware_drivers")) { model.section = .drivers }
            Button(t("not_now"), role: .cancel) {}
        } message: {
            Text(t("fan_control_and_charge_limits_require_a_compatible_ec_driver_check_har"))
        }
    }

    @ViewBuilder
    private var permissionButtons: some View {
        if !hotkeys.inputAllowed {
            Button(t("enableInputMonitoring")) { hotkeys.requestPermission() }
        }
        if !hotkeys.bluetoothAllowed {
            Button(t("enableBluetoothPermission")) { hotkeys.requestBluetoothPermission() }
        }
        if !model.powerServiceReady {
            Button(action: model.authorizePowerService) {
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .frame(width: 20, height: 20)
                        .onDrag {
                            NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                        }
                    Text(t("authorizePowerControl"))
                }
            }
            .disabled(model.powerAuthorizationBusy)
        }
    }
}

struct SidebarView: View {
    @Binding var selection: AppSection
    @EnvironmentObject var localization: AppLocalization
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        List {
            ForEach(AppSection.mainSections) { item in
                navigationRow(item)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                navigationRow(.settings)
                .padding(.horizontal, 8)
            }
        }
    }

    private func navigationRow(_ item: AppSection) -> some View {
        let selected = selection == item
        let foreground = selected ? Color.accentColor : Color.primary
        return Button { selection = item } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(foreground)
                    .frame(width: 20)
                Text(item.title)
                    .foregroundStyle(foreground)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: reduceTransparency
                            ? .controlBackgroundColor
                            : contrast == .increased ? .secondarySystemFill : .quaternarySystemFill))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

