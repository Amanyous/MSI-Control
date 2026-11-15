import ECControl
import Foundation

@main
struct BatteryModelChecks {
    @MainActor
    static func main() async throws {
        let backend = FakeECBackend()
        let model = makeModel(backend)
        require(await backend.counts() == [0, 0, 0, 0])
        require(!model.canApply && !model.canWriteRaw && model.ec == nil)
        await model.applyLimit()
        require(await backend.counts() == [0, 0, 0, 0])
        print("PASS construction and disabled apply never access hardware")

        await model.refreshBattery()
        require(model.battery.percent == 72)
        require(await backend.counts() == [1, 0, 0, 0])
        print("PASS battery refresh is independent of EC")

        await model.refreshEC()
        require(model.canApply && model.selectedLimit == 80 && model.appliedDescription == "80%")
        model.selectedLimit = 60
        require(await backend.counts() == [1, 1, 0, 0])
        await model.applyLimit()
        require(model.lastWrite?.after == 0xBC && model.ec?.chargeByte == 0xBC && model.selectedLimit == 60)
        require(model.status.contains("校验通过") && !model.isBusy)
        require(await backend.lastRequest() == [60, 0xD0])
        print("PASS explicit apply carries expected old byte and accepts verified readback")

        for input in ["", "100", "GG", "-1"] {
            model.addressText = input
            await model.readRegister()
        }
        require(await backend.counts() == [1, 1, 0, 1])
        for address in ["00", "ff"] {
            model.addressText = address
            await model.readRegister()
            require(model.valueText == "AB")
        }
        require(await backend.addresses() == [0, 255])
        print("PASS byte reads validate address and include both boundaries")

        for (address, value) in [("D6", "D0"), ("D7", "50"), ("D7", "89"), ("D7", "E5"), ("D7", "FF")] {
            model.addressText = address; model.valueText = value
            require(!model.canWriteRaw)
            await model.writeRegister()
        }
        require(await backend.counts() == [1, 1, 2, 1])
        model.addressText = "0xd7"; model.valueText = "e4"
        require(model.canWriteRaw)
        await model.writeRegister()
        require(model.lastWrite?.percent == 100 && model.lastWrite?.after == 0xE4)
        require(await backend.lastRequest() == [100, 0xBC])
        print("PASS advanced writes permit only D7 with an encoded charge limit")

        for snapshot in [ECBridgeSnapshot(firmware: "15P4EMS1.106", chargeByte: 0xD0),
                         ECBridgeSnapshot(apiVersion: 0, firmware: "15P4EMS1.107", chargeByte: 0xD0),
                         ECBridgeSnapshot(firmware: "15P4EMS1.107", chargeByte: 0xFF)] {
            await backend.setSnapshot(snapshot)
            await model.refreshEC()
            require(!model.canApply && !model.canWriteRaw)
            let before = await backend.counts()
            await model.applyLimit()
            require(await backend.counts() == before)
        }
        await backend.setSnapshot(ECBridgeSnapshot(firmware: "15P4EMS1.107", chargeByte: 0x80))
        await model.refreshEC()
        require(model.canApply && model.appliedDescription == "固件未报告上限")
        print("PASS unknown firmware, old API and invalid values stay read-only")

        for failure in [FakeECBackend.Mode.fail, .badReadback, .wrongFirmware, .wrongPercent, .wrongBefore] {
            await backend.setSnapshot(ECBridgeSnapshot(firmware: "15P4EMS1.107", chargeByte: 0xD0))
            await model.refreshEC()
            model.selectedLimit = 60
            await backend.setMode(failure)
            await model.applyLimit()
            require(model.lastWrite == nil && model.ec == nil && !model.canApply && !model.isBusy)
            require(model.status.contains("重新读取") && model.registerDescription == model.status)
        }
        print("PASS failures and malformed helper receipts invalidate write eligibility")

        await backend.setMode(.normal)
        await backend.failNextRead()
        await model.refreshEC()
        require(model.ec == nil && model.status.contains("旧驱动") && !model.isBusy)
        model.addressText = "D7"
        await backend.failNextByteRead()
        await model.readRegister()
        require(model.registerDescription.contains("字节读取失败") && !model.isBusy)
        print("PASS unavailable driver and read errors remain visible")

        await model.refreshEC()
        model.selectedLimit = 80
        await backend.holdNextWrite()
        let writing = Task { await model.applyLimit() }
        for _ in 0..<100 {
            if await backend.isHolding() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        require(await backend.isHolding())
        require(model.isBusy && !model.canApply && !model.canWriteRaw)
        let counts = await backend.counts()
        await model.refreshEC(); await model.readRegister(); await model.applyLimit()
        require(await backend.counts() == counts)
        await backend.releaseWrite()
        await writing.value
        require(!model.isBusy && model.lastWrite?.percent == 80)
        print("PASS a pending authorization/write prevents overlapping EC operations")
        print("9 battery model check groups passed with a fake backend; no hardware accessed.")
    }

    private static func require(_ condition: Bool) { precondition(condition) }

    @MainActor
    private static func makeModel(_ backend: FakeECBackend) -> BatteryModel {
        BatteryModel(readBattery: { await backend.battery() }, readEC: { try await backend.snapshot() },
                     readByte: { try await backend.read($0) }, writeLimit: { try await backend.write($0, expected: $1) })
    }
}

private actor FakeECBackend {
    enum Mode { case normal, fail, badReadback, wrongFirmware, wrongPercent, wrongBefore }
    private var calls = [0, 0, 0, 0]
    private var readAddresses: [UInt8] = []
    private var request: [Int] = []
    private var current = ECBridgeSnapshot(firmware: "15P4EMS1.107", chargeByte: 0xD0)
    private var mode = Mode.normal
    private var readFails = false
    private var byteFails = false
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    func counts() -> [Int] { calls }
    func lastRequest() -> [Int] { request }
    func addresses() -> [UInt8] { readAddresses }
    func setSnapshot(_ value: ECBridgeSnapshot) { current = value }
    func setMode(_ value: Mode) { mode = value }
    func failNextRead() { readFails = true }
    func failNextByteRead() { byteFails = true }
    func holdNextWrite() { shouldHold = true }
    func isHolding() -> Bool { held != nil }
    func releaseWrite() { held?.resume(); held = nil }
    func battery() -> BatteryStatus { calls[0] += 1; return BatteryStatus(percent: 72, externalPower: true, isPresent: true) }
    func snapshot() throws -> ECBridgeSnapshot {
        calls[1] += 1
        if readFails { readFails = false; throw ECError.unavailable("旧驱动缺少读写接口") }
        return current
    }
    func read(_ address: UInt8) throws -> UInt8 {
        calls[2] += 1; readAddresses.append(address)
        if byteFails { byteFails = false; throw ECError.unavailable("字节读取失败") }
        return 0xAB
    }
    func write(_ percent: Int, expected: UInt8) async throws -> ECWriteReceipt {
        calls[3] += 1; request = [percent, Int(expected)]
        if shouldHold { shouldHold = false; await withCheckedContinuation { held = $0 } }
        if mode == .fail { throw ECError.unavailable("模拟授权取消或 EC 已变化") }
        let receipt = ECWriteReceipt(firmware: mode == .wrongFirmware ? "15P4EMS1.105" : current.firmware,
                                     percent: mode == .wrongPercent ? 100 : percent,
                                     before: mode == .wrongBefore ? 0xE4 : expected,
                                     after: mode == .badReadback ? expected : ECChargePolicy.encode(mode == .wrongPercent ? 100 : percent)!)
        if mode == .normal { current = ECBridgeSnapshot(firmware: current.firmware, chargeByte: receipt.after) }
        return receipt
    }
}
