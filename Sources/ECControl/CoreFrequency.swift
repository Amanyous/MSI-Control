import Foundation
import IOKit

public struct CoreCounter: Sendable {
    public let logicalCPU: Int?
    public let apic: UInt64
    public let type: UInt64
    public let referenceHz: UInt64
    public let baseHz: UInt64
    public let tsc: UInt64
    public let aperf: UInt64
    public let mperf: UInt64
    public let sampledAt: TimeInterval?
    public let generation: UInt64?

    public init(apic: UInt64, type: UInt64, referenceHz: UInt64, tsc: UInt64, aperf: UInt64, mperf: UInt64, baseHz: UInt64? = nil, logicalCPU: Int? = nil, sampledAt: TimeInterval? = nil, generation: UInt64? = nil) {
        self.sampledAt = sampledAt
        self.generation = generation
        self.logicalCPU = logicalCPU
        self.apic = apic
        self.type = type
        self.referenceHz = referenceHz
        self.baseHz = baseHz ?? referenceHz
        self.tsc = tsc
        self.aperf = aperf
        self.mperf = mperf
    }
}

public struct CoreFrequency: Identifiable, Sendable {
    public var id: UInt64 { apic }
    public let apic: UInt64
    public let type: UInt64
    public let activeGHz: Double?
    public let effectiveGHz: Double
    let activityWeight: Double
    public var kind: String { type == 0x40 ? "P" : type == 0x20 ? "E" : type == 0 ? "普通" : "?" }

    public static func measure(previous: CoreCounter, current: CoreCounter) -> CoreFrequency? {
        guard previous.apic == current.apic, previous.type == current.type,
              previous.logicalCPU == current.logicalCPU,
              previous.generation == current.generation,
              previous.referenceHz == current.referenceHz, current.referenceHz > 0,
              previous.baseHz == current.baseHz, current.baseHz > 0,
              current.tsc > previous.tsc, current.aperf >= previous.aperf,
              current.mperf >= previous.mperf else { return nil }
        let ticks = Double(current.tsc - previous.tsc)
        let seconds = ticks / Double(current.referenceHz)
        guard (0.25...5).contains(seconds) else { return nil }
        let a = Double(current.aperf - previous.aperf)
        let m = Double(current.mperf - previous.mperf)
        let effective = a / seconds / 1e9
        let active = m > 0 ? Double(current.baseHz) * a / m / 1e9 : nil
        guard effective.isFinite, effective <= 10,
              active.map({ $0.isFinite && $0 <= 10 }) ?? true else { return nil }
        return CoreFrequency(apic: current.apic, type: current.type, activeGHz: active,
                             effectiveGHz: effective,
                             activityWeight: m / Double(current.baseHz) / seconds)
    }
}

public struct CoreFrequencyRow: Identifiable, Sendable {
    public let id: Int
    public let apic: UInt64?
    public let type: UInt64?
    public let frequency: CoreFrequency?
    public var kind: String {
        switch type {
        case 0x40: "P"
        case 0x20: "E"
        case 0: "普通"
        default: "待识别"
        }
    }
}

public struct CoreFrequencySamples: Sendable {
    private struct Baseline: Sendable {
        let counter: CoreCounter
        let timestamp: TimeInterval
    }
    private struct Measurement: Sendable {
        let frequency: CoreFrequency
        let timestamp: TimeInterval
    }
    private var baselines: [UInt64: Baseline] = [:]
    private var measurements: [UInt64: Measurement] = [:]
    private var topology: [Int: CoreCounter] = [:]
    private static let baselineLifetime: TimeInterval = 5
    private static let measurementLifetime: TimeInterval = 2

    public init() {}

    public var frequencies: [CoreFrequency] {
        measurements.values.map(\.frequency).sorted { $0.apic < $1.apic }
    }

    public var aggregateGHz: Double? {
        let contributing = frequencies.filter { $0.activeGHz != nil && $0.activityWeight > 0 }
        let weight = contributing.reduce(0) { $0 + $1.activityWeight }
        guard weight > 0 else { return nil }
        let speed = contributing.reduce(0) { $0 + $1.effectiveGHz } / weight
        return speed.isFinite ? speed : nil
    }

    public var hasLogicalCPUIdentity: Bool { !topology.isEmpty }

    public func rows(logicalCPUCount: Int) -> [CoreFrequencyRow] {
        (0..<max(0, min(logicalCPUCount, 4096))).map { index in
            let identity = topology[index]
            let frequency = identity.flatMap { measurements[$0.apic]?.frequency }
            return CoreFrequencyRow(id: index, apic: identity?.apic, type: identity?.type,
                                    frequency: frequency?.type == identity?.type ? frequency : nil)
        }
    }

    public mutating func expire(at timestamp: TimeInterval) {
        baselines = baselines.filter { (0...Self.baselineLifetime).contains(timestamp - $0.value.timestamp) }
        measurements = measurements.filter { (0...Self.measurementLifetime).contains(timestamp - $0.value.timestamp) }
    }

    public mutating func update(_ counters: [CoreCounter], at timestamp: TimeInterval) {
        expire(at: timestamp)
        for current in counters {
            let acquired = current.sampledAt ?? timestamp
            guard acquired.isFinite, (0...2).contains(timestamp - acquired) else { continue }
            if let index = current.logicalCPU, (0..<4096).contains(index) {
                if let old = topology[index], old.apic != current.apic || old.type != current.type {
                    measurements.removeValue(forKey: old.apic)
                    baselines.removeValue(forKey: current.apic)
                }
                let staleIndices = topology.filter { $0.key != index && $0.value.apic == current.apic }.map(\.key)
                for stale in staleIndices { topology.removeValue(forKey: stale) }
                topology[index] = current
            }
            if let previous = baselines[current.apic] {
                if current.sampledAt != nil, current.tsc == previous.counter.tsc,
                   current.generation == previous.counter.generation { continue }
                if let frequency = CoreFrequency.measure(previous: previous.counter, current: current) {
                    measurements[current.apic] = Measurement(frequency: frequency, timestamp: acquired)
                } else {
                    measurements.removeValue(forKey: current.apic)
                }
            }
            baselines[current.apic] = Baseline(counter: current, timestamp: acquired)
        }
    }
}

enum CoreCounterProtocol {
    static let wordCount = 12

    static func cached(_ words: [UInt64], index: Int) throws -> [CoreCounter] {
        guard (0..<256).contains(index), words.count == wordCount,
              words[0] == 4, words[1] == 1,
              words[3] == UInt64(index + 1), words[4] <= 1 else {
            throw ECError.invalid("全核缓存核心编号异常")
        }
        if words[4] == 0 { return [] }
        var local = words
        local[2] = 0
        let decoded = try read(api: 15, version: 4) { local }[0]
        guard decoded.tsc > 0 else { throw ECError.invalid("全核缓存时间异常") }
        return [CoreCounter(apic: decoded.apic, type: decoded.type,
                            referenceHz: decoded.referenceHz, tsc: decoded.tsc,
                            aperf: decoded.aperf, mperf: decoded.mperf, baseHz: decoded.baseHz,
                            logicalCPU: index, sampledAt: Double(decoded.tsc) / 1e9,
                            generation: words[2])]
    }

    static func read(api: Int, version: Int, fetch: () throws -> [UInt64]) throws -> [CoreCounter] {
        guard api >= 15, [2, 3, 4].contains(version) else {
            throw ECError.unavailable("区间采样需要 MSIECBridge 0.4.6，请更新驱动并重启")
        }
        let words = try fetch()
        guard words.count == wordCount, words[0] == UInt64(version), words[1] == 1,
              words[2] == 0,
              version == 4 ? (1...4096).contains(words[3]) : words[3] == 0 else {
            throw ECError.invalid("区间采样响应异常")
        }
        guard words[4] == 1 else { throw ECError.unavailable("当前核心不支持计数器采样") }
        let types: [UInt64] = version >= 3 ? [0, 0x40, 0x20] : [0x40, 0x20]
        guard types.contains(words[6]), words[7] > 0, words[11] > 0,
              version < 3 || words[7] == 1_000_000_000 else {
            throw ECError.invalid("核心时钟信息异常")
        }
        return [CoreCounter(apic: words[5], type: words[6], referenceHz: words[7],
                            tsc: words[8], aperf: words[9], mperf: words[10], baseHz: words[11],
                            logicalCPU: version == 4 ? Int(words[3] - 1) : nil)]
    }
}

extension ECBridgeConnection {
    public func cachedCoreCounters(logicalCPUCount: Int) throws -> [CoreCounter] {
        guard apiVersion >= 15, counterProtocolVersion == 4, counterCacheVersion == 1 else {
            throw ECError.unavailable("全核采样需要 MSIECBridge 0.4.9，请更新硬盘 EFI 并重启")
        }
        guard (1...256).contains(logicalCPUCount) else { throw ECError.invalid("逻辑核心数量超出采样范围") }
        var counters: [CoreCounter] = []
        for index in 0..<logicalCPUCount {
            var input = UInt64(index)
            var words = [UInt64](repeating: 0, count: CoreCounterProtocol.wordCount)
            var size = words.count * 8
            let code = words.withUnsafeMutableBytes {
                IOConnectCallMethod(connection, 17, &input, 1, nil, 0, nil, nil, $0.baseAddress, &size)
            }
            guard code == KERN_SUCCESS else { throw ECError.system(operation: "读取全核采样缓存", code: code) }
            guard size == 96 else { throw ECError.invalid("全核缓存响应长度异常") }
            counters += try CoreCounterProtocol.cached(words, index: index)
        }
        return counters
    }

    public func coreCounters() throws -> [CoreCounter] {
        try CoreCounterProtocol.read(api: apiVersion, version: counterProtocolVersion) {
            var words = [UInt64](repeating: 0, count: CoreCounterProtocol.wordCount)
            var size = words.count * MemoryLayout<UInt64>.size
            let code = words.withUnsafeMutableBytes {
                IOConnectCallStructMethod(connection, 16, nil, 0, $0.baseAddress, &size)
            }
            guard code == KERN_SUCCESS else { throw ECError.system(operation: "读取逐核计数器", code: code) }
            guard size == words.count * 8 else { throw ECError.invalid("区间采样响应长度异常") }
            return words
        }
    }
}
