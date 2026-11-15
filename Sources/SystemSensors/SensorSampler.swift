import Foundation

public struct SensorReading: Sendable, Codable {
    public let value: Double?
    public let source: String?
    public let issue: String?

    public init(value: Double?, source: String?, issue: String?) {
        self.value = value; self.source = source; self.issue = issue
    }

    public static let pending = SensorReading(value: nil, source: nil, issue: "Waiting for sample")

    public func formatted(decimals: Int = 1) -> String {
        value.map { String(format: "%.*f", decimals, $0) } ?? "—"
    }

    public func progress(maximum: Double) -> Double { min(1, max(0, (value ?? 0) / maximum)) }
}

public struct SensorSnapshot: Sendable, Codable {
    public let timestamp: Date
    public let temperature: SensorReading
    public let frequency: SensorReading
    public let fan: SensorReading
    public let fan2: SensorReading
    public let power: SensorReading

    public init(timestamp: Date, temperature: SensorReading, frequency: SensorReading,
                fan: SensorReading, fan2: SensorReading, power: SensorReading) {
        self.timestamp = timestamp
        self.temperature = temperature
        self.frequency = frequency
        self.fan = fan
        self.fan2 = fan2
        self.power = power
    }

    public static let pending = SensorSnapshot(timestamp: Date(), temperature: .pending, frequency: .pending, fan: .pending, fan2: .pending, power: .pending)
}

public actor SensorSampler {
    private var reader: SMCReader?
    public init() {}

    public func sample() -> SensorSnapshot {
        do {
            if reader == nil { reader = try SMCReader() }
            return Self.sample(reader: reader!)
        } catch {
            let missing = SensorReading(value: nil, source: nil, issue: String(describing: error))
            return SensorSnapshot(timestamp: Date(), temperature: missing, frequency: missing, fan: missing, fan2: missing, power: missing)
        }
    }

    package static func sample(reader: any SMCReading) -> SensorSnapshot {
        func measure(_ keys: [String], range: ClosedRange<Double>, scale: Double = 1) -> SensorReading {
            var issues: [String] = []
            for key in keys {
                do {
                    let value = try reader.read(key).number() * scale
                    guard range.contains(value) else { issues.append("\(key): out of range"); continue }
                    return SensorReading(value: value, source: "SMC \(key)", issue: nil)
                } catch { issues.append("\(key): \(error)") }
            }
            return SensorReading(value: nil, source: nil, issue: issues.joined(separator: "; "))
        }
        return SensorSnapshot(
            timestamp: Date(),
            temperature: measure(["TC0F", "TC0D", "TC0E", "TC0P", "TC0C"], range: 1...125),
            // These SMC counters expose the current effective clock in MHz.
            // Read them on every sensor tick instead of using powermetrics'
            // one-second average, matching Hackintool's live telemetry model.
            frequency: measure(["CCPA", "CCPC", "CC0A", "CC0C"], range: 0.05...10, scale: 0.001),
            fan: measure(["F0Ac"], range: 0...20000),
            fan2: measure(["F1Ac"], range: 0...20000),
            power: measure(["PCPR", "PCPT", "PCTR"], range: 0...500)
        )
    }
}
