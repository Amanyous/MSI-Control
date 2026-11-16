import Foundation

public struct ECNamedMode: Sendable, Codable, Equatable, Identifiable {
    public let name: String
    public let value: UInt8
    public var id: UInt8 { value }
    public init(name: String, value: UInt8) { self.name = name; self.value = value }
}

public enum ECCommonFeature: UInt64, Codable, Sendable, CaseIterable {
    case webcam, winKeyLeft, shift, fan
}

public struct ECCommonReceipt: Codable, Sendable {
    public let firmware: String
    public let feature: ECCommonFeature
    public let desired: UInt8
    public let before: UInt8
    public let after: UInt8
}

public struct ECCommonSnapshot: Sendable {
    public let firmware: String
    public let api: Int
    public let profile: ECFeatureProfile
    public let webcam: UInt8?
    public let webcamBlock: UInt8?
    public let fnWin: UInt8?
    public let shift: UInt8?
    public let fan: UInt8?
    public let cpuTemperature: UInt8?
    public let gpuTemperature: UInt8?
    public let cpuFan: UInt8?
    public let gpuFan: UInt8?
    public var webcamEnabled: Bool? { webcam.map { $0 & (1 << profile.webcamBit) != 0 } }
    public var webcamBlocked: Bool? { webcamBlock.map { $0 & (1 << profile.webcamBit) == 0 } }
    public var winKeyLeft: Bool? {
        fnWin.map { ($0 & (1 << profile.fnWinBit) != 0) != profile.fnWinInverted }
    }
    public func rawValue(for feature: ECCommonFeature) -> UInt8? {
        switch feature { case .webcam: webcam; case .winKeyLeft: fnWin; case .shift: shift; case .fan: fan }
    }
}

public enum ECCommonPolicy {
    public static func target(profile: ECFeatureProfile, feature: ECCommonFeature,
                              desired: UInt8, current: UInt8) -> UInt8? {
        switch feature {
        case .webcam, .winKeyLeft:
            let address = feature == .webcam ? profile.webcamAddress : profile.fnWinAddress
            guard address != nil, desired <= 1 else { return nil }
            let bit = feature == .webcam ? profile.webcamBit : profile.fnWinBit
            guard bit < 8 else { return nil }
            let inverted = feature == .winKeyLeft && profile.fnWinInverted
            let mask: UInt8 = 1 << bit
            let set = (desired == 1) != inverted
            return (current & ~mask) | (set ? mask : 0)
        case .shift, .fan:
            let modes = feature == .shift ? profile.shiftModes : profile.namedFanModes
            guard (feature != .shift || profile.shiftAddress != nil),
                  modes.contains(where: { $0.value == desired }),
                  modes.contains(where: { $0.value == current }) else { return nil }
            return desired
        }
    }
}

extension ECBridgeConnection {
    public func commonSnapshot() throws -> ECCommonSnapshot {
        let identity = try firmware()
        guard let profile = ECFeatureProfile.match(identity) else {
            throw ECError.unavailable("No msi-ec profile for \(identity)")
        }
        func optionalRead(_ address: UInt8?) -> UInt8? { address.flatMap { try? readByte(at: $0) } }
        return ECCommonSnapshot(
            firmware: identity, api: apiVersion, profile: profile,
            webcam: optionalRead(profile.webcamAddress), webcamBlock: optionalRead(profile.webcamBlockAddress),
            fnWin: optionalRead(profile.fnWinAddress), shift: optionalRead(profile.shiftAddress),
            fan: optionalRead(profile.fanAddress), cpuTemperature: optionalRead(profile.cpuTemperatureAddress),
            gpuTemperature: optionalRead(profile.gpuTemperatureAddress),
            cpuFan: optionalRead(profile.cpuFanAddress), gpuFan: optionalRead(profile.gpuFanAddress)
        )
    }

    public func setCommonFeature(_ feature: ECCommonFeature, desired: UInt8, expected: UInt8) throws -> ECCommonReceipt {
        guard apiVersion >= 11 else { throw ECError.unavailable("Common EC controls require API 11 / MSIECBridge 0.3.8.") }
        let identity = try firmware()
        guard let profile = ECFeatureProfile.match(identity),
              let target = ECCommonPolicy.target(profile: profile, feature: feature, desired: desired, current: expected) else {
            throw ECError.invalid("Unsupported EC feature or mode")
        }
        let output = try callCommonFeature(feature: feature.rawValue, desired: UInt64(desired), expected: UInt64(expected))
        guard output == [UInt64(expected), UInt64(target)] else {
            throw ECError.mismatch("EC readback mismatch; refresh before retrying.")
        }
        return ECCommonReceipt(firmware: identity, feature: feature, desired: desired,
                               before: expected, after: target)
    }
}
