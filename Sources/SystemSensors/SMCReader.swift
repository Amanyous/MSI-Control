import Foundation
import IOKit

public enum SensorError: Error, Sendable, CustomStringConvertible {
    case unavailable, system(Int32), response(UInt8), malformed, unsupported(String)

    public var description: String {
        switch self {
        case .unavailable: "AppleSMC service unavailable"
        case .system(let code): String(format: "SMC IOKit error 0x%08X", UInt32(bitPattern: code))
        case .response(let code): String(format: "SMC response 0x%02X", code)
        case .malformed: "Invalid SMC response"
        case .unsupported(let type): "Unsupported SMC type: \(type)"
        }
    }
}

public struct SMCValue: Sendable {
    public let type: String
    public let bytes: [UInt8]

    public init(type: String, bytes: [UInt8]) { self.type = type; self.bytes = bytes }

    public func number() throws -> Double {
        let value: Double
        switch (type, bytes.count) {
        case ("ui8 ", 1): value = Double(bytes[0])
        case ("ui16", 2), ("ui32", 4):
            value = Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case ("flt ", 4):
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
            value = Double(Float(bitPattern: bits))
        default:
            let chars = Array(type.utf8)
            guard bytes.count == 2, chars.count == 4,
                  chars[0] == 115 || chars[0] == 102, chars[1] == 112,
                  let integerBits = Int(String(UnicodeScalar(chars[2])), radix: 16),
                  let fractionBits = Int(String(UnicodeScalar(chars[3])), radix: 16),
                  integerBits + fractionBits == (chars[0] == 115 ? 15 : 16) else {
                throw SensorError.unsupported(type)
            }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let signed = chars[0] == 115 ? Double(Int16(bitPattern: raw)) : Double(raw)
            value = signed / Double(1 << fractionBits)
        }
        guard value.isFinite else { throw SensorError.malformed }
        return value
    }
}

package protocol SMCReading {
    func read(_ key: String) throws -> SMCValue
}

// AppleSMC's 80-byte SMCKeyData ABI, with explicit offsets rather than Swift struct padding.
// Only command 9 (metadata) and command 5 (read bytes) are exposed.
final class SMCReader: SMCReading {
    private var connection: io_connect_t = 0

    init() throws {
        guard let matching = IOServiceMatching("AppleSMC") else { throw SensorError.unavailable }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw SensorError.unavailable }
        defer { IOObjectRelease(service) }
        let code = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard code == KERN_SUCCESS else { throw SensorError.system(code) }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read(_ key: String) throws -> SMCValue {
        guard key.utf8.count == 4 else { throw SensorError.malformed }
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let metadata = try call(key: code, command: 9)
        let size = Self.word(metadata, at: 28)
        guard (1...32).contains(size) else { throw SensorError.malformed }
        let typeCode = Self.word(metadata, at: 32)
        let type = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: typeCode >> $0) }, encoding: .ascii) ?? ""
        let result = try call(key: code, command: 5, size: size)
        return SMCValue(type: type, bytes: Array(result[48..<(48 + Int(size))]))
    }

    private func call(key: UInt32, command: UInt8, size: UInt32 = 0) throws -> [UInt8] {
        var input = [UInt8](repeating: 0, count: 80)
        for (offset, value) in [(0, key), (28, size)] {
            for index in 0..<4 { input[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        input[42] = command
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count
        let code = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, source.count, destination.baseAddress, &outputSize)
            }
        }
        guard code == KERN_SUCCESS else { throw SensorError.system(code) }
        guard outputSize == 80 else { throw SensorError.malformed }
        guard output[40] == 0 else { throw SensorError.response(output[40]) }
        return output
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}
