import XCTest
@testable import ECControl

final class CPUPowerTests: XCTestCase {
    func testControlStatusAndPresets() throws {
        XCTAssertTrue(ECChargePolicy.supportsAPI(12))
        XCTAssertTrue(ECChargePolicy.supportsAPI(13))
        XCTAssertTrue(ECChargePolicy.supportsAPI(14))
        XCTAssertTrue(ECChargePolicy.supportsAPI(15))
        XCTAssertFalse(ECChargePolicy.supportsAPI(16))
        XCTAssertEqual(CPUPowerPreset.allCases.count, 5)
        XCTAssertEqual(CPUPowerPreset.energySaving.watts.0, 25)
        XCTAssertEqual(CPUPowerPreset.extreme.watts.1, 90)
        var words = [UInt64](repeating: 0, count: 14)
        words[0] = 1; words[1] = 15; words[3] = 3
        words[4] = 280 | (440 << 32)
        words[5] = 2000 | (2000 << 32)
        words[7] = 1; words[8] = 0xC1; words[9] = 0x1D
        let status = try CPUPowerControlStatus(words: words)
        XCTAssertTrue(status.available)
        XCTAssertTrue(status.owned)
        XCTAssertEqual(status.preset, .quiet)
        XCTAssertEqual(status.currentWatts.0, 35)
        XCTAssertEqual(status.currentWatts.1, 55)
        XCTAssertEqual(status.originalWatts?.0, 250)
        words[13] = 1
        XCTAssertThrowsError(try CPUPowerControlStatus(words: words))
        XCTAssertThrowsError(try CPUPowerControlStatus(words: []))
    }
    func testValidation() throws {
        XCTAssertThrowsError(try CPUPowerSnapshot(words: []))
        var words = [UInt64](repeating: 0, count: 16)
        words[0] = 2
        XCTAssertThrowsError(try CPUPowerSnapshot(words: words))
        words[0] = 1; words[9] = 1
        XCTAssertThrowsError(try CPUPowerSnapshot(words: words))
        words[9] = 0; words[1] = 1
        XCTAssertThrowsError(try CPUPowerSnapshot(words: words))
    }
    func testUnitsWindowsLockAndIdentity() throws {
        var words = [UInt64](repeating: 0, count: 16)
        words[0] = 1
        words[1] = (1 << 12) | (1 << 13)
        words[6] = 0xB0671
        words[12] = 3 | (10 << 16)
        words[13] = 440 | (1 << 15) | (1 << 16) | (UInt64(10 | (2 << 5)) << 17) | (1 << 63)
        let snapshot = try CPUPowerSnapshot(words: words)
        XCTAssertEqual(snapshot.family, 6)
        XCTAssertEqual(snapshot.model, 0xB7)
        XCTAssertEqual(snapshot.limit(short: false)?.watts, 55)
        XCTAssertEqual(snapshot.limit(short: false)?.seconds, 1.5)
        XCTAssertEqual(snapshot.limit(short: false)?.enabled, true)
        XCTAssertEqual(snapshot.limit(short: false)?.clamp, true)
        XCTAssertEqual(snapshot.packageLocked, true)
        XCTAssertNil(snapshot.register(11))
    }
    func testUnsupportedSnapshotHasNoLimits() throws {
        var words = [UInt64](repeating: 0, count: 16)
        words[0] = 1
        let snapshot = try CPUPowerSnapshot(words: words)
        XCTAssertNil(snapshot.limit(short: true))
        XCTAssertNil(snapshot.packageLocked)
        XCTAssertFalse(snapshot.hwpSupported)
    }
}
