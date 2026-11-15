import ECControl
import Foundation

enum PerformanceAdministrator {
    static func read() throws -> (UInt8, UInt8) { try ECBridgeConnection().performanceBytes() }

    static func apply(_ profile: Int, expected: (UInt8, UInt8)) throws -> (UInt8, UInt8) {
        let connection = try ECBridgeConnection()
        guard connection.apiVersion >= 5, try connection.performanceBytes() == expected else {
            throw ECError.mismatch("EC 性能档已变化或驱动过旧，请重新读取")
        }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "MSIECHelper"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw ECError.unavailable("应用缺少 EC 写入助手") }
        let command = ([helper.path, "set-performance", String(profile), String(expected.0), String(expected.1)])
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ECError.unavailable(String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "性能档写入失败")
        }
        let receipt = try JSONDecoder().decode([UInt8].self, from: data)
        guard receipt.count == 2 else { throw ECError.mismatch("性能档回执异常") }
        return (receipt[0], receipt[1])
    }
}
