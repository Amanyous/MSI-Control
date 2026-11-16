import Foundation

public struct CPUPowerSnapshot {
    public let words: [UInt64]
    public init(words: [UInt64]) throws {
        let allowed: UInt64 = (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 13)
        guard words.count == 16, words[0] == 1, words[15] == 0,
              words[1] & ~allowed == 0,
              words[2...8].allSatisfy({ $0 <= UInt32.max }), words[14] <= UInt32.max,
              (9...13).allSatisfy({ words[1] & (1 << $0) != 0 || words[$0] == 0 }) else {
            throw ECError.invalid("Invalid CPU snapshot")
        }
        self.words = words
    }

    public func register(_ index: Int) -> UInt64? {
        guard (9...13).contains(index), words[1] & (1 << index) != 0 else { return nil }
        return words[index]
    }

    public var vendor: String {
        String(bytes: words[2...4].flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }, encoding: .ascii) ?? "unknown"
    }
    public var family: UInt64 {
        let base = (words[6] >> 8) & 15
        return base == 15 ? base + ((words[6] >> 20) & 255) : base
    }
    public var model: UInt64 {
        let base = (words[6] >> 8) & 15
        return ((words[6] >> 4) & 15) | ((base == 6 || base == 15) ? (words[6] >> 12) & 240 : 0)
    }
    public var hwpSupported: Bool { words[7] & (1 << 7) != 0 }
    public var eppSupported: Bool { words[7] & (1 << 10) != 0 }
    public var packageLocked: Bool? { register(13).map { $0 & (1 << 63) != 0 } }
    public var wattsPerUnit: Double? { register(12).map { pow(2, -Double($0 & 15)) } }
    public var secondsPerUnit: Double? { register(12).map { pow(2, -Double(($0 >> 16) & 15)) } }
    public func limit(short: Bool) -> (watts: Double, enabled: Bool, clamp: Bool, seconds: Double)? {
        guard let raw = register(13), let power = wattsPerUnit, let time = secondsPerUnit else { return nil }
        let value = raw >> (short ? 32 : 0)
        let window = (value >> 17) & 127
        return (Double(value & 0x7fff) * power, value & (1 << 15) != 0,
                value & (1 << 16) != 0,
                pow(2, Double(window & 31)) * (1 + Double(window >> 5) / 4) * time)
    }
}
