import XCTest
@testable import ECControl

final class CoreFrequencyTests: XCTestCase {
    private var response: [UInt64] {
        [2, 1, 0, 0, 1, 2, 0x40, 2_000_000_000, 1, 10, 10, 2_000_000_000]
    }

    func testOldDriverNeverInvokesCounterMethod() {
        for (api, version) in [(14, 0), (14, 2), (14, 3), (14, 4), (15, 0), (15, 1), (15, 5)] {
            var called = false
            XCTAssertThrowsError(try CoreCounterProtocol.read(api: api, version: version) {
                called = true
                return self.response
            })
            XCTAssertFalse(called)
        }
    }

    func testCachedProtocolRejectsWrongSlotAndMissingData() throws {
        var words: [UInt64] = [4, 1, 0, 28, 1, 42, 0x20, 1_000_000_000,
                               10_000_000_000, 10, 10, 2_600_000_000]
        let sample = try XCTUnwrap(CoreCounterProtocol.cached(words, index: 27).first)
        XCTAssertEqual(sample.logicalCPU, 27)
        XCTAssertEqual(sample.sampledAt, 10)
        XCTAssertThrowsError(try CoreCounterProtocol.cached(words, index: 26))
        XCTAssertThrowsError(try CoreCounterProtocol.cached(words, index: 256))
        words[4] = 0
        XCTAssertTrue(try CoreCounterProtocol.cached(words, index: 27).isEmpty)
        words[4] = 2
        XCTAssertThrowsError(try CoreCounterProtocol.cached(words, index: 27))
    }

    func testCachedDuplicateDoesNotDestroyIntervalOrExtendFreshness() throws {
        func cached(_ second: UInt64) -> CoreCounter {
            CoreCounter(apic: 42, type: 0x20, referenceHz: 1_000_000_000,
                        tsc: second * 1_000_000_000, aperf: second * 2_000_000_000,
                        mperf: second * 1_000_000_000, baseHz: 1_000_000_000,
                        logicalCPU: 2, sampledAt: Double(second))
        }
        var samples = CoreFrequencySamples()
        samples.update([cached(10)], at: 10.1)
        samples.update([cached(11)], at: 11.1)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 2)
        samples.update([cached(11)], at: 11.4)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 2)
        samples.update([cached(11)], at: 13.01)
        XCTAssertNil(samples.aggregateGHz)
        samples.update([cached(14)], at: 14.1)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 2)
        samples.update([cached(15)], at: 14.9)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 2)
    }

    func testAll28CachedProcessorsProduceIndependentFreshIntervals() {
        var samples = CoreFrequencySamples()
        for second in UInt64(10)...12 {
            let counters = (0..<28).map { index in
                CoreCounter(apic: UInt64(index * 2), type: index < 16 ? 0x40 : 0x20,
                            referenceHz: 1_000_000_000, tsc: second * 1_000_000_000,
                            aperf: second * UInt64(index + 1) * 100_000_000,
                            mperf: second * 1_000_000_000, baseHz: 1_000_000_000,
                            logicalCPU: index, sampledAt: Double(second))
            }
            samples.update(counters, at: Double(second) + 0.1)
        }
        XCTAssertEqual(samples.rows(logicalCPUCount: 28).filter { $0.frequency != nil }.count, 28)
        XCTAssertEqual(samples.frequencies.filter { $0.kind == "E" }.count, 12)
        samples.expire(at: 14.01)
        XCTAssertTrue(samples.frequencies.isEmpty)
    }

    func testSleepGenerationCannotReusePreSleepInterval() throws {
        func observation(_ second: UInt64, generation: UInt64) throws -> CoreCounter {
            try XCTUnwrap(CoreCounterProtocol.cached(
                [4, 1, generation, 1, 1, 0, 0x40, 1_000_000_000,
                 second * 1_000_000_000, second * 2_000_000_000,
                 second * 1_000_000_000, 1_000_000_000], index: 0).first)
        }
        var samples = CoreFrequencySamples()
        samples.update([try observation(10, generation: 0)], at: 10)
        samples.update([try observation(11, generation: 0)], at: 11)
        XCTAssertNotNil(samples.aggregateGHz)
        samples.update([try observation(12, generation: 2)], at: 12)
        XCTAssertNil(samples.aggregateGHz)
        samples.update([try observation(13, generation: 2)], at: 13)
        XCTAssertNotNil(samples.aggregateGHz)
    }

    func testLogicalCPUProtocolIdentity() throws {
        var words: [UInt64] = [4, 1, 0, 28, 1, 42, 0x20, 1_000_000_000,
                               1, 10, 10, 2_600_000_000]
        let result = try XCTUnwrap(CoreCounterProtocol.read(api: 15, version: 4) { words }.first)
        XCTAssertEqual(result.logicalCPU, 27)
        XCTAssertEqual(result.apic, 42)
        for value: UInt64 in [0, 4097, UInt64.max] {
            words[3] = value
            XCTAssertThrowsError(try CoreCounterProtocol.read(api: 15, version: 4) { words })
        }
        words[3] = 1
        words[7] = 2_000_000_000
        XCTAssertThrowsError(try CoreCounterProtocol.read(api: 15, version: 4) { words })
        XCTAssertNil(try CoreCounterProtocol.read(api: 15, version: 2) { response }.first?.logicalCPU)
    }

    private func indexedCounter(index: Int = 2, apic: UInt64 = 42, type: UInt64 = 0x20,
                                second: UInt64) -> CoreCounter {
        CoreCounter(apic: apic, type: type, referenceHz: 1_000_000_000,
                    tsc: 1 + second * 1_000_000_000, aperf: 10 + second * 2_000_000_000,
                    mperf: 10 + second * 1_000_000_000, baseHz: 1_000_000_000, logicalCPU: index)
    }

    func testFixedRosterPreservesIdentityButNotExpiredFrequency() throws {
        var samples = CoreFrequencySamples()
        XCTAssertEqual(samples.rows(logicalCPUCount: 28).map(\.id), Array(0..<28))
        XCTAssertTrue(samples.rows(logicalCPUCount: 28).allSatisfy { $0.apic == nil && $0.frequency == nil })
        samples.update([indexedCounter(second: 0)], at: 0)
        XCTAssertTrue(samples.hasLogicalCPUIdentity)
        XCTAssertEqual(samples.rows(logicalCPUCount: 28)[2].kind, "E")
        XCTAssertNil(samples.rows(logicalCPUCount: 28)[2].frequency)
        samples.update([indexedCounter(second: 1)], at: 1)
        let row = samples.rows(logicalCPUCount: 28)[2]
        XCTAssertEqual(row.apic, 42)
        XCTAssertEqual(try XCTUnwrap(row.frequency?.activeGHz), 2)
        XCTAssertTrue(samples.rows(logicalCPUCount: 28).enumerated().allSatisfy {
            $0.offset == 2 || $0.element.frequency == nil
        })
        samples.expire(at: 4)
        XCTAssertEqual(samples.rows(logicalCPUCount: 28).count, 28)
        XCTAssertEqual(samples.rows(logicalCPUCount: 28)[2].apic, 42)
        XCTAssertNil(samples.rows(logicalCPUCount: 28)[2].frequency)
    }

    func testLegacySamplesAreNeverGuessedIntoOSRows() {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0)], at: 0)
        samples.update([counter(second: 1)], at: 1)
        XCTAssertNotNil(samples.aggregateGHz)
        XCTAssertFalse(samples.hasLogicalCPUIdentity)
        XCTAssertTrue(samples.rows(logicalCPUCount: 28).allSatisfy { $0.apic == nil && $0.frequency == nil })
        XCTAssertTrue(samples.rows(logicalCPUCount: -1).isEmpty)
        XCTAssertEqual(samples.rows(logicalCPUCount: Int.max).count, 4096)
    }

    func testIdentityChangesCannotReuseAnotherProcessorsInterval() {
        var samples = CoreFrequencySamples()
        samples.update([indexedCounter(second: 0)], at: 0)
        samples.update([indexedCounter(second: 1)], at: 1)
        samples.update([indexedCounter(index: 3, second: 2)], at: 2)
        XCTAssertNil(samples.rows(logicalCPUCount: 4)[2].apic)
        XCTAssertNil(samples.rows(logicalCPUCount: 4)[3].frequency)
        samples.update([indexedCounter(index: 3, second: 3)], at: 3)
        XCTAssertNotNil(samples.rows(logicalCPUCount: 4)[3].frequency)
        samples.update([indexedCounter(index: 3, apic: 43, second: 4)], at: 4)
        XCTAssertEqual(samples.rows(logicalCPUCount: 4)[3].apic, 43)
        XCTAssertNil(samples.rows(logicalCPUCount: 4)[3].frequency)
    }

    func testMonotonicProtocolAndOrdinaryCore() throws {
        let words: [UInt64] = [3, 1, 0, 0, 1, 6, 0, 1_000_000_000,
                                1, 10, 10, 2_600_000_000]
        let before = try XCTUnwrap(CoreCounterProtocol.read(api: 15, version: 3) { words }.first)
        var afterWords = words
        afterWords[8] += 1_000_000_000
        afterWords[9] += 1_950_000_000
        afterWords[10] += 1_300_000_000
        let after = try XCTUnwrap(CoreCounterProtocol.read(api: 15, version: 3) { afterWords }.first)
        let result = try XCTUnwrap(CoreFrequency.measure(previous: before, current: after))
        XCTAssertEqual(result.kind, "普通")
        XCTAssertEqual(try XCTUnwrap(result.activeGHz), 3.9, accuracy: 0.0001)
        XCTAssertEqual(result.effectiveGHz, 1.95, accuracy: 0.0001)
        XCTAssertThrowsError(try CoreCounterProtocol.read(api: 15, version: 2) { words })
        for (index, value) in [(0, UInt64(2)), (6, 1), (7, 2_000_000_000)] {
            var invalid = words
            invalid[index] = value
            XCTAssertThrowsError(try CoreCounterProtocol.read(api: 15, version: 3) { invalid })
        }
    }

    func testCompactProtocolValidation() throws {
        let result = try CoreCounterProtocol.read(api: 15, version: 2) { response }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].apic, 2)
        XCTAssertEqual(result[0].baseHz, 2_000_000_000)
        var invalid = [Array(response.dropLast()), response + [0], []]
        for (index, value) in [(0, UInt64(1)), (1, 0), (1, 2), (2, 1), (3, 1),
                               (4, 0), (6, 0), (7, 0), (11, 0)] {
            var words = response
            words[index] = value
            invalid.append(words)
        }
        for words in invalid {
            XCTAssertThrowsError(try CoreCounterProtocol.read(api: 15, version: 2) { words })
        }
    }

    func testIntervalFrequencyAndIdle() throws {
        let before = CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000,
                                 tsc: 1, aperf: 10, mperf: 10)
        let after = CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000,
                                tsc: 2_000_000_001, aperf: 2_150_000_010, mperf: 1_000_000_010)
        let result = try XCTUnwrap(CoreFrequency.measure(previous: before, current: after))
        XCTAssertEqual(try XCTUnwrap(result.activeGHz), 4.3, accuracy: 0.0001)
        XCTAssertEqual(result.effectiveGHz, 2.15, accuracy: 0.0001)
        let idle = CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000,
                               tsc: 2_000_000_001, aperf: 10, mperf: 10)
        let idleResult = try XCTUnwrap(CoreFrequency.measure(previous: before, current: idle))
        XCTAssertNil(idleResult.activeGHz)
        XCTAssertEqual(idleResult.effectiveGHz, 0)
    }

    func testRejectsMigrationResetAndLongGap() {
        let before = CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000,
                                 tsc: 1, aperf: 10, mperf: 10)
        for after in [
            CoreCounter(apic: 3, type: 0x40, referenceHz: 2_000_000_000, tsc: 2_000_000_001, aperf: 20, mperf: 20),
            CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000, tsc: 2_000_000_001, aperf: 0, mperf: 20),
            CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000, tsc: 12_000_000_001, aperf: 20, mperf: 20)
        ] {
            XCTAssertNil(CoreFrequency.measure(previous: before, current: after))
        }
    }

    func testIntervalBoundsAndClockChanges() {
        let before = CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000,
                                 tsc: 1, aperf: 10, mperf: 10, baseHz: 2_000_000_000)
        for seconds in [0.25, 5.0] {
            let after = CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000,
                                    tsc: 1 + UInt64(seconds * 2e9), aperf: 20, mperf: 20,
                                    baseHz: 2_000_000_000)
            XCTAssertNotNil(CoreFrequency.measure(previous: before, current: after))
        }
        for after in [
            CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000, tsc: 500_000_000, aperf: 20, mperf: 20),
            CoreCounter(apic: 2, type: 0x20, referenceHz: 2_000_000_000, tsc: 2_000_000_001, aperf: 20, mperf: 20),
            CoreCounter(apic: 2, type: 0x40, referenceHz: 3_000_000_000, tsc: 2_000_000_001, aperf: 20, mperf: 20),
            CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000, tsc: 2_000_000_001, aperf: 20, mperf: 20, baseHz: 3_000_000_000),
            CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000, tsc: 2_000_000_001, aperf: 20, mperf: 0)
        ] {
            XCTAssertNil(CoreFrequency.measure(previous: before, current: after))
        }
    }

    private func counter(apic: UInt64 = 2, second: UInt64, idle: Bool = false) -> CoreCounter {
        CoreCounter(apic: apic, type: 0x40, referenceHz: 2_000_000_000,
                    tsc: 1 + second * 2_000_000_000,
                    aperf: 10 + (idle ? 0 : second * 4_300_000_000),
                    mperf: 10 + (idle ? 0 : second * 2_000_000_000))
    }

    func testMigrationRetainsMatchedRowsAndIndependentBaselines() throws {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0)], at: 0)
        XCTAssertTrue(samples.frequencies.isEmpty)
        samples.update([counter(second: 1)], at: 1)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 4.3, accuracy: 0.0001)
        samples.update([counter(apic: 3, second: 2)], at: 2)
        XCTAssertEqual(samples.frequencies.map(\.apic), [2])
        samples.update([counter(apic: 3, second: 3)], at: 3)
        XCTAssertEqual(samples.frequencies.map(\.apic), [2, 3])
        samples.update([counter(second: 4)], at: 4)
        XCTAssertEqual(samples.frequencies.map(\.apic), [2, 3])
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 4.3, accuracy: 0.0001)
    }

    func testMissingSnapshotRetainsDataUntilBoundedExpiry() {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0)], at: 0)
        samples.update([counter(second: 1)], at: 1)
        samples.update([], at: 2)
        XCTAssertEqual(samples.frequencies.count, 1)
        samples.expire(at: 3)
        XCTAssertNotNil(samples.aggregateGHz)
        samples.expire(at: 3.001)
        XCTAssertTrue(samples.frequencies.isEmpty)
        XCTAssertNil(samples.aggregateGHz)
    }

    func testTemporaryFailureDoesNotDiscardBaseline() {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0)], at: 0)
        samples.update([], at: 1)
        samples.update([counter(second: 2)], at: 2)
        XCTAssertNotNil(samples.aggregateGHz)
    }

    func testIdleReplacesPreviousActiveMeasurement() throws {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0)], at: 0)
        samples.update([counter(second: 1)], at: 1)
        let idle = CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000,
                               tsc: 4_000_000_001, aperf: 4_300_000_010, mperf: 2_000_000_010)
        samples.update([idle], at: 2)
        XCTAssertEqual(samples.frequencies.count, 1)
        XCTAssertNil(samples.aggregateGHz)
        XCTAssertEqual(try XCTUnwrap(samples.frequencies.first).effectiveGHz, 0)
    }

    func testResetInvalidatesOnlyAffectedCoreAndRebaselines() throws {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0), counter(apic: 3, second: 0)], at: 0)
        samples.update([counter(second: 1), counter(apic: 3, second: 1)], at: 1)
        samples.update([counter(second: 0)], at: 2)
        XCTAssertEqual(samples.frequencies.map(\.apic), [3])
        samples.update([counter(second: 1)], at: 3)
        XCTAssertEqual(samples.frequencies.map(\.apic), [2, 3])
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 4.3, accuracy: 0.0001)
    }

    func testExpiredBaselineRequiresAnotherSnapshot() {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0)], at: 0)
        samples.update([counter(second: 6)], at: 6)
        XCTAssertTrue(samples.frequencies.isEmpty)
        samples.update([counter(second: 7)], at: 7)
        XCTAssertNotNil(samples.aggregateGHz)
    }

    func testBackwardsMonotonicTimeDiscardsPreviousState() {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0)], at: 10)
        samples.update([counter(second: 1)], at: 11)
        samples.update([counter(second: 2)], at: 9)
        XCTAssertTrue(samples.frequencies.isEmpty)
        samples.update([counter(second: 3)], at: 10)
        XCTAssertNotNil(samples.aggregateGHz)
    }

    func testAggregateIncludesFreshLowerFrequencyWithoutHoldingPeak() throws {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0), counter(apic: 3, second: 0)], at: 0)
        samples.update([counter(second: 1)], at: 1)
        let slower = CoreCounter(apic: 3, type: 0x40, referenceHz: 2_000_000_000,
                                 tsc: 4_000_000_001, aperf: 2_400_000_010, mperf: 4_000_000_010)
        samples.update([slower], at: 2)
        XCTAssertEqual(samples.frequencies.count, 2)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 2.75, accuracy: 0.0001)
        samples.expire(at: 3.01)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 1.2, accuracy: 0.0001)
    }

    func testIdleCoreDoesNotMaskAnotherFreshActiveCore() throws {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0), counter(apic: 3, second: 0)], at: 0)
        samples.update([counter(second: 1)], at: 1)
        samples.update([counter(apic: 3, second: 2, idle: true)], at: 2)
        XCTAssertEqual(samples.frequencies.count, 2)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 4.3, accuracy: 0.0001)
    }

    private func observation(index: Int, time: Double, cycles: Double = 0,
                             activeSeconds: Double = 0, baseHz: Double = 2e9) -> CoreCounter {
        CoreCounter(apic: UInt64(index), type: index == 0 ? 0x40 : 0x20,
                    referenceHz: 1_000_000_000, tsc: UInt64(time * 1e9),
                    aperf: UInt64(cycles), mperf: UInt64(activeSeconds * baseHz),
                    baseHz: UInt64(baseHz), logicalCPU: index, sampledAt: time)
    }

    func testNewestPointEightGHzCoreDoesNotDetermineAggregate() throws {
        var samples = CoreFrequencySamples()
        samples.update([observation(index: 0, time: 10),
                        observation(index: 27, time: 10.1)], at: 10.1)
        samples.update([observation(index: 0, time: 11, cycles: 4e9, activeSeconds: 1),
                        observation(index: 27, time: 11.1, cycles: 0.08e9,
                                    activeSeconds: 0.1)], at: 11.1)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 4.08 / 1.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(samples.rows(logicalCPUCount: 28)[27].frequency?.activeGHz),
                       0.8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(samples.rows(logicalCPUCount: 28)[0].frequency?.activeGHz),
                       4, accuracy: 0.0001)
        XCTAssertEqual(samples.rows(logicalCPUCount: 28).filter { $0.frequency != nil }.count, 2)
    }

    func testAggregateNormalizesHybridBaseClocksAndUnequalIntervals() throws {
        var samples = CoreFrequencySamples()
        samples.update([observation(index: 0, time: 10, baseHz: 2e9),
                        observation(index: 1, time: 11, baseHz: 1e9)], at: 11)
        samples.update([observation(index: 0, time: 12, cycles: 4e9,
                                    activeSeconds: 1, baseHz: 2e9),
                        observation(index: 1, time: 12, cycles: 0.8e9,
                                    activeSeconds: 1, baseHz: 1e9)], at: 12)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 2.8 / 1.5, accuracy: 0.0001)
        samples.expire(at: 14.001)
        XCTAssertNil(samples.aggregateGHz)
    }

    func testAggregateIgnoresIdleAndInvalidIntervals() throws {
        var samples = CoreFrequencySamples()
        samples.update([observation(index: 0, time: 10),
                        observation(index: 1, time: 10)], at: 10)
        samples.update([observation(index: 0, time: 11, cycles: 3e9, activeSeconds: 1),
                        observation(index: 1, time: 11)], at: 11)
        XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 3, accuracy: 0.0001)
        samples.update([observation(index: 0, time: 12)], at: 12)
        XCTAssertNil(samples.aggregateGHz)
        XCTAssertEqual(samples.frequencies.count, 1)
    }

    func testMeasurementExpiryDoesNotExpireValidBaseline() {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0)], at: 0)
        samples.update([counter(second: 1)], at: 1)
        samples.expire(at: 3.1)
        XCTAssertNil(samples.aggregateGHz)
        samples.update([counter(second: 4)], at: 4)
        XCTAssertNotNil(samples.aggregateGHz)
    }

    func testQuarterSecondIntervalsProduceFreshMeasurements() throws {
        var samples = CoreFrequencySamples()
        samples.update([counter(second: 0)], at: 0)
        for tick in UInt64(1)...8 {
            let current = CoreCounter(apic: 2, type: 0x40, referenceHz: 2_000_000_000,
                                      tsc: 1 + tick * 500_000_000,
                                      aperf: 10 + tick * 1_075_000_000,
                                      mperf: 10 + tick * 500_000_000)
            samples.update([current], at: Double(tick) * 0.25)
            XCTAssertEqual(try XCTUnwrap(samples.aggregateGHz), 4.3, accuracy: 0.0001)
        }
    }
}
