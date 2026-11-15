import Foundation
import IOKit.ps
import IOKit

public struct BatteryStatus: Equatable, Sendable {
    public let percent: Int?
    public let isCharging: Bool
    public let externalPower: Bool
    public let isPresent: Bool
    public let healthPercent: Double?
    public let powerWatts: Double?
    public let source: String

    public init(percent: Int? = nil, isCharging: Bool = false, externalPower: Bool = false, isPresent: Bool = false, healthPercent: Double? = nil, powerWatts: Double? = nil, source: String = "系统") {
        self.percent = percent; self.isCharging = isCharging
        self.externalPower = externalPower; self.isPresent = isPresent
        self.healthPercent = healthPercent
        self.powerWatts = powerWatts
        self.source = source
    }

    public static func health(fullChargeCapacity: Int?, designCapacity: Int?) -> Double? {
        guard let fullChargeCapacity, let designCapacity,
              fullChargeCapacity > 0, designCapacity > 100,
              fullChargeCapacity > 100 else { return nil }
        let result = Double(fullChargeCapacity) / Double(designCapacity) * 100
        return result <= 150 ? result : nil
    }

    public static func from(description: [String: Any], healthPercent: Double? = nil) -> BatteryStatus {
        let present = description[kIOPSIsPresentKey as String] as? Bool ?? true
        let current = description[kIOPSCurrentCapacityKey as String] as? Int
        let maximum = description[kIOPSMaxCapacityKey as String] as? Int
        let percent: Int?
        if present, let current, let maximum, maximum > 0, current >= 0, current <= maximum {
            percent = Int((Double(current) / Double(maximum) * 100).rounded())
        } else { percent = nil }
        let charging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        let externalPower = description[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue as String
        let voltage = (description[kIOPSVoltageKey as String] as? NSNumber)?.doubleValue
        let amperage = (description[kIOPSCurrentKey as String] as? NSNumber)?.doubleValue
            ?? (description["Amperage"] as? NSNumber)?.doubleValue
        let powerWatts: Double?
        if present, let voltage, let amperage, voltage.isFinite, amperage.isFinite,
           voltage > 0, voltage <= 60000, abs(amperage) <= 50000 {
            let magnitude = abs(voltage * amperage) / 1_000_000
            powerWatts = amperage == 0 ? 0 : (charging ? magnitude : -magnitude)
        } else {
            powerWatts = nil
        }
        return BatteryStatus(percent: percent, isCharging: charging,
                             externalPower: externalPower, isPresent: present,
                             healthPercent: present ? healthPercent : nil,
                             powerWatts: powerWatts)
    }

    private static func readHealth() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = raw?.takeRetainedValue() as? [String: Any] else { return nil }
        let design = properties["DesignCapacity"] as? Int
        // MaxCapacity can be a normalized percentage; prefer the raw mAh field.
        let full = properties["AppleRawMaxCapacity"] as? Int ?? properties["MaxCapacity"] as? Int
        return health(fullChargeCapacity: full, designCapacity: design)
    }

    public static func readSystem() -> BatteryStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return BatteryStatus() }
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue(),
                  let value = raw as? [String: Any],
                  value[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType as String else { continue }
            return from(description: value, healthPercent: readHealth())
        }
        return BatteryStatus()
    }
}
