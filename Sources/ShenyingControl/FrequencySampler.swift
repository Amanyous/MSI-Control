import Foundation
import SystemSensors

enum FrequencySampler {
    static func sample() throws -> SensorReading {
        // Fixed, read-only system command. Authorization is initiated by an explicit button.
        let script = "do shell script \"/usr/bin/powermetrics --samplers cpu_power -i 1000 -n 1\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return SensorReading(value: nil, source: nil, issue: String(decoding: errorData, as: UTF8.self))
        }
        guard let value = PowerMetrics.frequency(in: String(decoding: data, as: UTF8.self)) else {
            return SensorReading(value: nil, source: nil, issue: "powermetrics did not report absolute average CPU frequency")
        }
        return SensorReading(value: value, source: "powermetrics · " + Date().formatted(date: .omitted, time: .standard), issue: nil)
    }
}
