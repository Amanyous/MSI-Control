import Foundation

public enum ECChargePolicy {
    public static let apiVersion = 2
    public static let address = 0xD7
    public static let percentRange = 10...100
    public static let firmwareLength = 12
    public static let supportedFirmware = ["15P2EMS1.110", "15P4EMS1.105", "15P4EMS1.107"]

    public static func supports(_ firmware: String) -> Bool { supportedFirmware.contains(firmware) }
    public static func encode(_ percent: Int) -> UInt8? {
        guard percentRange.contains(percent) else { return nil }
        return UInt8(percent) | 0x80
    }
    public static func decode(_ raw: UInt8) -> Int? {
        let value = Int(raw & 0x7F)
        return percentRange.contains(value) ? value : nil
    }
    public static func validCurrent(_ raw: UInt8) -> Bool { raw == 0x80 || decode(raw) != nil }
    public static func parseByte(_ text: String) -> UInt8? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("0x") { text.removeFirst(2) }
        guard (1...2).contains(text.utf8.count), text.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return UInt8(text, radix: 16)
    }
    public static func firmware(from bytes: [UInt8]) -> String? {
        guard bytes.count == firmwareLength, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}

public enum ECFanMode: String, CaseIterable, Codable, Sendable {
    case automatic = "自动"
    case silent = "静音"
    case advanced = "高级"

    public var rawValueByte: UInt8 {
        switch self { case .automatic: 0x0D; case .silent: 0x1D; case .advanced: 0x8D }
    }
    public init?(rawValueByte: UInt8) {
        switch rawValueByte { case 0x0D: self = .automatic; case 0x1D: self = .silent; case 0x8D: self = .advanced; default: return nil }
    }
}

public struct ECFanCurve: Codable, Equatable, Sendable {
    public let temperatures: [UInt8]
    public let speeds: [UInt8]
    public init(temperatures: [UInt8], speeds: [UInt8]) {
        self.temperatures = temperatures; self.speeds = speeds
    }
    public var isValid: Bool {
        temperatures.count == 6 && speeds.count == 6 &&
        temperatures.allSatisfy { $0 <= 110 } && zip(temperatures, temperatures.dropFirst()).allSatisfy { $0 <= $1 } &&
        speeds.allSatisfy { $0 <= 150 }
    }
}

public struct ECFanCurveReceipt: Codable, Sendable {
    public let speeds: [UInt8]
    public let mode: UInt8
}

public struct ECCoolerBoostReceipt: Codable, Sendable {
    public let before: UInt8
    public let after: UInt8
}

public struct ECFanModeReceipt: Codable, Equatable, Sendable {
    public let mode: ECFanMode
    public let before: UInt8
    public let after: UInt8
    public var isVerified: Bool { after == mode.rawValueByte && ECFanMode(rawValueByte: before) != nil }
    public init(mode: ECFanMode, before: UInt8, after: UInt8) { self.mode = mode; self.before = before; self.after = after }
}

public struct ECBridgeSnapshot: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let driverVersion: String
    public let firmware: String
    public let chargeByte: UInt8?
    public let readAt: Date
    public var chargeLimit: Int? { chargeByte.flatMap(ECChargePolicy.decode) }
    public var canWriteChargeLimit: Bool {
        (2...8).contains(apiVersion) && (firmware != "15P2EMS1.110" || apiVersion >= 4) &&
        ECChargePolicy.supports(firmware) &&
        chargeByte.map(ECChargePolicy.validCurrent) == true
    }
    public init(apiVersion: Int = ECChargePolicy.apiVersion, driverVersion: String = "0.2.1",
                firmware: String, chargeByte: UInt8?, readAt: Date = Date()) {
        self.apiVersion = apiVersion
        self.driverVersion = driverVersion
        self.firmware = firmware
        self.chargeByte = chargeByte
        self.readAt = readAt
    }
}

public struct ECBatteryReading: Codable, Equatable, Sendable {
    public let designCapacity: Int
    public let fullChargeCapacity: Int
    public let remainingCapacity: Int
    public let voltageMillivolts: Int
    public let currentMilliamps: Int

    public init(designCapacity: Int, fullChargeCapacity: Int, remainingCapacity: Int,
                voltageMillivolts: Int, currentMilliamps: Int) {
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.remainingCapacity = remainingCapacity
        self.voltageMillivolts = voltageMillivolts
        self.currentMilliamps = currentMilliamps
    }

    public var percent: Int {
        Int((Double(remainingCapacity) / Double(fullChargeCapacity) * 100).rounded())
    }
}

public struct ECWriteReceipt: Codable, Equatable, Sendable {
    public let firmware: String
    public let percent: Int
    public let before: UInt8
    public let after: UInt8
    public var isVerified: Bool { ECChargePolicy.supports(firmware) && ECChargePolicy.encode(percent) == after }
    public init(firmware: String, percent: Int, before: UInt8, after: UInt8) {
        self.firmware = firmware; self.percent = percent; self.before = before; self.after = after
    }
}

public enum ECError: LocalizedError, Sendable {
    case unavailable(String)
    case system(operation: String, code: Int32)
    case invalid(String)
    case mismatch(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .invalid(message), let .mismatch(message): return message
        case let .system(operation, code):
            return "\(operation)失败（\(String(format: "0x%08X", UInt32(bitPattern: code)))）"
        }
    }
}
