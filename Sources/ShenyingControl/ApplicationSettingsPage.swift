import SwiftUI
import ServiceManagement
import ECControl

struct ApplicationSettingsPage: View {
    @EnvironmentObject private var localization: AppLocalization
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("mcontrol.appearance") private var appearance = "system"
    @AppStorage("mcontrol.shortcutOSD") private var shortcutOSD = true
    @AppStorage("mcontrol.windowsNumLock") private var windowsNumLock = false
    @State private var numLockError = false
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var loginBusy = false
    @State private var touchpadEnabled: Bool?
    @State private var touchpadBusy = false
    @State private var touchpadError: String?
    private var chinese: Bool { localization.resolvedLanguage == .chinese }

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text(t("generalSettings")).font(.caption).foregroundStyle(.secondary)
                LabeledContent(t("appLanguage")) {
                Picker(t("language"), selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }.labelsHidden().pickerStyle(.menu).frame(width: 180)
                }.frame(maxWidth: .infinity)
                LabeledContent(t("osdSetting")) {
                    Toggle(t("osdSetting"), isOn: $shortcutOSD)
                        .labelsHidden().toggleStyle(.switch)
                }
                LabeledContent(chinese ? "触控板" : "Trackpad") {
                    Toggle(chinese ? "触控板" : "Trackpad", isOn: Binding(
                        get: { touchpadEnabled ?? true },
                        set: { updateTouchpad($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(touchpadEnabled == nil || touchpadBusy)
                }
                if let touchpadError {
                    Text(touchpadError).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent(chinese ? "Windows 式 Num Lock" : "Windows-style Num Lock") {
                    Toggle("Num Lock", isOn: Binding(
                        get: { windowsNumLock },
                        set: { enabled in
                            if WindowsNumLock.apply(enabled) {
                                windowsNumLock = enabled
                                numLockError = false
                            } else {
                                numLockError = true
                            }
                        }
                    )).labelsHidden().toggleStyle(.switch)
                }
                if numLockError {
                    Text(chinese ? "请先安装支持 Num Lock 的键盘驱动并重启。"
                         : "Install the Num Lock keyboard driver and restart first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent(t("appAppearance")) {
                    Picker(t("appAppearance"), selection: $appearance) {
                        Text(t("appearanceSystem")).tag("system")
                        Text(t("appearanceLight")).tag("light")
                        Text(t("appearanceDark")).tag("dark")
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 300)
                }.frame(maxWidth: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(t("startupSettings")).font(.caption).foregroundStyle(.secondary)
                LabeledContent(t("launchAtLogin")) {
                Toggle(t("launchAtLogin"), isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { enabled in
                        loginBusy = true
                        loginError = nil
                        Task { @MainActor in
                            defer { loginStatus = SMAppService.mainApp.status; loginBusy = false }
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try await SMAppService.mainApp.unregister() }
                            } catch { loginError = error.localizedDescription }
                        }
                    }
                )).labelsHidden().toggleStyle(.switch).disabled(loginBusy)
                }
                if loginStatus == .requiresApproval {
                    Button(t("approveLoginItem")) { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.bordered)
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
          }
          .labeledContentStyle(SettingsRowStyle())
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(24)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refreshTouchpad() }
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                loginStatus = SMAppService.mainApp.status
                Task { await refreshTouchpad() }
            }
        }
    }

    @MainActor private func refreshTouchpad() async {
        guard !touchpadBusy else { return }
        touchpadBusy = true
        defer { touchpadBusy = false }
        do {
            touchpadEnabled = try await Task.detached {
                try ECBridgeConnection().touchpadEnabled()
            }.value
            touchpadError = nil
        } catch {
            touchpadEnabled = nil
            touchpadError = chinese
                ? "触控板控制需要配置 MSIECBridge 0.3.6 并重启；仅支持兼容的 VoodooI2C 驱动。"
                : "Install MSIECBridge 0.3.6 and restart. A compatible VoodooI2C driver is required."
        }
    }

    private func updateTouchpad(_ enabled: Bool) {
        guard !touchpadBusy else { return }
        touchpadBusy = true
        Task { @MainActor in
            defer { touchpadBusy = false }
            do {
                touchpadEnabled = try await Task.detached {
                    try ECBridgeConnection().touchpadEnabled(enabled)
                }.value
                touchpadError = nil
            } catch {
                touchpadError = chinese ? "未能切换触控板，请重新打开设置读取状态。" : "Could not switch the trackpad. Reopen Settings to refresh its state."
            }
        }
    }
}

private struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 24) {
            configuration.label.frame(minWidth: 120, alignment: .leading)
            Spacer(minLength: 16)
            configuration.content
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
}

struct ApplicationAboutPage: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
    private var driverVersion: String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("MSIECBridge.kext/Contents/Info.plist"),
              let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return "—" }
        return info["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        Form {
            Section("MSI Control") {
                LabeledContent(t("version"), value: version).textSelection(.enabled)
                LabeledContent(t("build"), value: build).textSelection(.enabled)
            }
            Section(t("system")) {
                LabeledContent(t("system"), value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent(t("architecture"), value: "Intel x86_64")
            }
            Section(t("ecDriverFirmware")) {
                LabeledContent(t("bundled_ec_driver"), value: driverVersion).textSelection(.enabled)
            }
        }.formStyle(.grouped)
    }
}
