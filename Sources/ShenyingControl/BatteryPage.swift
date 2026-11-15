import ECControl
import SwiftUI

struct BatteryPage: View {
    @ObservedObject var battery: BatteryModel
    @State private var showingEC = false
    @State private var customLimit = false

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                valueRow(t("电量"), battery.battery.percent.map { "\($0)% · \(battery.battery.source)" } ?? "—")
                valueRow(t("电池健康度"), battery.battery.healthPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                valueRow(t("power"), t(battery.battery.isPresent ? (battery.battery.externalPower ? "已接电源" : "电池供电") : "未读取到电池"))
                valueRow(t("充电状态"), t(battery.battery.isCharging ? "正在充电" : "未在充电"))
                valueRow(t("电池功率"), battery.battery.powerWatts.map { String(format: "%+.1f W", $0) } ?? "—")
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(t("charge_limit")).font(.headline)
                valueRow(t("current_charge_limit"), translated(battery.appliedDescription))
                HStack(alignment: .center) {
                Text(t("charge_limit")).foregroundStyle(.secondary)
                Spacer()
                Picker(t("charge_limit"), selection: Binding(
                    get: { customLimit ? 0 : battery.selectedLimit },
                    set: { value in
                        customLimit = value == 0
                        if value != 0 { battery.selectedLimit = value }
                    }
                )) {
                    Text("80%").tag(80)
                    Text("100%").tag(100)
                    Text(t("customChargeLimit")).tag(0)
                }.labelsHidden().pickerStyle(.menu).frame(width: 160).disabled(battery.isBusy)
                }
                if customLimit {
                HStack(alignment: .center, spacing: 12) {
                    Text(t("custom_limit")).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Slider(value: Binding(get: { Double(battery.selectedLimit) }, set: { battery.selectedLimit = Int($0.rounded()) }),
                           in: 10...100, step: 1).accessibilityLabel(t("charge_limit_percentage"))
                    Stepper("\(battery.selectedLimit)%", value: $battery.selectedLimit, in: ECChargePolicy.percentRange)
                        .fixedSize().accessibilityLabel(t("adjust_charge_limit_percentage"))
                }.disabled(battery.isBusy)
                }
                Text(t("batteryLimitHint")).font(.caption).foregroundStyle(.secondary)
                Text(translated(battery.status)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(t("ecDriverFirmware")).font(.headline)
                valueRow(t("ecDriverFirmware"), translated(battery.firmwareDescription))
                Text(translated(battery.capabilityDescription)).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(t("ecRegisterAdvanced"), isExpanded: $showingEC) {
                  VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(t("address"))
                        TextField(t("address"), text: $battery.addressText).textFieldStyle(.roundedBorder)
                            .font(.body.monospaced()).frame(width: 80)
                            .accessibilityLabel(t("ec_hexadecimal_address_00_to_ff"))
                        Button(t("readByte")) { Task { await battery.readRegister() } }.buttonStyle(.bordered)
                        Text(t("value"))
                        TextField(t("value"), text: $battery.valueText).textFieldStyle(.roundedBorder)
                            .font(.body.monospaced()).frame(width: 80)
                            .accessibilityLabel(t("ec_hexadecimal_byte_value"))
                        Button(t("writeVerify")) { Task { await battery.writeRegister() } }
                            .buttonStyle(.bordered).disabled(!battery.canWriteRaw)
                    }
                    Text(translated(battery.registerDescription)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(t("registerHint")).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                  }.padding(.top, 8)
                }.disabled(battery.isBusy)
            }
          }
          .padding(24)
          .frame(maxWidth: 900, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .onChange(of: battery.selectedLimit) { _, limit in
            if limit != 80 && limit != 100 { customLimit = true }
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await battery.applyLimit() } } label: {
                    Label(t("applyChargeLimit"), systemImage: "checkmark")
                }.disabled(!battery.canApply).help(t("applyChargeLimit"))
            }
        }
        .task {
            await battery.refreshEC()
            customLimit = battery.selectedLimit != 80 && battery.selectedLimit != 100
            await battery.refreshBattery()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await battery.refreshBattery()
            }
        }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .center, spacing: 20) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value).foregroundStyle(.primary).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }.frame(maxWidth: .infinity)
    }
}
