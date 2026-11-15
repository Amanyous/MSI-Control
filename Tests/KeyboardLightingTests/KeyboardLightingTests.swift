import Foundation

struct KeyboardLightingChecks {
    // Vendor HID collection with 63 payload bytes + Report ID for reports 1/2.
    private let descriptor = Data([
        0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01,
        0x85, 0x01, 0x75, 0x08, 0x95, 0x3F, 0xB1, 0x02,
        0x85, 0x02, 0x75, 0x08, 0x95, 0x3F, 0xB1, 0x02, 0xC0
    ])

    private func device(vendor: Int = 0x1462, product: Int = 0x1603, reports: [Int: Int]? = [1: 64, 2: 64]) -> LightingDevice {
        LightingDevice(id: 123, vendorID: vendor, productID: product, name: "Test Mystic Light",
                       manufacturer: "MSI", transport: "Test", usagePage: 0xFF00, usage: 1,
                       maximumFeatureBytes: 64, featureReports: reports, descriptorHex: nil)
    }

    func testDescriptorIncludesNonzeroReportIDInLength() {
        expectEqual(HIDFeatureLayout.parse(descriptor), [1: 64, 2: 64])
    }

    func testTruncatedAndMalformedDescriptorsDoNotAuthorizeWrites() {
        let malformed: [Data] = [Data(), Data([0x06, 0x00]), Data([0xFE, 0x01, 0]),
                                 Data([0xB4]), Data([0xC0]), Data(descriptor.dropLast()),
                                 Data([0xA1, 1, 0x85, 0, 0xB1, 2, 0xC0])]
        for bytes in malformed {
            expectNil(HIDFeatureLayout.parse(bytes))
            expectFalse(device(reports: HIDFeatureLayout.parse(bytes)).supportsTrial)
        }
    }

    func testGlobalPushPopAndMultipleFeatureItems() {
        let bytes = Data([
            0xA1, 1, 0x85, 2, 0x75, 8, 0x95, 31, 0xB1, 2,
            0xA4, 0x85, 3, 0x95, 2, 0xB1, 2, 0xB4,
            0x95, 32, 0xB1, 2, 0xC0
        ])
        expectEqual(HIDFeatureLayout.parse(bytes), [2: 64, 3: 3])
    }

    func testInputReportsCannotBeMistakenForFeatureReports() {
        var bytes = [UInt8](descriptor)
        bytes[13] = 0x81
        bytes[21] = 0x81
        expectEqual(HIDFeatureLayout.parse(Data(bytes)), [:])
        expectFalse(device(reports: HIDFeatureLayout.parse(Data(bytes))).supportsTrial)
    }

    func testReportWithNoIDDoesNotGainAnExtraByte() {
        let bytes = Data([0xA1, 1, 0x75, 8, 0x95, 64, 0xB1, 2, 0xC0])
        expectEqual(HIDFeatureLayout.parse(bytes), [0: 64])
        expectFalse(device(reports: HIDFeatureLayout.parse(bytes)).supportsTrial)
    }

    func testWrongProductOrReportLengthNeverOpensDevice() {
        for info in [device(vendor: 0x1770), device(product: 0x1601), device(product: 0x1563),
                     device(reports: [2: 63]), device(reports: [2: 65]), device(reports: nil)] {
            let transport = FakeTransport()
            let result = LightingTransaction.perform(.turnOff, device: info, transport: transport)
            expectEqual(transport.events, [])
            expectFalse(result.allReportsSent)
            expectEqual(result.reportsSent, 0)
        }
    }

    func testCapturedSteadyPacketKeepsBothKeyframeTimesAndCoversAll24Zones() {
        let packets = MysticLightProtocol.reports(for: .solid(red: 10, green: 20, blue: 30))
        // Golden bytes from the 1462:1603 MSI Center protocol, not a hardware test.
        let expectedZones: [UInt8] = [2, 1, 255, 255, 255, 0] + Array(repeating: 0, count: 58)
        expectEqual(packets[0], expectedZones)
        var expectedColor: [UInt8] = [2, 2, 1, 88, 2, 0, 50, 8, 1, 1]
        expectedColor += [0, 10, 20, 30, 100, 10, 20, 30]
        expectedColor += Array(repeating: 0, count: 46)
        expectEqual(packets[1], expectedColor)
    }

    func testOffUsesBlackAcrossAllZonesAndDoesNotSaveToFlash() {
        let transport = FakeTransport()
        let result = LightingTransaction.perform(.turnOff, device: device(), transport: transport)
        expectEqual(transport.events, ["open", "write", "read", "write", "read", "close"])
        expectEqual(transport.writes.count, 2)
        expectEqual(Array(transport.writes[0][2...5]), [255, 255, 255, 0])
        expectEqual(Array(transport.writes[1][11...13]), [0, 0, 0])
        expectEqual(Array(transport.writes[1][15...17]), [0, 0, 0])
        expectTrue(transport.writes.allSatisfy { $0.count == 64 && $0[0] == 2 && $0[1] != 0xA0 })
        expectTrue(result.allReportsSent)
        expectTrue(result.message.contains("确认效果"))
        expectFalse(result.message.contains("已关闭"))
    }

    func testOpenFailureNeverWrites() {
        let transport = FakeTransport()
        transport.openCode = -1
        let result = LightingTransaction.perform(.turnOff, device: device(), transport: transport)
        expectEqual(transport.events, ["open"])
        expectFalse(result.allReportsSent)
        expectEqual(result.reportsSent, 0)
        expectEqual(result.trace.first?.returnCode, "0xFFFFFFFF")
    }

    func testZoneSelectionFailureStopsBeforeColorWrite() {
        let transport = FakeTransport()
        transport.writeCodes = [-1]
        let result = LightingTransaction.perform(.turnOff, device: device(), transport: transport)
        expectEqual(transport.events, ["open", "write", "close"])
        expectEqual(result.reportsSent, 0)
        expectFalse(result.allReportsSent)
    }

    func testPartialWriteFailureIsNotReportedAsSuccess() {
        let transport = FakeTransport()
        transport.writeCodes = [0, -1]
        let result = LightingTransaction.perform(.turnOff, device: device(), transport: transport)
        expectEqual(transport.events, ["open", "write", "read", "write", "close"])
        expectEqual(result.reportsSent, 1)
        expectFalse(result.allReportsSent)
        expectTrue(result.message.contains("发送失败"))
    }

    func testOptionalReadFailureRemainsVisibleInTrace() {
        let transport = FakeTransport()
        transport.readCode = -1
        let result = LightingTransaction.perform(.turnOff, device: device(), transport: transport)
        expectEqual(result.reportsSent, 2)
        expectEqual(result.trace.filter { $0.returnCode == "0xFFFFFFFF" }.count, 2)
        expectTrue(result.message.contains("确认效果"))
    }

    func testNoReadIsIssuedForUnknownReplyLayout() {
        let transport = FakeTransport()
        _ = LightingTransaction.perform(.turnOff, device: device(reports: [2: 64]), transport: transport)
        expectFalse(transport.events.contains("read"))
    }

    func testLoadSavedOnlySendsDocumentedLoadCommand() {
        let transport = FakeTransport()
        let result = LightingTransaction.perform(.loadSaved, device: device(), transport: transport)
        let expected: [UInt8] = [2, 0xB0] + Array(repeating: 0, count: 62)
        expectEqual(transport.writes, [expected])
        expectEqual(result.reportsSent, 1)
    }

    func testSaveSendsOnlyTheDocumentedFlashCommand() {
        let transport = FakeTransport()
        let result = LightingTransaction.perform(.save, device: device(), transport: transport)
        let expected: [UInt8] = [2, 0xA0] + Array(repeating: 0, count: 62)
        expectEqual(transport.writes, [expected])
        expectEqual(transport.events, ["open", "write", "close"])
        expectEqual(result.reportsSent, 1)
        expectTrue(result.allReportsSent)
    }

    func testDiagnosticRetainsFailuresAndDescriptorLayout() throws {
        let transport = FakeTransport()
        transport.writeCodes = [-1]
        let result = LightingTransaction.perform(.turnOff, device: device(), transport: transport)
        let report = LightingReport(createdAt: Date(), scan: LightingScan(devices: [device()], error: nil), result: result)
        let encoded = try report.json()
        guard let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let decodedResult = decoded["result"] as? [String: Any] else { fatalError("Missing diagnostic result") }
        expectEqual(decodedResult["allReportsSent"] as? Bool, false)
        expectEqual(decodedResult["reportsSent"] as? Int, 0)
        let text = String(decoding: encoded, as: UTF8.self)
        expectTrue(text.contains("0xFFFFFFFF"))
        expectTrue(text.contains("featureReports"))
        expectFalse(text.contains("serialNumber"))
    }

    func testZoneGroupsKeepColorsAndCoverAll24ZonesExactlyOnce() {
        let red = LightingRGB(red: 255, green: 0, blue: 0)
        let blue = LightingRGB(red: 0, green: 0, blue: 255)
        var colors = Array(repeating: red, count: 24)
        colors[23] = blue
        let transport = FakeTransport()
        let result = LightingTransaction.perform(.frame(colors: colors), device: device(), transport: transport)
        expectEqual(transport.writes.count, 4)
        let lowerMask: [UInt8] = [2, 1, 255, 255, 127, 0]
        let upperMask: [UInt8] = [2, 1, 0, 0, 128, 0]
        expectEqual(Array(transport.writes[0].prefix(6)), lowerMask)
        expectEqual(Array(transport.writes[2].prefix(6)), upperMask)
        expectEqual(Array(transport.writes[1][11...13]), [255, 0, 0])
        expectEqual(Array(transport.writes[3][11...13]), [0, 0, 255])
        expectTrue(result.allReportsSent)
    }

    func testDistinctZoneColorsHaveNonoverlappingMasksAndBoundedReportCount() {
        let colors = (0..<24).map { LightingRGB(red: UInt8($0), green: 30, blue: 40) }
        let packets = MysticLightProtocol.reports(for: .frame(colors: colors))
        expectEqual(packets.count, 48)
        var combined: UInt32 = 0
        for index in stride(from: 0, to: packets.count, by: 2) {
            let packet = packets[index]
            let mask = UInt32(packet[2]) | (UInt32(packet[3]) << 8) | (UInt32(packet[4]) << 16)
            expectEqual(combined & mask, 0)
            combined |= mask
            expectEqual(packet[5], 0)
            expectTrue(packets[index + 1][1] != 0xA0)
            expectEqual(packets[index + 1].count, 64)
        }
        expectEqual(combined, 0x00FF_FFFF)
    }

    func testUniformZoneFrameKeepsOriginalFullKeyboardPacket() {
        let color = LightingRGB(red: 10, green: 20, blue: 30)
        let frame = MysticLightProtocol.reports(for: .frame(colors: Array(repeating: color, count: 24)))
        expectEqual(frame, MysticLightProtocol.reports(for: .solid(red: 10, green: 20, blue: 30)))
    }

    func testIncrementalFramesOnlyWriteChangedZonesAndSkipOptionalRead() {
        let red = LightingRGB(red: 255, green: 0, blue: 0)
        let blue = LightingRGB(red: 0, green: 0, blue: 255)
        let previous = Array(repeating: red, count: 24)
        var colors = previous
        colors[0] = blue
        colors[23] = blue
        let transport = FakeTransport()
        let result = LightingTransaction.perform(.frame(colors: colors, previous: previous), device: device(), transport: transport)
        expectTrue(result.allReportsSent)
        expectEqual(result.reportsSent, 2)
        expectEqual(transport.events, ["open", "write", "write", "close"])
        expectEqual(Array(transport.writes[0].prefix(6)), [2, 1, 1, 0, 128, 0])
        expectEqual(Array(transport.writes[1][11...13]), [0, 0, 255])
    }

    func testIdenticalIncrementalFrameDoesNotOpenOrWrite() {
        let colors = Array(repeating: LightingRGB.defaultColor, count: 24)
        let transport = FakeTransport()
        let result = LightingTransaction.perform(.frame(colors: colors, previous: colors), device: device(), transport: transport)
        expectTrue(result.allReportsSent)
        expectEqual(result.reportsSent, 0)
        expectEqual(transport.events, [])
    }

    func testInvalidPreviousFrameAndFailedIncrementalWriteNeverContinue() {
        let colors = Array(repeating: LightingRGB.defaultColor, count: 24)
        for previousCount in [0, 23, 25] {
            let transport = FakeTransport()
            let result = LightingTransaction.perform(.frame(colors: colors, previous: Array(repeating: .black, count: previousCount)), device: device(), transport: transport)
            expectFalse(result.allReportsSent)
            expectEqual(transport.events, [])
        }
        let transport = FakeTransport()
        transport.writeCodes = [0, -1]
        let result = LightingTransaction.perform(.frame(colors: colors, previous: Array(repeating: .black, count: 24)), device: device(), transport: transport)
        expectFalse(result.allReportsSent)
        expectEqual(result.reportsSent, 1)
        expectEqual(transport.events, ["open", "write", "write", "close"])
    }

    func testIncrementalEffectFramesReconstructFullFrameWithoutStaleZones() {
        var configuration = LightingConfiguration()
        for effect in LightingEffect.allCases {
            configuration.effect = effect
            var previous = configuration.frame(at: 0)
            for step in 1...60 {
                let colors = configuration.frame(at: Double(step) * configuration.period / 60)
                let packets = MysticLightProtocol.reports(for: .frame(colors: colors, previous: previous))
                var actual = previous
                var updatedMask: UInt32 = 0
                for index in stride(from: 0, to: packets.count, by: 2) {
                    let maskBytes = packets[index]
                    let mask = UInt32(maskBytes[2]) | (UInt32(maskBytes[3]) << 8) | (UInt32(maskBytes[4]) << 16)
                    expectEqual(updatedMask & mask, 0)
                    updatedMask |= mask
                    let rgbBytes = packets[index + 1]
                    let color = LightingRGB(red: rgbBytes[11], green: rgbBytes[12], blue: rgbBytes[13])
                    for zone in 0..<24 where mask & (1 << zone) != 0 {
                        expectTrue(previous[zone] != colors[zone])
                        actual[zone] = color
                    }
                }
                expectEqual(actual, colors)
                previous = colors
            }
        }
    }

    func testInvalidFrameDoesNotOpenDevice() {
        for count in [0, 1, 23, 25] {
            let transport = FakeTransport()
            let result = LightingTransaction.perform(.frame(colors: Array(repeating: .black, count: count)), device: device(), transport: transport)
            expectFalse(result.allReportsSent)
            expectEqual(transport.events, [])
        }
    }

    func testBrightnessAndOffAffectEveryZoneWithoutChangingSavedColors() {
        var configuration = LightingConfiguration()
        configuration.colors[23] = LightingRGB(red: 40, green: 80, blue: 120)
        let source = configuration.colors
        configuration.brightness = 2
        let frame = configuration.frame(at: 0)
        expectEqual(frame[23], LightingRGB(red: 20, green: 40, blue: 60))
        expectEqual(configuration.colors, source)
        configuration.brightness = 0
        expectTrue(configuration.frame(at: 0).allSatisfy { $0 == .black })
        configuration.brightness = 4
        configuration.effect = .off
        expectTrue(configuration.frame(at: 0).allSatisfy { $0 == .black })
        expectEqual(configuration.colors, source)
    }

    func testBreathingIsPeriodicAndReachesBlackWithoutDiscardingZoneColor() {
        var configuration = LightingConfiguration()
        configuration.effect = .breathing
        expectEqual(configuration.frame(at: 0), configuration.colors)
        expectTrue(configuration.frame(at: configuration.period / 2).allSatisfy { $0 == .black })
        expectEqual(configuration.frame(at: configuration.period), configuration.colors)
        expectEqual(configuration.frame(at: configuration.period / 4), configuration.frame(at: configuration.period * 0.75))
    }

    func testColorCycleUsesFullSpectrumRegardlessOfPreviousColor() {
        var configuration = LightingConfiguration()
        configuration.effect = .colorCycle
        configuration.colors = Array(repeating: LightingRGB(red: 255, green: 0, blue: 0), count: 24)
        configuration.colors[23] = LightingRGB(red: 40, green: 40, blue: 40)
        expectEqual(configuration.frame(at: configuration.period / 3)[0], LightingRGB(red: 0, green: 255, blue: 0))
        expectEqual(configuration.frame(at: configuration.period * 2 / 3)[0], LightingRGB(red: 0, green: 0, blue: 255))
        expectEqual(configuration.frame(at: configuration.period), configuration.frame(at: 0))
        expectEqual(configuration.frame(at: 1)[23], configuration.frame(at: 1)[0])
    }

    func testConfigurationRestoresEveryEffectAndRejectsCorruptValues() throws {
        var configuration = LightingConfiguration()
        configuration.effect = .breathing
        configuration.colors[23] = .black
        configuration.brightness = 2
        configuration.period = 8
        let data = try JSONEncoder().encode(configuration)
        expectEqual(LightingConfiguration.restore(from: data), configuration)
        expectEqual(LightingConfiguration.restore(from: Data("broken".utf8)), LightingConfiguration())
        expectEqual(LightingConfiguration.restore(from: nil), LightingConfiguration())
        for effect in LightingEffect.allCases {
            configuration.effect = effect
            let data = try JSONEncoder().encode(configuration)
            expectEqual(LightingConfiguration.restore(from: data), configuration)
        }
        configuration.effect = .solid
        configuration.colors.removeLast()
        let invalid = try JSONEncoder().encode(configuration)
        expectEqual(LightingConfiguration.restore(from: invalid), LightingConfiguration())
    }

    func testEveryEffectIsPeriodicAndUsesOnlyBounded24ZoneReports() {
        var configuration = LightingConfiguration()
        configuration.colors = Array(repeating: LightingRGB(red: 255, green: 80, blue: 20), count: 24)
        for effect in LightingEffect.allCases {
            configuration.effect = effect
            let start = configuration.frame(at: 0)
            expectEqual(start.count, 24)
            expectEqual(configuration.frame(at: configuration.period), start)
            for sample in 0..<48 {
                let frame = configuration.frame(at: Double(sample) / 8)
                let reports = MysticLightProtocol.reports(for: .frame(colors: frame))
                expectTrue((2...48).contains(reports.count))
                expectTrue(reports.allSatisfy { $0.count == 64 && $0[0] == 2 && [1, 2].contains($0[1]) })
                var mask: UInt32 = 0
                for index in stride(from: 0, to: reports.count, by: 2) {
                    let packet = reports[index]
                    let zoneMask = UInt32(packet[2]) | (UInt32(packet[3]) << 8) | (UInt32(packet[4]) << 16)
                    mask |= zoneMask
                }
                expectEqual(mask, 0x00FF_FFFF)
            }
            if effect.isAnimated { expectTrue(start != configuration.frame(at: configuration.period / 4)) }
            configuration.brightness = 0
            expectTrue(configuration.frame(at: 1.5).allSatisfy { $0 == .black })
            configuration.brightness = 4
        }
    }

    func testSpatialEffectsAndAutomaticPaletteHaveDistinctBehavior() {
        var configuration = LightingConfiguration()
        configuration.effect = .rainbow
        expectEqual(configuration.frame(at: 0)[0], LightingRGB(red: 255, green: 0, blue: 0))
        expectEqual(configuration.frame(at: 0)[8], LightingRGB(red: 0, green: 255, blue: 0))
        configuration.effect = .wave
        expectEqual(configuration.frame(at: 0)[0], configuration.colors[0])
        expectEqual(configuration.frame(at: 0)[12], .black)
        configuration.effect = .ripple
        let ripple = configuration.frame(at: 1.5)
        for zone in 0..<12 { expectEqual(ripple[zone], ripple[23 - zone]) }
        configuration.effect = .roulette
        expectEqual(configuration.frame(at: 0)[0], LightingRGB(red: 255, green: 0, blue: 0))
        expectEqual(configuration.frame(at: 0)[12], .black)
        for effect in [LightingEffect.rainbow, .colorCycle, .roulette] {
            configuration.effect = effect
            let expected = configuration.frame(at: 1)
            configuration.colors = Array(repeating: .black, count: 24)
            expectEqual(configuration.frame(at: 1), expected)
            expectFalse(effect.usesSelectedColors)
        }
        expectTrue(LightingEffect.breathing.usesSelectedColors)
    }

    func testRGBHexAcceptsOnlyEightBitOpaqueColor() {
        expectEqual(LightingRGB(hex: " #fF8000 "), LightingRGB(red: 255, green: 128, blue: 0))
        expectEqual(LightingRGB(hex: "000000"), .black)
        expectEqual(LightingRGB(hex: "FFFFFF")?.hex, "#FFFFFF")
        for invalid in ["", "#fff", "#12345678", "1234567", "GG0000", "+12345", "#-12345", "#12 345"] {
            expectNil(LightingRGB(hex: invalid))
        }
    }

    func testInvalidTimingAndBrightnessProduceNoFrame() {
        for period in [Double.nan, .infinity, -1, 0, 0.49, 13] {
            var configuration = LightingConfiguration()
            configuration.period = period
            expectFalse(configuration.isValid)
            expectEqual(configuration.frame(at: 0), [])
        }
        for brightness in [-1, 5, 255] {
            var configuration = LightingConfiguration()
            configuration.brightness = brightness
            expectFalse(configuration.isValid)
            expectEqual(configuration.frame(at: 0), [])
        }
        let configuration = LightingConfiguration()
        expectEqual(configuration.frame(at: .infinity), configuration.frame(at: 0))
    }

    func testFastPeriodsPreserveTimingAndLegacyPeriodsRemainValid() throws {
        expectEqual(LightingConfiguration().period, 2)
        for period in [0.5, 1, 1.5, 2, 3, 6, 8, 12] {
            var configuration = LightingConfiguration()
            configuration.effect = .breathing
            configuration.period = period
            expectTrue(configuration.isValid)
            expectTrue(configuration.frame(at: period / 2).allSatisfy { $0 == .black })
            expectEqual(configuration.frame(at: period), configuration.frame(at: 0))
            let data = try JSONEncoder().encode(configuration)
            expectEqual(LightingConfiguration.restore(from: data), configuration)
        }
    }

    func testSelectedZoneEditsDoNotOverwriteOtherColors() {
        var configuration = LightingConfiguration()
        let blue = LightingRGB(red: 0, green: 0, blue: 255)
        configuration.setColor(blue, zone: 23)
        expectEqual(configuration.colors[23], blue)
        expectEqual(configuration.colors[0], .defaultColor)
        configuration.setColor(.black, zone: 24)
        expectEqual(configuration.colors[23], blue)
        configuration.setColor(.black, zone: nil)
        expectTrue(configuration.colors.allSatisfy { $0 == .black })
    }
}

private final class FakeTransport: LightingTransport {
    var openCode: Int32 = 0
    var writeCodes: [Int32] = []
    var readCode: Int32 = 0
    var events: [String] = []
    var writes: [[UInt8]] = []

    func open() -> Int32 { events.append("open"); return openCode }
    func close() { events.append("close") }
    func send(_ bytes: [UInt8]) -> Int32 {
        events.append("write")
        writes.append(bytes)
        return writeCodes.isEmpty ? 0 : writeCodes.removeFirst()
    }
    func readReply() -> (code: Int32, bytes: [UInt8]) {
        events.append("read")
        return (readCode, readCode == 0 ? [1, 0] : [])
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
private func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "Expected false", file: file, line: line)
}
private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}

@main
struct RunKeyboardLightingChecks {
    static func main() throws {
        let checks = KeyboardLightingChecks()
        let tests: [(String, () throws -> Void)] = [
            ("testDescriptorIncludesNonzeroReportIDInLength", checks.testDescriptorIncludesNonzeroReportIDInLength),
            ("testTruncatedAndMalformedDescriptorsDoNotAuthorizeWrites", checks.testTruncatedAndMalformedDescriptorsDoNotAuthorizeWrites),
            ("testGlobalPushPopAndMultipleFeatureItems", checks.testGlobalPushPopAndMultipleFeatureItems),
            ("testInputReportsCannotBeMistakenForFeatureReports", checks.testInputReportsCannotBeMistakenForFeatureReports),
            ("testReportWithNoIDDoesNotGainAnExtraByte", checks.testReportWithNoIDDoesNotGainAnExtraByte),
            ("testWrongProductOrReportLengthNeverOpensDevice", checks.testWrongProductOrReportLengthNeverOpensDevice),
            ("testCapturedSteadyPacketKeepsBothKeyframeTimesAndCoversAll24Zones", checks.testCapturedSteadyPacketKeepsBothKeyframeTimesAndCoversAll24Zones),
            ("testOffUsesBlackAcrossAllZonesAndDoesNotSaveToFlash", checks.testOffUsesBlackAcrossAllZonesAndDoesNotSaveToFlash),
            ("testOpenFailureNeverWrites", checks.testOpenFailureNeverWrites),
            ("testZoneSelectionFailureStopsBeforeColorWrite", checks.testZoneSelectionFailureStopsBeforeColorWrite),
            ("testPartialWriteFailureIsNotReportedAsSuccess", checks.testPartialWriteFailureIsNotReportedAsSuccess),
            ("testOptionalReadFailureRemainsVisibleInTrace", checks.testOptionalReadFailureRemainsVisibleInTrace),
            ("testNoReadIsIssuedForUnknownReplyLayout", checks.testNoReadIsIssuedForUnknownReplyLayout),
            ("testLoadSavedOnlySendsDocumentedLoadCommand", checks.testLoadSavedOnlySendsDocumentedLoadCommand),
            ("testSaveSendsOnlyTheDocumentedFlashCommand", checks.testSaveSendsOnlyTheDocumentedFlashCommand),
            ("testDiagnosticRetainsFailuresAndDescriptorLayout", checks.testDiagnosticRetainsFailuresAndDescriptorLayout),
            ("testZoneGroupsKeepColorsAndCoverAll24ZonesExactlyOnce", checks.testZoneGroupsKeepColorsAndCoverAll24ZonesExactlyOnce),
            ("testDistinctZoneColorsHaveNonoverlappingMasksAndBoundedReportCount", checks.testDistinctZoneColorsHaveNonoverlappingMasksAndBoundedReportCount),
            ("testUniformZoneFrameKeepsOriginalFullKeyboardPacket", checks.testUniformZoneFrameKeepsOriginalFullKeyboardPacket),
            ("testIncrementalFramesOnlyWriteChangedZonesAndSkipOptionalRead", checks.testIncrementalFramesOnlyWriteChangedZonesAndSkipOptionalRead),
            ("testIdenticalIncrementalFrameDoesNotOpenOrWrite", checks.testIdenticalIncrementalFrameDoesNotOpenOrWrite),
            ("testInvalidPreviousFrameAndFailedIncrementalWriteNeverContinue", checks.testInvalidPreviousFrameAndFailedIncrementalWriteNeverContinue),
            ("testIncrementalEffectFramesReconstructFullFrameWithoutStaleZones", checks.testIncrementalEffectFramesReconstructFullFrameWithoutStaleZones),
            ("testInvalidFrameDoesNotOpenDevice", checks.testInvalidFrameDoesNotOpenDevice),
            ("testBrightnessAndOffAffectEveryZoneWithoutChangingSavedColors", checks.testBrightnessAndOffAffectEveryZoneWithoutChangingSavedColors),
            ("testBreathingIsPeriodicAndReachesBlackWithoutDiscardingZoneColor", checks.testBreathingIsPeriodicAndReachesBlackWithoutDiscardingZoneColor),
            ("testColorCycleUsesFullSpectrumRegardlessOfPreviousColor", checks.testColorCycleUsesFullSpectrumRegardlessOfPreviousColor),
            ("testConfigurationRestoresEveryEffectAndRejectsCorruptValues", checks.testConfigurationRestoresEveryEffectAndRejectsCorruptValues),
            ("testEveryEffectIsPeriodicAndUsesOnlyBounded24ZoneReports", checks.testEveryEffectIsPeriodicAndUsesOnlyBounded24ZoneReports),
            ("testSpatialEffectsAndAutomaticPaletteHaveDistinctBehavior", checks.testSpatialEffectsAndAutomaticPaletteHaveDistinctBehavior),
            ("testRGBHexAcceptsOnlyEightBitOpaqueColor", checks.testRGBHexAcceptsOnlyEightBitOpaqueColor),
            ("testInvalidTimingAndBrightnessProduceNoFrame", checks.testInvalidTimingAndBrightnessProduceNoFrame),
            ("testFastPeriodsPreserveTimingAndLegacyPeriodsRemainValid", checks.testFastPeriodsPreserveTimingAndLegacyPeriodsRemainValid),
            ("testSelectedZoneEditsDoNotOverwriteOtherColors", checks.testSelectedZoneEditsDoNotOverwriteOtherColors)
        ]
        for (name, test) in tests {
            try test()
            print("PASS " + name)
        }
        print("\(tests.count) offline protocol / failure-path checks passed; no hardware accessed.")
    }
}
