import ECControl
import Foundation

public enum PowerServiceIdentity {
    public static let name = "org.shenying.mcontrol.power"
    public static let plist = name + ".plist"
    public static let executable = "MSIPowerService"
    public static let version = 1
    private static let certificate = "48d7b07ac770e67a5b828754b5466e29fbc14560"
    public static let appRequirement =
        "identifier \"org.shenying.mcontrol\" and certificate leaf = H\"\(certificate)\""
    public static let serviceRequirement =
        "identifier \"\(name)\" and certificate leaf = H\"\(certificate)\""
}

@objc public protocol PowerServiceProtocol {
    func ping(reply: @escaping (Int) -> Void)
    func apply(_ request: Data, reply: @escaping (Data?, String?) -> Void)
    func control(_ request: Data, reply: @escaping (Data?, String?) -> Void)
}

public enum HardwareServiceRequest: Codable, Sendable {
    case fan(FanServiceRequest)
    case efi(EFIServiceRequest)
}

public enum FanServiceRequest: Codable, Sendable {
    case mode(ECFanMode, expected: UInt8, firmware: String)
    case curve(fan: Int, expected: ECFanCurve, speeds: [UInt8], mode: UInt8, firmware: String)
    case boost(Bool, expected: UInt8, firmware: String)

    public func validate() throws {
        switch self {
        case let .mode(mode, expected, firmware):
            guard let profile = ECFeatureProfile.match(firmware),
                  mode == .automatic || mode == .advanced,
                  profile.fanModes.contains(mode.rawValueByte),
                  profile.fanModes.contains(expected) else {
                throw ECError.invalid("风扇模式请求无效")
            }
        case let .curve(fan, expected, speeds, mode, firmware):
            guard (0...1).contains(fan), firmware == "15P2EMS1.110",
                  mode == ECFanMode.advanced.rawValueByte, expected.isValid,
                  ECFanCurve(temperatures: expected.temperatures, speeds: speeds).isValid,
                  speeds.allSatisfy({ (20...150).contains($0) }) else {
                throw ECError.invalid("风扇曲线请求无效")
            }
        case let .boost(_, _, firmware):
            guard ECFeatureProfile.match(firmware) != nil else {
                throw ECError.invalid("强冷请求无效")
            }
        }
    }

    public func execute(on bridge: ECBridgeConnection) throws -> Data {
        try validate()
        switch self {
        case let .mode(mode, expected, firmware):
            guard try bridge.firmware() == firmware else { throw ECError.mismatch("EC 固件已变化") }
            return try JSONEncoder().encode(bridge.setFanMode(mode, expected: expected))
        case let .curve(fan, expected, speeds, mode, firmware):
            guard try bridge.firmware() == firmware,
                  try bridge.fanCurve(fan: fan) == expected,
                  try bridge.readByte(at: 0xD4) == mode else {
                throw ECError.mismatch("EC 曲线或模式已变化，请重新读取")
            }
            return try JSONEncoder().encode(bridge.setFanCurve(fan: fan, expected: expected, speeds: speeds, expectedMode: mode))
        case let .boost(enabled, expected, firmware):
            guard try bridge.firmware() == firmware,
                  let profile = ECFeatureProfile.match(firmware),
                  try bridge.readByte(at: profile.fanAddress) == ECFanMode.advanced.rawValueByte else {
                throw ECError.mismatch("请先应用手动模式并重新读取")
            }
            return try JSONEncoder().encode(bridge.setCoolerBoost(enabled, expected: expected))
        }
    }
}

public struct PowerServiceRequest: Codable, Sendable {
    public let version: Int
    public let mode: Int
    public let eco: Bool
    public let expectedWords: [UInt64]

    public init(preset: CPUPowerPreset?, eco: Bool, expected: CPUPowerControlStatus) {
        version = PowerServiceIdentity.version
        mode = preset?.rawValue ?? 5
        self.eco = eco
        expectedWords = expected.words
    }

    public func validatedStatus() throws -> CPUPowerControlStatus {
        guard version == PowerServiceIdentity.version, (0...5).contains(mode),
              !eco || mode == CPUPowerPreset.energySaving.rawValue else {
            throw ECError.invalid("功耗助手请求格式无效")
        }
        return try CPUPowerControlStatus(words: expectedWords)
    }

    public func validateCurrent(_ current: CPUPowerControlStatus) throws {
        let expected = try validatedStatus()
        guard current.generation == expected.generation, current.current == expected.current,
              current.shift == expected.shift, current.fan == expected.fan else {
            throw ECError.mismatch("功耗或 EC 状态已变化，未写入；请重新读取")
        }
    }
}

public struct SavedPowerSelection: Codable, Equatable, Sendable {
    public let mode: Int
    public let eco: Bool
    public var preset: CPUPowerPreset? { CPUPowerPreset(rawValue: mode) }

    public init(preset: CPUPowerPreset, eco: Bool) {
        mode = preset.rawValue
        self.eco = preset == .energySaving && eco
    }

    public static func load(from defaults: UserDefaults) -> SavedPowerSelection? {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.preset != nil, !value.eco || value.preset == .energySaving else { return nil }
        return value
    }

    public static func saveVerified(_ selection: Self?, to defaults: UserDefaults) {
        if let selection, let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static let key = "mcontrol.lastVerifiedPowerSelection"
}
