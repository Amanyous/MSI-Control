import Foundation
import AppKit
import Combine
@testable import KeyboardLighting

@main
struct RunLightingModelChecks {
    @MainActor
    static func main() async throws {
        let suite = "org.shenying.mcontrol.offline-checks." + UUID().uuidString
        let defaults = MemoryDefaults(suiteName: suite)!
        let key = "keyboardLighting.configuration.v2"
        let model = KeyboardLightingModel(defaults: defaults)
        precondition(model.report == nil && model.lastOperation == nil)
        precondition(!model.isBusy && !model.isAnimating && !model.canControl)
        model.configuration.effect = .breathing
        model.configuration.brightness = 2
        model.configuration.colors[23] = .black
        let restored = KeyboardLightingModel(defaults: defaults)
        precondition(restored.configuration == model.configuration)
        precondition(restored.report == nil && restored.lastOperation == nil)
        precondition(!restored.isBusy && !restored.isAnimating)
        model.turnOff()
        precondition(model.configuration.effect == .breathing)
        model.apply()
        precondition(!model.isBusy && model.lastOperation == nil)
        defaults.set(Data("corrupt".utf8), forKey: key)
        let reset = KeyboardLightingModel(defaults: defaults)
        precondition(reset.configuration == LightingConfiguration())
        precondition(reset.lastOperation == nil && !reset.isBusy)
        print("PASS editor persists 24-zone settings, startup restores without HID access, disconnected actions do not send, corrupt settings reset")

        let legacyDefaults = MemoryDefaults(suiteName: suite + ".legacy")!
        var legacy = LightingConfiguration()
        legacy.effect = .rainbow
        legacy.colors[23] = .black
        legacy.period = 6
        legacyDefaults.set(try JSONEncoder().encode(legacy), forKey: "keyboardLighting.configuration.v1")
        let upgraded = KeyboardLightingModel(defaults: legacyDefaults)
        legacy.period = 2
        precondition(upgraded.configuration == legacy && upgraded.report == nil)
        upgraded.configuration.period = 6
        let keptNewChoice = KeyboardLightingModel(defaults: legacyDefaults)
        precondition(keptNewChoice.configuration.period == 6)
        let customDefaults = MemoryDefaults(suiteName: suite + ".custom")!
        legacy.period = 8
        customDefaults.set(try JSONEncoder().encode(legacy), forKey: "keyboardLighting.configuration.v1")
        let keptLegacyChoice = KeyboardLightingModel(defaults: customDefaults)
        precondition(keptLegacyChoice.configuration == legacy)
        print("PASS legacy default speed upgrades once to 2 seconds; custom and new explicit periods persist")

        let colorDefaults = MemoryDefaults(suiteName: suite + ".colors")!
        let colorModel = KeyboardLightingModel(defaults: colorDefaults, scanDevices: { preconditionFailure("Color editing must not scan HID") }, sendAction: { _, _ in preconditionFailure("Color editing must not send HID") })
        let custom = LightingRGB(red: 51, green: 102, blue: 255)
        colorModel.setColor(custom)
        precondition(colorModel.configuration.colors.allSatisfy { $0 == custom })
        colorModel.selectedZone = 23
        colorModel.setColor(LightingRGB(red: 13, green: 97, blue: 201))
        precondition(colorModel.configuration.colors[23].hex == "#0D61C9")
        precondition(colorModel.configuration.colors.dropLast().allSatisfy { $0 == custom })
        colorModel.selectedZone = 0
        precondition(colorModel.editorColor == custom)
        let restoredColors = KeyboardLightingModel(defaults: colorDefaults)
        precondition(restoredColors.configuration == colorModel.configuration)
        precondition(colorModel.report == nil && colorModel.lastOperation == nil)
        print("PASS custom picker colors persist, edit all or one region, and never touch HID before Apply")

        let backend = FakeKeyboardBackend()
        let controlled = KeyboardLightingModel(defaults: defaults, scanDevices: { await backend.scan() }, sendAction: { action, id in await backend.send(action, id: id) })
        await controlled.refresh()
        precondition(controlled.canControl)
        controlled.configuration.effect = .breathing
        controlled.apply()
        try await waitUntil { controlled.isAnimating && !controlled.isBusy && controlled.lastOperation != nil }
        precondition(controlled.successfulApplyCount == 1)
        let initialCount = await backend.count()
        var pageUpdates = 0
        let observation = controlled.objectWillChange.sink { pageUpdates += 1 }
        let initialStatus = controlled.status
        let initialDescription = controlled.lastSentDescription
        try await waitUntil { await backend.count() >= initialCount + 4 }
        precondition(pageUpdates == 0, "Animation frames must not republish page state")
        precondition(controlled.canControl && !controlled.isBusy && controlled.isAnimating)
        precondition(controlled.status == initialStatus && controlled.lastSentDescription == initialDescription)
        precondition(controlled.successfulApplyCount == 1, "Animation frames must not repeat Apply feedback")
        observation.cancel()
        print("PASS continuous frames keep page publications at zero, status stable and controls available")

        controlled.stopAnimation()
        try await Task.sleep(for: .milliseconds(300))
        let stoppedCount = await backend.count()
        precondition(stoppedCount >= initialCount + 4 && !controlled.isAnimating && !controlled.isBusy)
        try await Task.sleep(for: .milliseconds(200))
        let afterStop = await backend.count()
        precondition(stoppedCount == afterStop)
        print("PASS stopping animation cancels subsequent frames")

        controlled.apply()
        try await waitUntil { controlled.isAnimating && !controlled.isBusy }
        controlled.turnOff()
        try await waitUntil { !controlled.isAnimating && !controlled.isBusy }
        try await Task.sleep(for: .milliseconds(200))
        let lastWasOff = await backend.lastWasOff()
        precondition(lastWasOff)
        precondition(controlled.configuration.effect == .off)
        print("PASS off cancels animation and remains the final operation")

        controlled.configuration.effect = .wave
        controlled.apply()
        try await waitUntil { controlled.isAnimating && !controlled.isBusy }
        await backend.holdNextFrame()
        try await waitUntil { await backend.isHolding() }
        precondition(controlled.canControl && !controlled.isBusy)
        controlled.turnOff()
        await backend.releaseFrame()
        try await waitUntil { !controlled.isBusy && !controlled.isAnimating }
        let offAfterHeldFrame = await backend.lastWasOff()
        let maximumDuringOff = await backend.maximumConcurrent()
        precondition(offAfterHeldFrame && maximumDuringOff == 1)
        print("PASS off waits for an in-flight frame; hardware transactions do not overlap")

        controlled.configuration.effect = .roulette
        controlled.apply()
        try await waitUntil { controlled.isAnimating && !controlled.isBusy }
        controlled.configuration.period = 8
        try await Task.sleep(for: .milliseconds(300))
        precondition(!controlled.isAnimating && !controlled.isBusy)
        let editedCount = await backend.count()
        try await Task.sleep(for: .milliseconds(200))
        let afterEdit = await backend.count()
        precondition(editedCount == afterEdit && controlled.status.contains("参数已修改"))
        print("PASS editing parameters stops subsequent frames and leaves a stable pending state")

        controlled.configuration.effect = .breathing
        controlled.apply()
        try await waitUntil { controlled.isAnimating && !controlled.isBusy }
        controlled.setColor(custom)
        try await Task.sleep(for: .milliseconds(100))
        let afterColorEdit = await backend.count()
        try await Task.sleep(for: .milliseconds(100))
        let afterColorWait = await backend.count()
        precondition(!controlled.isAnimating && !controlled.isBusy && afterColorEdit == afterColorWait)
        precondition(controlled.configuration.colors.allSatisfy { $0 == custom })
        precondition(controlled.status.contains("参数已修改"))
        print("PASS selecting a custom color pauses animation and waits for Apply")

        controlled.configuration.effect = .breathing
        await backend.failNext()
        let successesBeforeFailure = controlled.successfulApplyCount
        controlled.apply()
        try await waitUntil { !controlled.isBusy && !controlled.isAnimating }
        precondition(controlled.lastOperation?.result?.allReportsSent == false)
        precondition(controlled.successfulApplyCount == successesBeforeFailure, "Failed sends must not trigger success feedback")
        let failedCount = await backend.count()
        try await Task.sleep(for: .milliseconds(300))
        let afterFailure = await backend.count()
        precondition(failedCount == afterFailure)
        precondition(controlled.status.contains("failed"))
        print("PASS a failed frame stops animation and preserves diagnostic failure")

        await controlled.refresh()
        precondition(controlled.lastOperation?.result?.allReportsSent == false)
        let maximumConcurrent = await backend.maximumConcurrent()
        precondition(maximumConcurrent == 1)
        print("PASS refresh retains the previous operation; writes never overlap")

        let timingBackend = FakeKeyboardBackend()
        let timingDefaults = MemoryDefaults(suiteName: suite + ".timing")!
        let timingModel = KeyboardLightingModel(defaults: timingDefaults, scanDevices: { await timingBackend.scan() }, sendAction: { action, id in await timingBackend.send(action, id: id) })
        await timingModel.refresh()
        timingModel.configuration.effect = .colorCycle
        timingModel.apply()
        try await waitUntil { await timingBackend.count() >= 12 }
        let starts = await timingBackend.startTimes()
        timingModel.stopAnimation()
        let intervals = zip(starts.dropFirst(), starts).map { $0 - $1 }
        let averageInterval = intervals.reduce(0, +) / Double(intervals.count)
        precondition(averageInterval < 0.1, "Frames still include a fixed 125ms pause")
        let incrementalCount = await timingBackend.incrementalFrames()
        precondition(incrementalCount >= 11)
        print(String(format: "PASS animation averages %.1f fps on a 15ms fake transport; subsequent frames are incremental", 1 / averageInterval))

        let slowBackend = FakeKeyboardBackend(delay: .milliseconds(180))
        let slowModel = KeyboardLightingModel(defaults: timingDefaults, scanDevices: { await slowBackend.scan() }, sendAction: { action, id in await slowBackend.send(action, id: id) })
        await slowModel.refresh()
        slowModel.configuration.effect = .rainbow
        slowModel.apply()
        try await waitUntil { await slowBackend.count() >= 4 }
        slowModel.stopAnimation()
        try await Task.sleep(for: .milliseconds(250))
        let slowMaximum = await slowBackend.maximumConcurrent()
        precondition(slowMaximum == 1)
        let slowCount = await slowBackend.count()
        try await Task.sleep(for: .milliseconds(200))
        let afterSlowStop = await slowBackend.count()
        precondition(slowCount == afterSlowStop)
        print("PASS a slow transport never queues overlapping frames and stops without backlog")
        let appliedKey = "keyboardLighting.lastApplied.v1"
        let snapshot = defaults.data(forKey: appliedKey)!
        let applied = try JSONDecoder().decode(LightingConfiguration.self, from: snapshot)
        let startupBackend = FakeKeyboardBackend()
        let startup = KeyboardLightingModel(defaults: defaults, scanDevices: { await startupBackend.scan() }, sendAction: { action, id in await startupBackend.send(action, id: id) })
        await startup.restoreAtStartup()
        try await waitUntil { startup.lastOperation != nil && !startup.isBusy }
        precondition(startup.isAnimating == applied.effect.isAnimated)
        let restoredSnapshot = try JSONDecoder().decode(LightingConfiguration.self, from: defaults.data(forKey: appliedKey)!)
        precondition(restoredSnapshot == applied)
        let savedAfterRestore = defaults.data(forKey: appliedKey)
        startup.stopAnimation()
        try await Task.sleep(for: .milliseconds(100))
        let restoredCount = await startupBackend.count()
        await startup.restoreAtStartup()
        try await Task.sleep(for: .milliseconds(100))
        let repeatedCount = await startupBackend.count()
        precondition(restoredCount == repeatedCount)
        startup.configuration.brightness = 1
        precondition(defaults.data(forKey: appliedKey) == savedAfterRestore)
        await startupBackend.failNext()
        startup.apply()
        try await waitUntil { !startup.isBusy }
        precondition(defaults.data(forKey: appliedKey) == savedAfterRestore)
        let noSnapshot = KeyboardLightingModel(defaults: MemoryDefaults(suiteName: suite + ".empty")!, scanDevices: { preconditionFailure("No applied snapshot must not scan") })
        await noSnapshot.restoreAtStartup()
        print("PASS startup restores the applied effect once; edits, failed writes and missing snapshots are safe")
        print("Model checks passed with a fake backend; no hardware accessed.")
    }

    @MainActor
    static func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for model state")
    }
}

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Data] = [:]
    override func data(forKey key: String) -> Data? { values[key] }
    override func set(_ value: Any?, forKey key: String) {
        values[key] = value as? Data
    }
}

private actor FakeKeyboardBackend {
    private var sent = 0
    private var inFlight = 0
    private var maximum = 0
    private var nextFails = false
    private var wasOff = false
    private var holdNext = false
    private var heldFrame: CheckedContinuation<Void, Never>?
    private var starts: [Double] = []
    private var incremental = 0
    private let delay: Duration

    init(delay: Duration = .milliseconds(15)) { self.delay = delay }

    func scan() -> LightingReport {
        let device = LightingDevice(id: 1, vendorID: 0x1462, productID: 0x1603, name: "Fake", manufacturer: "Fake", transport: "Fake", usagePage: 0xFF00, usage: 1, maximumFeatureBytes: 64, featureReports: [1: 64, 2: 64], descriptorHex: nil)
        return LightingReport(createdAt: Date(), scan: LightingScan(devices: [device], error: nil), result: nil)
    }

    func send(_ action: LightingAction, id: UInt64) async -> LightingReport {
        precondition(id == 1)
        inFlight += 1
        maximum = max(maximum, inFlight)
        starts.append(ProcessInfo.processInfo.systemUptime)
        if action.isIncrementalFrame { incremental += 1 }
        // Like an in-flight hardware transaction, this finishes before stopping.
        if holdNext {
            holdNext = false
            await withCheckedContinuation { heldFrame = $0 }
        } else {
            let delay = delay
            await Task.detached { try? await Task.sleep(for: delay) }.value
        }
        sent += 1
        if case .turnOff = action { wasOff = true }
        let success = !nextFails
        nextFails = false
        inFlight -= 1
        let result = LightingResult(action: action.title, reportsSent: success ? 2 : 0, allReportsSent: success, message: success ? "sent" : "failed", trace: [])
        return LightingReport(createdAt: Date(), scan: scan().scan, result: result)
    }

    func count() -> Int { sent }
    func lastWasOff() -> Bool { wasOff }
    func maximumConcurrent() -> Int { maximum }
    func startTimes() -> [Double] { starts }
    func incrementalFrames() -> Int { incremental }
    func failNext() { nextFails = true }
    func holdNextFrame() { holdNext = true }
    func isHolding() -> Bool { heldFrame != nil }
    func releaseFrame() { heldFrame?.resume(); heldFrame = nil }
}
