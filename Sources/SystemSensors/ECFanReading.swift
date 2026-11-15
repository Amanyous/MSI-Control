import Foundation

public enum ECFanReading {
    public static func decode(high: UInt8, low: UInt8, address: String) -> SensorReading {
        let source = String(format: "EC %@=%02X:%02X · 实验性换算", address, high, low)
        // A stopped fan is a valid measurement: 00:00 means 0 RPM.
        guard high == 0 else {
            return SensorReading(value: nil, source: source, issue: "EC 测速格式未确认；\(source)")
        }
        if low == 0 {
            return SensorReading(value: 0, source: source, issue: nil)
        }
        let rpm = 478000.0 / Double(low)
        guard rpm <= 8000 else {
            return SensorReading(value: nil, source: source, issue: "EC 测速计数异常；\(source)")
        }
        return SensorReading(value: rpm, source: source, issue: nil)
    }
}
