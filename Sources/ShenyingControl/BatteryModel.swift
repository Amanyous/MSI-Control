import AppKit
import Combine
import ECControl
import Foundation

@MainActor
final class BatteryModel: ObservableObject {
    @Published private(set) var successfulApplyCount = 0
    @Published private(set) var battery = BatteryStatus()
    @Published private(set) var ec: ECBridgeSnapshot?
    @Published private(set) var isBusy = false
    @Published private(set) var status = "点击“读取 EC”获取固件和当前充电上限"
    @Published private(set) var lastWrite: ECWriteReceipt?
    @Published var selectedLimit = 80
    @Published var addressText = "D7"
    @Published var valueText = "D0"
    @Published private(set) var registerDescription = "尚未读取"
    private let readBattery: @Sendable () async -> BatteryStatus
    private let readEC: @Sendable () async throws -> ECBridgeSnapshot
    private let readByte: @Sendable (UInt8) async throws -> UInt8
    private let writeLimit: @Sendable (Int, UInt8) async throws -> ECWriteReceipt

    init(
        readBattery: @escaping @Sendable () async -> BatteryStatus = {
            await Task.detached { BatteryStatus.readSystem() }.value
        },
        readEC: @escaping @Sendable () async throws -> ECBridgeSnapshot = {
            try await Task.detached { try ECBridgeConnection().snapshot() }.value
        },
        readByte: @escaping @Sendable (UInt8) async throws -> UInt8 = { address in
            try await Task.detached { try ECBridgeConnection().readByte(at: address) }.value
        },
        writeLimit: @escaping @Sendable (Int, UInt8) async throws -> ECWriteReceipt = { percent, expected in
            try await Task.detached { try ECAdministrator.apply(percent: percent, expected: expected) }.value
        }
    ) {
        self.readBattery = readBattery; self.readEC = readEC
        self.readByte = readByte; self.writeLimit = writeLimit
        // Constructing the model never reads or writes EC, or restores a write.
    }

    var canApply: Bool { !isBusy && ec?.canWriteChargeLimit == true && ECChargePolicy.encode(selectedLimit) != nil }
    var rawWritePercent: Int? {
        guard ECChargePolicy.parseByte(addressText) == UInt8(ECChargePolicy.address),
              let value = ECChargePolicy.parseByte(valueText), let percent = ECChargePolicy.decode(value),
              ECChargePolicy.encode(percent) == value else { return nil }
        return percent
    }
    var canWriteRaw: Bool { !isBusy && ec?.canWriteChargeLimit == true && rawWritePercent != nil }
    var firmwareDescription: String { ec?.firmware ?? "尚未读取" }
    var appliedDescription: String {
        if let percent = ec?.chargeLimit { return "\(percent)%" }
        return ec?.chargeByte == 0x80 ? "固件未报告上限" : "—"
    }
    var capabilityDescription: String {
        guard let ec else { return "尚未连接 EC 读写接口" }
        if !ECChargePolicy.supports(ec.firmware) { return "固件尚未适配，EC 保持只读" }
        if !(2...8).contains(ec.apiVersion) { return "EC 驱动 API \(ec.apiVersion) 不兼容，暂不能写入" }
        if ec.apiVersion < 4 && ec.firmware == "15P2EMS1.110" { return "需配置 MSIECBridge 0.3.1 或更新版本并重启" }
        if !ec.canWriteChargeLimit {
            return ec.chargeByte.map { String(format: "充电寄存器 D7=0x%02X 无法识别，暂不能写入", $0) }
                ?? "未读取到充电寄存器 D7，暂不能写入"
        }
        return "已匹配充电控制，可读写并校验"
    }

    func refreshBattery() async {
        let system = await readBattery()
        do {
            let ecReading = try await Task.detached { try ECBridgeConnection().batteryReading() }.value
            if let ecReading {
                let charging = ecReading.currentMilliamps > 50
                battery = BatteryStatus(
                    percent: ecReading.percent,
                    isCharging: charging,
                    externalPower: system.externalPower,
                    isPresent: system.isPresent,
                    healthPercent: BatteryStatus.health(
                        fullChargeCapacity: ecReading.fullChargeCapacity,
                        designCapacity: ecReading.designCapacity
                    ),
                    powerWatts: system.powerWatts,
                    source: "EC \(ecReading.remainingCapacity)/\(ecReading.fullChargeCapacity) mAh"
                )
                return
            }
        } catch {
            // Keep the system reading when EC telemetry is unavailable.
        }
        battery = system
    }

    func refreshEC() async {
        guard !isBusy else { return }
        isBusy = true
        status = "正在读取 EC 固件与充电设置…"
        defer { isBusy = false }
        do {
            let snapshot = try await readEC()
            ec = snapshot
            if let limit = snapshot.chargeLimit { selectedLimit = limit }
            if let value = snapshot.chargeByte { valueText = String(format: "%02X", value) }
            status = capabilityDescription
        } catch {
            ec = nil
            status = error.localizedDescription
        }
    }

    func readRegister() async {
        guard !isBusy else { return }
        guard let address = ECChargePolicy.parseByte(addressText) else {
            registerDescription = "请输入 00–FF 范围的十六进制地址"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let byte = try await readByte(address)
            addressText = String(format: "%02X", address)
            valueText = String(format: "%02X", byte)
            registerDescription = String(format: "EC 0x%02X = 0x%02X（%d）", address, byte, byte)
        } catch { registerDescription = error.localizedDescription }
    }

    func applyLimit() async { await apply(percent: selectedLimit) }
    func writeRegister() async {
        guard let percent = rawWritePercent else {
            registerDescription = "当前仅支持充电寄存器 D7，写入值须为 8A–E4（上限 10–100%）"
            return
        }
        await apply(percent: percent)
    }

    private func apply(percent: Int) async {
        guard !isBusy, let snapshot = ec, snapshot.canWriteChargeLimit, let expected = snapshot.chargeByte,
              ECChargePolicy.encode(percent) != nil else { return }
        isBusy = true
        lastWrite = nil
        status = "等待管理员授权，写入后将读回校验…"
        defer { isBusy = false }
        do {
            let receipt = try await writeLimit(percent, expected)
            guard receipt.isVerified, receipt.firmware == snapshot.firmware,
                  receipt.percent == percent, receipt.before == expected else {
                throw ECError.mismatch("写入记录与请求不匹配，未确认生效，请重新读取")
            }
            ec = ECBridgeSnapshot(apiVersion: snapshot.apiVersion, driverVersion: snapshot.driverVersion, firmware: receipt.firmware, chargeByte: receipt.after)
            selectedLimit = percent
            valueText = String(format: "%02X", receipt.after)
            lastWrite = receipt
            registerDescription = String(format: "EC 0xD7：0x%02X → 0x%02X，读回一致", receipt.before, receipt.after)
            status = "充电上限 \(percent)% · EC 读回校验通过"
            successfulApplyCount += 1
        } catch {
            // Invalidate cached write eligibility: a failed write may have changed EC.
            ec = nil
            status = error.localizedDescription + "；请重新读取 EC 后再操作"
            registerDescription = status
        }
    }
}

private enum ECAdministrator {
    static func apply(percent: Int, expected: UInt8) throws -> ECWriteReceipt {
        guard ECChargePolicy.encode(percent) != nil else { throw ECError.invalid("充电上限超出范围") }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "MSIECHelper"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ECError.unavailable("应用内缺少 EC 写入助手，请使用完整的 MSI Control.app")
        }
        func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = shellQuote(helper.path) + " set-charge-limit \(percent) \(expected)"
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "管理员授权或 EC 写入失败"
            throw ECError.unavailable(message)
        }
        return try JSONDecoder().decode(ECWriteReceipt.self, from: data)
    }
}
