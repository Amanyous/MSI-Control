import Foundation
import IOKit

public struct GPUStatus: Sendable {
    public let temperature: Double?
    public let coreUsage: Double?
    public let videoDecodeUsage: Double?
    public let memoryUsage: Double?
    public let memoryUsedBytes: Double?
    public let memoryTotalBytes: Double?

    public static func read() -> GPUStatus? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let bundle = IORegistryEntryCreateCFProperty(service, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard bundle == "com.nullmoth.NVAccel" else { continue }
            let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] ?? [:]
            let accumulated = IORegistryEntryCreateCFProperty(service, "PerformanceStatisticsAccum" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] ?? [:]
            var parent: io_registry_entry_t = 0
            var total: NSNumber?
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                total = IORegistryEntryCreateCFProperty(parent, "VRAM,totalsize" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
                IOObjectRelease(parent)
            }
            return decode(stats, usedMemory: accumulated["inUseVidMemoryBytes"] as? NSNumber, totalMemory: total)
        }
        return nil
    }

    public static func decode(_ statistics: [String: Any], usedMemory: NSNumber? = nil, totalMemory: NSNumber? = nil) -> GPUStatus {
        func value(_ key: String, range: ClosedRange<Double>) -> Double? {
            guard let number = statistics[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let result = number.doubleValue
            return result.isFinite && range.contains(result) ? result : nil
        }
        var memoryUsage: Double?
        if let usedMemory, let totalMemory,
           CFGetTypeID(usedMemory) != CFBooleanGetTypeID(),
           CFGetTypeID(totalMemory) != CFBooleanGetTypeID() {
            let used = usedMemory.doubleValue
            let total = totalMemory.doubleValue
            if used.isFinite, total.isFinite, total > 0, used >= 0, used <= total {
                memoryUsage = used / total * 100
            }
        }
        return GPUStatus(
            temperature: value("Temperature(C)", range: 0...150),
            coreUsage: value("GPU Core Utilization %", range: 0...100),
            videoDecodeUsage: value("GPU Video Decode Utilization %", range: 0...100),
            memoryUsage: memoryUsage,
            memoryUsedBytes: memoryUsage != nil ? usedMemory?.doubleValue : nil,
            memoryTotalBytes: memoryUsage != nil ? totalMemory?.doubleValue : nil
        )
    }
}
