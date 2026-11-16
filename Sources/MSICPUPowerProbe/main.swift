import Foundation
import ECControl
import Darwin

func systemIdentity(_ name: String) -> Int32? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
}

do {
    if CommandLine.arguments.contains("--cached-frequency") {
        print("Read-only cached CPU speed; no policy writes.")
        let bridge = try ECBridgeConnection()
        let count = ProcessInfo.processInfo.processorCount
        var samples = CoreFrequencySamples()
        for _ in 0..<12 {
            let counters = try bridge.cachedCoreCounters(logicalCPUCount: count)
            samples.update(counters, at: ProcessInfo.processInfo.systemUptime)
            let rows = samples.rows(logicalCPUCount: count)
            let valid = rows.filter { $0.frequency != nil }.count
            let speed = samples.aggregateGHz.map { String(format: "%.3f", $0) } ?? "unavailable"
            let last = rows.last?.frequency?.activeGHz.map { String(format: "%.3f", $0) } ?? "unavailable"
            print("valid=\(valid)/\(count) aggregate=\(speed) GHz lastCPU=\(last) GHz")
            Thread.sleep(forTimeInterval: 1)
        }
        exit(0)
    }
    if CommandLine.arguments.contains("--frequency") {
        print("Read-only per-logical-core interval frequency; no policy writes.")
        var previous = try ECBridgeConnection().coreCounters()
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 1)
            let current = try ECBridgeConnection().coreCounters()
            let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.apic, $0) })
            for core in current {
                if let before = old[core.apic], let value = CoreFrequency.measure(previous: before, current: core) {
                    print("APIC \(value.apic) \(value.kind): active \(value.activeGHz.map { String(format: "%.3f", $0) } ?? "idle") GHz, effective \(String(format: "%.3f", value.effectiveGHz)) GHz")
                } else {
                    print("APIC \(core.apic): invalid interval")
                }
            }
            previous = current
        }
        exit(0)
    }
    if CommandLine.arguments.contains("--control-status") {
        let status = try ECBridgeConnection().powerControlStatus()
        print("Read-only power-control status; no writes.")
        print("Available: \(status.available); owned: \(status.owned); conflict: \(status.conflict)")
        print("Generation: \(status.generation); mode: \(status.preset.map { String($0.rawValue) } ?? "original")")
        print("PL1/PL2: \(status.currentWatts.0)/\(status.currentWatts.1) W")
        print(String(format: "EC shift/fan: %02X/%02X", status.shift, status.fan))
        print("Raw status: \(status.words)")
        exit(0)
    }
    let snapshot = try ECBridgeConnection().cpuPowerSnapshot()
    print("Read-only CPU snapshot v1; no register or power-policy writes.")
    print("Hardware: \(snapshot.vendor), family \(snapshot.family), model \(String(snapshot.model, radix: 16)), stepping \(snapshot.words[6] & 15)")
    print("macOS-reported identity (not used for capability gating): family \(systemIdentity("machdep.cpu.family").map(String.init) ?? "unavailable"), model \(systemIdentity("machdep.cpu.model").map { String($0, radix: 16) } ?? "unavailable")")
    print("Sample scope: one logical CPU; \(snapshot.words[1] & (1 << 8) != 0 ? "x2APIC" : "initial APIC") ID \(snapshot.words[8]); not an all-core measurement.")
    print("HWP supported: \(snapshot.hwpSupported); EPP supported: \(snapshot.eppSupported)")
    for (index, name) in [(9, "PM_ENABLE"), (10, "HWP_CAPABILITIES"), (11, "HWP_REQUEST"), (12, "RAPL_UNIT"), (13, "PKG_POWER_LIMIT")] {
        print("\(name): \(snapshot.register(index).map { String(format: "0x%016llx", $0) } ?? "unavailable")")
    }
    for short in [false, true] {
        if let limit = snapshot.limit(short: short) {
            print("\(short ? "PL2" : "PL1"): \(limit.watts) W, enabled \(limit.enabled), clamp \(limit.clamp), window \(limit.seconds) s")
        }
    }
    print("Package limit lock: \(snapshot.packageLocked.map(String.init) ?? "unavailable"); read support does not establish safe write support.")
} catch {
    print("CPU discovery unavailable: \(error)")
    exit(1)
}
