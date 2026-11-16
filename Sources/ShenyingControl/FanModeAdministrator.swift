import ECControl
import Foundation
import PowerServiceProtocol

enum ECFanAdministrator {
    static func apply(_ mode: ECFanMode) throws -> ECFanModeReceipt {
        let connection = try ECBridgeConnection()
        let firmware = try connection.firmware()
        guard let profile = ECFeatureProfile.match(firmware),
              profile.fanModes.contains(mode.rawValueByte),
              connection.apiVersion >= 10 ||
                (firmware == "15P2EMS1.110" && connection.apiVersion >= 3) ||
                (firmware != "15P2EMS1.110" && ECChargePolicy.supportedFirmware.contains(firmware)) else {
            throw ECError.unavailable("当前固件或驱动不支持风扇模式写入")
        }
        let current = try connection.readByte(at: profile.fanAddress)
        guard ECFanMode(rawValueByte: current) != nil else { throw ECError.invalid("当前 D4 风扇模式无法确认") }
        guard mode != .silent else { throw ECError.invalid("仅支持自动与手动") }
        let data = try PerformanceAdministrator.control(
            .fan(.mode(mode, expected: current, firmware: firmware)), as: ECFanModeReceipt.self)
        guard data.mode == mode, data.isVerified, data.before == current, data.after == mode.rawValueByte else {
            throw ECError.mismatch("EC 风扇模式读回值与请求不匹配")
        }
        return data
    }

    static func read() throws -> (String, UInt8, UInt8, ECFanCurve?, ECFanCurve?) {
        let connection = try ECBridgeConnection()
        let firmware = try connection.firmware()
        guard let profile = ECFeatureProfile.match(firmware) else {
            throw ECError.unavailable("当前 EC 固件没有匹配的风扇寄存器配置")
        }
        let mode = try connection.readByte(at: profile.fanAddress)
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
        let receipt = try PerformanceAdministrator.control(
            .fan(.curve(fan: fan, expected: expected, speeds: speeds, mode: mode, firmware: "15P2EMS1.110")),
            as: ECFanCurveReceipt.self)
        guard receipt.speeds == speeds, receipt.mode == mode else { throw ECError.mismatch("曲线读回不匹配") }
        return receipt
    }

    static func applyBoost(_ enabled: Bool) throws -> ECCoolerBoostReceipt {
        let connection = try ECBridgeConnection()
        guard connection.apiVersion >= 3 else { throw ECError.unavailable("请先配置 MSIECBridge 0.3.0 并重启") }
        let firmware = try connection.firmware()
        guard let profile = ECFeatureProfile.match(firmware),
              connection.apiVersion >= 10 || firmware == "15P2EMS1.110" else {
            throw ECError.unavailable("当前固件的强冷控制需要 API 10 驱动")
        }
        guard try connection.readByte(at: profile.fanAddress) == ECFanMode.advanced.rawValueByte else {
            throw ECError.unavailable("请先应用手动模式")
        }
        let expected = try connection.readByte(at: 0x98)
        let receipt = try PerformanceAdministrator.control(
            .fan(.boost(enabled, expected: expected, firmware: firmware)), as: ECCoolerBoostReceipt.self)
        guard receipt.before == expected, receipt.after == ((expected & 0x7F) | (enabled ? 0x80 : 0)) else {
            throw ECError.mismatch("强冷读回不匹配")
        }
        return receipt
    }
}
