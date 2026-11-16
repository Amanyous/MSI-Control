import ECControl
import Foundation
import PowerServiceProtocol
import XCTest

final class PowerServiceTests: XCTestCase {
    func testFanRequestsRejectUnsupportedInputs() throws {
        try FanServiceRequest.mode(.advanced, expected: 0x1D, firmware: "15P2EMS1.110").validate()
        try FanServiceRequest.boost(true, expected: 0, firmware: "15P2EMS1.110").validate()
        XCTAssertThrowsError(try FanServiceRequest.mode(.silent, expected: 0x0D, firmware: "15P2EMS1.110").validate())
        XCTAssertThrowsError(try FanServiceRequest.mode(.automatic, expected: 0, firmware: "unknown").validate())
        let curve = ECFanCurve(temperatures: [30, 40, 50, 60, 70, 80], speeds: [20, 30, 40, 50, 60, 70])
        try FanServiceRequest.curve(fan: 0, expected: curve, speeds: curve.speeds, mode: 0x8D, firmware: "15P2EMS1.110").validate()
        for fan in [-1, 2] {
            XCTAssertThrowsError(try FanServiceRequest.curve(fan: fan, expected: curve, speeds: curve.speeds, mode: 0x8D, firmware: "15P2EMS1.110").validate())
        }
        XCTAssertThrowsError(try FanServiceRequest.curve(fan: 0, expected: curve, speeds: [0], mode: 0x8D, firmware: "15P2EMS1.110").validate())
    }

    func testEFIIdentityAndStateValidation() throws {
        let current = SystemEFIPartition(identifier: "disk1s1", uuid: UUID(), mountPoint: nil)
        let request = EFIServiceRequest(mount: true, expected: current)
        try request.validate(current: current)
        for changed in [
            SystemEFIPartition(identifier: "disk2s1", uuid: current.uuid, mountPoint: nil),
            SystemEFIPartition(identifier: current.identifier, uuid: UUID(), mountPoint: nil),
            SystemEFIPartition(identifier: current.identifier, uuid: current.uuid, mountPoint: "/Volumes/EFI")
        ] {
            XCTAssertThrowsError(try request.validate(current: changed))
        }
        let invalid = SystemEFIPartition(identifier: "disk1s1;reboot", uuid: current.uuid, mountPoint: nil)
        XCTAssertThrowsError(try EFIServiceRequest(mount: true, expected: invalid).validate(current: invalid))
        let data = try JSONEncoder().encode(HardwareServiceRequest.efi(request))
        guard case .efi(let decoded) = try JSONDecoder().decode(HardwareServiceRequest.self, from: data) else {
            return XCTFail("Wrong request kind")
        }
        try decoded.validate(current: current)
    }

    private func status() throws -> CPUPowerControlStatus {
        try CPUPowerControlStatus(words: [1, 7, 10, 3, 100, 200, 100, 1, 193, 29, 193, 29, 0, 0])
    }

    func testValidRequestAndStaleCAS() throws {
        let current = try status()
        let request = PowerServiceRequest(preset: .quiet, eco: false, expected: current)
        try request.validateCurrent(current)
        var changed = current.words
        for index in [2, 4, 8, 9] {
            changed = current.words
            changed[index] += 1
            XCTAssertThrowsError(try request.validateCurrent(CPUPowerControlStatus(words: changed)))
        }
    }

    func testRejectsInvalidRequests() throws {
        for json in [
            #"{"version":2,"mode":0,"eco":false,"expectedWords":[]}"#,
            #"{"version":1,"mode":6,"eco":false,"expectedWords":[]}"#,
            #"{"version":1,"mode":1,"eco":true,"expectedWords":[]}"#,
            #"{"version":1,"mode":0,"eco":false,"expectedWords":[]}"#
        ] {
            let request = try JSONDecoder().decode(PowerServiceRequest.self, from: Data(json.utf8))
            XCTAssertThrowsError(try request.validatedStatus())
        }
    }

    func testPreferenceRoundTripAndExplicitRestore() throws {
        let name = "MSIControl.PowerServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(SavedPowerSelection.load(from: defaults))
        let saved = SavedPowerSelection(preset: .energySaving, eco: true)
        SavedPowerSelection.saveVerified(saved, to: defaults)
        XCTAssertEqual(SavedPowerSelection.load(from: defaults), saved)
        XCTAssertFalse(SavedPowerSelection(preset: .quiet, eco: true).eco)
        defaults.set(Data(#"{"mode":9,"eco":false}"#.utf8), forKey: "mcontrol.lastVerifiedPowerSelection")
        XCTAssertNil(SavedPowerSelection.load(from: defaults))
        SavedPowerSelection.saveVerified(saved, to: defaults)
        SavedPowerSelection.saveVerified(nil, to: defaults)
        XCTAssertNil(SavedPowerSelection.load(from: defaults))
    }
}
