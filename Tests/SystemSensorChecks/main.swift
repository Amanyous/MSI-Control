import Foundation
import SystemSensors

struct FakeSMC: SMCReading {
    let values: [String: SMCValue]
    func read(_ key: String) throws -> SMCValue {
        guard let value = values[key] else { throw SensorError.response(0x84) }
        return value
    }
}

@main
struct SensorChecks {
    static func main() throws {
        let fixtures: [(String, [UInt8], Double)] = [
            ("sp78", [0x32, 0x80], 50.5), ("sp78", [0xff, 0x80], -0.5),
            ("sp96", [0x12, 0x80], 74), ("fpe2", [0x2e, 0xe0], 3000),
            ("ui8 ", [0], 0), ("ui16", [0x12, 0x34], 4660),
            ("ui32", [0, 0, 0x13, 0x88], 5000), ("flt ", [0, 0, 0x48, 0x42], 50)
        ]
        for (type, bytes, expected) in fixtures {
            let actual = try SMCValue(type: type, bytes: bytes).number()
            precondition(abs(actual - expected) < 0.0001, "\(type): \(actual) != \(expected)")
        }
        for (type, bytes) in [("ui32", [UInt8(0)]), ("sp78", []), ("fpff", [0, 0]), ("flt ", [0, 0, 0x80, 0x7f]), ("xxxx", [0, 0])] {
            do { _ = try SMCValue(type: type, bytes: bytes).number(); fatalError("Invalid value accepted") }
            catch { }
        }
        precondition(PowerMetrics.frequency(in: "CPU Average frequency: 2345.5 MHz") == 2.3455)
        precondition(PowerMetrics.frequency(in: "Average frequency as fraction of nominal: 3500 MHz (150%)") == 3.5)
        precondition(PowerMetrics.frequency(in: "Average frequency as fraction of nominal: 150%") == nil)
        precondition(PowerMetrics.frequency(in: "CPU Average frequency: 99999 MHz") == nil)
        precondition(abs(PowerMetrics.frequency(in: "header\rSystem Average frequency as fraction of nominal: 62.46% (1436.60 Mhz)\rCPU Average frequency as fraction of nominal: 162.22% (3730.96 Mhz)")! - 1.4366) < 0.000001)
        precondition(ECFanReading.decode(high: 0, low: 160, address: "C8:C9").value == 2987.5)
        precondition(ECFanReading.decode(high: 1, low: 160, address: "C8:C9").value == nil)
        precondition(ECFanReading.decode(high: 0, low: 0, address: "C8:C9").value == nil)
        precondition(ECFanReading.decode(high: 0, low: 1, address: "C8:C9").value == nil)
        let sample = SensorSampler.sample(reader: FakeSMC(values: [
            "TC0F": SMCValue(type: "sp78", bytes: [0xff, 0xff]),
            "TC0D": SMCValue(type: "sp78", bytes: [60, 0]),
            "F0Ac": SMCValue(type: "fpe2", bytes: [0, 0]),
            "F1Ac": SMCValue(type: "fpe2", bytes: [0x3e, 0x80]),
            "CCPC": SMCValue(type: "ui32", bytes: [0, 0, 0x0f, 0xa0]),
            "PCPR": SMCValue(type: "sp96", bytes: [0x12, 0x80])
        ]))
        precondition(sample.temperature.value == 60 && sample.temperature.source == "SMC TC0D")
        precondition(sample.frequency.value == 4)
        precondition(sample.fan.value == 0)
        precondition(sample.fan2.value == 4000 && sample.fan2.source == "SMC F1Ac")
        precondition(sample.power.value == 74)
        let missing = SensorSampler.sample(reader: FakeSMC(values: [:]))
        precondition(missing.temperature.value == nil && missing.fan.value == nil && missing.power.value == nil)
        precondition(missing.frequency.value == nil && missing.frequency.issue?.contains("0x84") == true)
        precondition(missing.fan2.value == nil && missing.fan2.issue?.contains("F1Ac") == true)
        let stopped = SensorSampler.sample(reader: FakeSMC(values: ["F1Ac": SMCValue(type: "fpe2", bytes: [0, 0])]))
        precondition(stopped.fan2.value == 0 && stopped.fan.value == nil)
        let invalid = SensorSampler.sample(reader: FakeSMC(values: ["F1Ac": SMCValue(type: "ui16", bytes: [0xff, 0xff])]))
        precondition(invalid.fan2.value == nil && invalid.fan2.issue?.contains("out of range") == true)
        print("28 sensor decoding, independent fans, fallback, zero, missing-data and frequency parsing checks passed")
    }
}
