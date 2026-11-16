import Foundation
import IOKit

public enum CPUPowerPreset: Int, CaseIterable, Sendable {
    case energySaving, quiet, balanced, performance, extreme
    public var watts: (Int, Int) {
        switch self {
        case .energySaving: (25, 35)
        case .quiet: (35, 55)
        case .balanced: (45, 65)
        case .performance: (55, 80)
        case .extreme: (65, 90)
        }
    }
}

public struct CPUPowerControlStatus: Sendable {
    public let words: [UInt64]
    public init(words: [UInt64]) throws {
        guard words.count == 14, words[0] == 1, words[1] & ~63 == 0,
              words[7] <= 5, words[8...11].allSatisfy({ $0 <= 255 }),
              words[12] <= 3, words[13] == 0 else {
            throw ECError.invalid("CPU 功耗状态格式异常")
        }
        self.words = words
    }
    public var available: Bool { words[1] & 1 != 0 }
    public var captured: Bool { words[1] & 2 != 0 }
    public var owned: Bool { words[1] & 12 != 0 }
    public var conflict: Bool { words[1] & 16 != 0 }
    public var generation: UInt64 { words[2] }
    public var current: UInt64 { words[4] }
    public var shift: UInt8 { UInt8(words[8]) }
    public var fan: UInt8 { UInt8(words[9]) }
    public var preset: CPUPowerPreset? { CPUPowerPreset(rawValue: Int(words[7])) }
    public var originalWatts: (Double, Double)? { captured ? watts(words[5]) : nil }
    public var currentWatts: (Double, Double) { watts(current) }
    private func watts(_ raw: UInt64) -> (Double, Double) {
        let unit = pow(2, -Double(words[3] & 15))
        return (Double(raw & 0x7FFF) * unit, Double((raw >> 32) & 0x7FFF) * unit)
    }
}

public struct CPUPowerReceipt: Codable, Sendable {
    public let outcome: UInt64
    public let package: UInt64
    public let shift: UInt8
    public let fan: UInt8
    public var verified: Bool { outcome == 0 }
}

extension ECBridgeConnection {
    public func powerControlStatus() throws -> CPUPowerControlStatus {
        guard apiVersion >= 13 else {
            throw ECError.unavailable("CPU 功耗控制需要 MSIECBridge 0.4.0 / API 13，更新驱动并重启后可用；频率和风扇读取不受影响。")
        }
        var output = [UInt64](repeating: 0, count: 14)
        var count: UInt32 = 14
        let code = output.withUnsafeMutableBufferPointer {
            IOConnectCallScalarMethod(connection, 13, nil, 0, $0.baseAddress, &count)
        }
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "读取 CPU 功耗状态", code: code) }
        guard count == 14 else { throw ECError.invalid("CPU 功耗响应长度异常") }
        return try CPUPowerControlStatus(words: output)
    }

    public func setPowerPreset(_ preset: CPUPowerPreset?, eco: Bool,
                               expected: CPUPowerControlStatus) throws -> CPUPowerReceipt {
        guard apiVersion >= 13, expected.available, (!expected.conflict || preset == nil),
              !eco || preset == .energySaving else {
            throw ECError.unavailable("功耗控制不可用或发生外部策略冲突，未写入")
        }
        if preset == .extreme && !BatteryStatus.readSystem().externalPower {
            throw ECError.unavailable("极致档仅支持接通电源时使用")
        }
        let input: [UInt64] = [UInt64(preset?.rawValue ?? 5), eco ? 1 : 0,
                               expected.generation, expected.current,
                               UInt64(expected.shift), UInt64(expected.fan)]
        var output = [UInt64](repeating: 0, count: 4)
        var count: UInt32 = 4
        let code = input.withUnsafeBufferPointer { values in
            output.withUnsafeMutableBufferPointer {
                IOConnectCallScalarMethod(connection, 14, values.baseAddress, 6, $0.baseAddress, &count)
            }
        }
        guard code == KERN_SUCCESS else {
            throw ECError.system(operation: "功耗事务被拒绝；请重新读取状态", code: code)
        }
        guard count == 4, output[0] <= 3, output[2] <= 255, output[3] <= 255 else {
            throw ECError.invalid("功耗事务回执异常，请重新读取；不能确认是否已恢复")
        }
        return CPUPowerReceipt(outcome: output[0], package: output[1],
                               shift: UInt8(output[2]), fan: UInt8(output[3]))
    }
}
