import Foundation
import ECControl
import SystemSensors

@main
struct SensorProbe {
    static func main() async throws {
        if CommandLine.arguments.contains("--scan-ec-battery") {
            let battery = BatteryStatus.readSystem()
            let connection = try ECBridgeConnection()
            var values: [String: UInt8] = [:]
            for address in 0...255 {
                if let value = try? connection.readByte(at: UInt8(address)) {
                    values[String(format: "%02X", address)] = value
                }
            }
            let result: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "systemBattery": [
                    "percent": battery.percent as Any,
                    "charging": battery.isCharging,
                    "externalPower": battery.externalPower,
                    "present": battery.isPresent
                ],
                "ec": values
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
            return
        }
        if CommandLine.arguments.contains("--parse-frequency") {
            let output = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            guard let frequency = PowerMetrics.frequency(in: output) else { throw SensorError.malformed }
            print(String(format: "Measured system average CPU frequency: %.4f GHz", frequency))
            return
        }
        let sampler = SensorSampler()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        for index in 0..<3 {
            if index > 0 { try await Task.sleep(for: .seconds(1)) }
            let snapshot = await sampler.sample()
            print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        }
    }
}
