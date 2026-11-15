import ECControl
import Foundation

enum ECFanAdministrator {
    static func apply(_ mode: ECFanMode) throws -> ECFanModeReceipt {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "MSIECHelper"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ECError.unavailable("应用内缺少 EC 写入助手，请使用完整的 MSI Control.app")
        }
        let connection = try ECBridgeConnection()
        let firmware = try connection.firmware()
        guard (firmware == "15P2EMS1.110" && connection.apiVersion >= 3) ||
              (firmware != "15P2EMS1.110" && ECChargePolicy.supports(firmware)) else {
            throw ECError.unavailable("当前固件或驱动不支持风扇模式写入")
        }
        let current = try connection.readByte(at: 0xD4)
        guard ECFanMode(rawValueByte: current) != nil else { throw ECError.invalid("当前 D4 风扇模式无法确认") }
        let name: String
        switch mode { case .automatic: name = "auto"; case .silent: throw ECError.invalid("仅支持自动与手动"); case .advanced: name = "advanced" }
        let data = try privileged(["set-fan-mode", name, String(current)], as: ECFanModeReceipt.self)
        guard data.mode == mode, data.isVerified, data.before == current, data.after == mode.rawValueByte else {
            throw ECError.mismatch("EC 风扇模式读回值与请求不匹配")
        }
        return data
    }

    static func read() throws -> (String, UInt8, UInt8, ECFanCurve?, ECFanCurve?) {
        let connection = try ECBridgeConnection()
        let firmware = try connection.firmware()
        let mode = try connection.readByte(at: 0xD4)
        let boost = try connection.readByte(at: 0x98)
        return (firmware, mode, boost,
                firmware == "15P2EMS1.110" ? try connection.fanCurve(fan: 0) : nil,
                firmware == "15P2EMS1.110" ? try connection.fanCurve(fan: 1) : nil)
    }

    static func applyCurve(fan: Int, expected: ECFanCurve, speeds: [UInt8], mode: UInt8) throws -> ECFanCurveReceipt {
        let connection = try ECBridgeConnection()
        guard connection.apiVersion >= 3 else { throw ECError.unavailable("请先配置 MSIECBridge 0.3.0 并重启") }
        guard mode == ECFanMode.advanced.rawValueByte,
              try connection.firmware() == "15P2EMS1.110",
              try connection.fanCurve(fan: fan) == expected,
              try connection.readByte(at: 0xD4) == mode else { throw ECError.mismatch("EC 曲线或模式已变化，请重新读取") }
        let temperatures = expected.temperatures.map(String.init).joined(separator: ",")
        let old = expected.speeds.map(String.init).joined(separator: ",")
        let target = speeds.map(String.init).joined(separator: ",")
        return try privileged(["set-fan-curve", String(fan), String(mode), temperatures, old, target], as: ECFanCurveReceipt.self)
    }

    static func applyBoost(_ enabled: Bool) throws -> ECCoolerBoostReceipt {
        let connection = try ECBridgeConnection()
        guard connection.apiVersion >= 3 else { throw ECError.unavailable("请先配置 MSIECBridge 0.3.0 并重启") }
        guard try connection.firmware() == "15P2EMS1.110" else { throw ECError.unavailable("当前固件不支持强冷写入") }
        guard try connection.readByte(at: 0xD4) == ECFanMode.advanced.rawValueByte else {
            throw ECError.unavailable("请先应用手动模式")
        }
        let expected = try connection.readByte(at: 0x98)
        return try privileged(["set-cooler-boost", enabled ? "on" : "off", String(expected)], as: ECCoolerBoostReceipt.self)
    }

    private static func privileged<T: Decodable>(_ args: [String], as type: T.Type) throws -> T {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "MSIECHelper"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw ECError.unavailable("应用内缺少 EC 写入助手") }
        let command = ([helper.path] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
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
            throw ECError.unavailable(String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "管理员授权或 EC 写入失败")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
