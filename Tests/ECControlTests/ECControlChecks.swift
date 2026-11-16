import Foundation
import IOKit.ps

@main
struct ECControlChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ description: String) {
            precondition(condition, description)
            checks += 1
        }
        check(BatteryStatus.from(description: ["Voltage": 16000, "Current": -2000]).powerWatts == -32, "Standard discharge current")
        check(BatteryStatus.from(description: ["Voltage": 16000, "Current": 2000, kIOPSIsChargingKey as String: true]).powerWatts == 32, "Charging power")
        check(BatteryStatus.from(description: ["Voltage": 16000, "Current": 0]).powerWatts == 0, "Zero current")
        for api in 4...9 {
            check(ECBridgeSnapshot(apiVersion: api, firmware: "15P2EMS1.110", chargeByte: 0xD0).canWriteChargeLimit, "Supported API \(api)")
            check(!ECBridgeSnapshot(apiVersion: api, firmware: "15P2EMS1.110", chargeByte: 0xFF).canWriteChargeLimit, "Invalid byte stays blocked")
        }
        check(!ECBridgeSnapshot(apiVersion: 12, firmware: "15P2EMS1.110", chargeByte: 0xD0).canWriteChargeLimit, "Unknown API stays blocked")
        check(ECBridgeSnapshot(apiVersion: 10, firmware: "14C1EMS1.199", chargeByte: 0xD0).canWriteChargeLimit, "Imported family")
        check(!ECBridgeSnapshot(apiVersion: 9, firmware: "14C1EMS1.199", chargeByte: 0xD0).canWriteChargeLimit, "Old kernel cannot write imported family")
        check(ECFeatureProfile.match("14C1EMS1.199")?.chargeAddress == 0xEF, "Gen1 address")
        check(ECFeatureProfile.match("15P2EMS1.199")?.chargeAddress == 0xD7, "Gen2 address")
        check(!ECChargePolicy.supports("16P5EMS1.199"), "Unsupported charging")
        check(ECChargePolicy.supports("15P4EMS1.106"), "Patch versions share upstream family")
        check(abs(BatteryStatus.health(fullChargeCapacity: 5159, designCapacity: 5700)! - 90.5087719) < 0.0001, "Raw capacity health")
        check(BatteryStatus.health(fullChargeCapacity: 100, designCapacity: 5700) == nil, "Reject normalized percentage")
        check(BatteryStatus.health(fullChargeCapacity: nil, designCapacity: 5700) == nil, "Missing capacity")
        check(BatteryStatus.health(fullChargeCapacity: 5159, designCapacity: 0) == nil, "Invalid design capacity")
        for percent in -1...256 {
            let encoded = ECChargePolicy.encode(percent)
            if (10...100).contains(percent) {
                check(encoded == UInt8(percent) | 0x80, "Charge encoding \(percent)")
                check(ECChargePolicy.decode(encoded!) == percent, "Charge round trip \(percent)")
            } else {
                check(encoded == nil, "Out-of-range percent \(percent)")
            }
        }
        check(ECChargePolicy.encode(60) == 0xBC, "60% MSI Center capture")
        check(ECChargePolicy.encode(80) == 0xD0, "80% MSI Center capture")
        check(ECChargePolicy.encode(100) == 0xE4, "100% MSI Center capture")
        for number in 0...255 {
            let raw = UInt8(number)
            let expected = (10...100).contains(number & 0x7F)
            check((ECChargePolicy.decode(raw) != nil) == expected, "Decode byte \(number)")
            check(ECChargePolicy.validCurrent(raw) == (raw & 0x80 != 0 && (raw == 0x80 || expected)), "Current byte \(number)")
        }
        for (input, value) in [("D7", 0xD7), ("0xd0", 0xD0), (" 0Xff\n", 0xFF), ("0", 0), ("a", 10)] {
            check(ECChargePolicy.parseByte(input) == UInt8(value), "Hex parse \(input)")
        }
        for input in ["", "0x", "100", "-1", "+1", "D 7", "GG", "0xx1", "１２", "0x001", "$(id)", ";"] {
            check(ECChargePolicy.parseByte(input) == nil, "Invalid hex input \(input)")
        }
        for firmware in ["15P2EMS1.110", "15P4EMS1.105", "15P4EMS1.107"] {
            check(ECChargePolicy.supports(firmware), "Supported firmware")
            check(ECChargePolicy.firmware(from: Array(firmware.utf8)) == firmware, "Firmware bytes")
        }
        for firmware in ["15P4EMS1.107x", "15p4ems1.107", "15P4EMS1.07", "", "15P4EMS1.107 "] {
            check(!ECChargePolicy.supports(firmware), "Exact firmware allowlist")
        }
        check(ECChargePolicy.firmware(from: Array("15P4EMS1.107".utf8) + [0]) == nil, "Firmware length")
        check(ECChargePolicy.firmware(from: [UInt8](repeating: 0, count: 12)) == nil, "Nonprintable firmware")
        let good = ECBridgeSnapshot(firmware: "15P4EMS1.107", chargeByte: 0xD0)
        check(good.canWriteChargeLimit && good.chargeLimit == 80, "Matched snapshot")
        check(ECBridgeSnapshot(apiVersion: 4, driverVersion: "0.3.1", firmware: "15P2EMS1.110", chargeByte: 0xD0).canWriteChargeLimit, "Local firmware with API 4")
        check(!ECBridgeSnapshot(apiVersion: 3, firmware: "15P2EMS1.110", chargeByte: 0xD0).canWriteChargeLimit, "Local firmware requires API 4")
        check(!ECBridgeSnapshot(apiVersion: 0, firmware: good.firmware, chargeByte: 0xD0).canWriteChargeLimit, "Old API")
        check(!ECBridgeSnapshot(firmware: "unknown", chargeByte: 0xD0).canWriteChargeLimit, "Unknown firmware")
        check(!ECBridgeSnapshot(firmware: good.firmware, chargeByte: nil).canWriteChargeLimit, "Missing register")
        check(!ECBridgeSnapshot(firmware: good.firmware, chargeByte: 0xFF).canWriteChargeLimit, "Invalid register")
        let unreported = ECBridgeSnapshot(firmware: good.firmware, chargeByte: 0x80)
        check(unreported.canWriteChargeLimit && unreported.chargeLimit == nil, "Unknown limit encoding")
        let receipt = ECWriteReceipt(firmware: good.firmware, percent: 60, before: 0xD0, after: 0xBC)
        check(receipt.isVerified, "Verified receipt")
        check(!ECWriteReceipt(firmware: "unknown", percent: 60, before: 0xD0, after: 0xBC).isVerified, "Unknown receipt firmware")
        check(!ECWriteReceipt(firmware: good.firmware, percent: 60, before: 0xD0, after: 0xD0).isVerified, "Mismatched readback")
        check(!ECWriteReceipt(firmware: good.firmware, percent: 101, before: 0xD0, after: 0xE5).isVerified, "Invalid receipt percent")
        check(try JSONDecoder().decode(ECWriteReceipt.self, from: JSONEncoder().encode(receipt)) == receipt, "Helper JSON round trip")
        check(try JSONDecoder().decode(ECBridgeSnapshot.self, from: JSONEncoder().encode(good)) == good, "Snapshot JSON round trip")
        check(ECError.system(operation: "读取", code: Int32(bitPattern: 0xE00002C5)).localizedDescription.contains("0xE00002C5"), "Preserve IOKit code")
        check(ECFanMode.automatic.rawValueByte == 0x0D && ECFanMode.silent.rawValueByte == 0x1D && ECFanMode.advanced.rawValueByte == 0x8D, "Fan mode encoding")
        for value in [UInt8(0x0D), UInt8(0x1D), UInt8(0x8D)] { check(ECFanMode(rawValueByte: value) != nil, "Fan mode decoding") }
        check(ECFanMode(rawValueByte: 0x2D) == nil, "Reject unknown fan mode")
        check(ECFanModeReceipt(mode: .silent, before: 0x0D, after: 0x1D).isVerified, "Verified fan mode receipt")
        check(!ECFanModeReceipt(mode: .silent, before: 0x0D, after: 0x0D).isVerified, "Reject mismatched fan mode receipt")

        let charging: [String: Any] = [kIOPSIsPresentKey: true, kIOPSCurrentCapacityKey: 42,
            kIOPSMaxCapacityKey: 80, kIOPSIsChargingKey: true, kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        let status = BatteryStatus.from(description: charging)
        check(status.percent == 53 && status.isPresent && status.isCharging && status.externalPower, "IOPS capacity normalization")
        check(BatteryStatus.from(description: [kIOPSCurrentCapacityKey: 72, kIOPSMaxCapacityKey: 100]).percent == 72, "IOPS percent units")
        for (current, max) in [(0, 0), (-1, 100), (101, 100), (1, -1)] {
            check(BatteryStatus.from(description: [kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: max]).percent == nil, "Invalid capacity")
        }
        check(BatteryStatus.from(description: [kIOPSIsPresentKey: false, kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 100]).percent == nil, "Absent battery")
        check(BatteryStatus.from(description: [:]).percent == nil, "Missing capacity")
        print("\(checks) EC policy, codec and battery parser checks passed; no hardware accessed.")
    }
}
