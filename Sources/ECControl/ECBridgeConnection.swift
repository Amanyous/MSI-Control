import Foundation
import IOKit

// Connections are short-lived; callers serialize individual hardware operations.
public final class ECBridgeConnection {
    private var connection: io_connect_t = 0
    private let driverVersion: String
    public let apiVersion: Int

    public init() throws {
        guard let matching = IOServiceMatching("MSIEmbeddedControllerBridge") else {
            throw ECError.unavailable("无法查找 EC 驱动服务")
        }
        var iterator: io_iterator_t = 0
        let matchingCode = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard matchingCode == KERN_SUCCESS else { throw ECError.system(operation: "查找 EC 驱动", code: matchingCode) }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { throw ECError.unavailable("EC 驱动未加载。请在“驱动配置”中配置新版 Kext，并重启目标机。") }
        defer { IOObjectRelease(service) }
        let duplicate = IOIteratorNext(iterator)
        if duplicate != 0 {
            IOObjectRelease(duplicate)
            throw ECError.unavailable("发现多个 EC 桥接服务，未执行读写")
        }
        let version = IORegistryEntryCreateCFProperty(service, "MSIECAPI" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        guard let api = version?.intValue, (2...9).contains(api) else {
            throw ECError.unavailable("当前 EC 驱动 API 不兼容，请配置随应用附带的新版驱动并重启。")
        }
        apiVersion = api
        driverVersion = api == 9 ? "0.3.6" : api == 8 ? "0.3.5" : api == 7 ? "0.3.4" : api == 6 ? "0.3.3" : api == 5 ? "0.3.2" : api == 4 ? "0.3.1" : api == 3 ? "0.3.0" : "0.2.1"
        let code = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "打开 EC 驱动", code: code) }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    public func touchpadEnabled(_ desired: Bool? = nil) throws -> Bool {
        guard apiVersion >= 9 else {
            throw ECError.unavailable("Touchpad control requires MSIECBridge 0.3.6.")
        }
        var input: UInt64 = desired.map { $0 ? 1 : 0 } ?? 2
        var output: UInt64 = 0
        var count: UInt32 = 1
        let code = IOConnectCallScalarMethod(connection, 10, &input, 1, &output, &count)
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "Touchpad", code: code) }
        guard count == 1, output <= 1, desired == nil || (output == 1) == desired else {
            throw ECError.mismatch("Touchpad state verification failed.")
        }
        return output == 1
    }

    public func setMuteIndicator(microphone: Bool, muted: Bool) throws {
        guard apiVersion >= 8 else { throw ECError.unavailable("静音指示灯需要 MSIECBridge 0.3.5") }
        let input: [UInt64] = [microphone ? 1 : 0, muted ? 1 : 0]
        var output: UInt64 = 0
        var count: UInt32 = 1
        let code = input.withUnsafeBufferPointer {
            IOConnectCallScalarMethod(connection, 9, $0.baseAddress, 2, &output, &count)
        }
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "同步静音指示灯", code: code) }
        guard count == 1, output == input[1] else { throw ECError.mismatch("静音指示灯读回不匹配") }
    }

    public func fanCounters() throws -> [UInt8] {
        guard apiVersion >= 7 else { throw ECError.unavailable("EC 测速需要 MSIECBridge 0.3.4，更新驱动并重启") }
        var output = [UInt64](repeating: 0, count: 4)
        var count: UInt32 = 4
        let code = output.withUnsafeMutableBufferPointer {
            IOConnectCallScalarMethod(connection, 8, nil, 0, $0.baseAddress, &count)
        }
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "读取 EC 风扇计数", code: code) }
        guard count == 4, output.allSatisfy({ $0 <= 255 }) else { throw ECError.invalid("EC 测速响应格式异常") }
        return output.map { UInt8($0) }
    }

    public func currentCoreFrequencyGHz() throws -> Double {
        guard apiVersion >= 6 else {
            throw ECError.unavailable("CPU 频率需要 MSIECBridge 0.3.3，更新驱动并重启后可读取")
        }
        var output: [UInt64] = [0, 0]
        var count: UInt32 = 2
        let code = output.withUnsafeMutableBufferPointer {
            IOConnectCallScalarMethod(connection, 7, nil, 0, $0.baseAddress, &count)
        }
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "读取采样核心频率", code: code) }
        guard count == 2, (100...10000).contains(output[0]),
              output[0] == ((output[1] >> 8) & 0xFF) * 100 else {
            throw ECError.invalid("CPU 频率响应格式异常")
        }
        return Double(output[0]) / 1000
    }

    public func firmware() throws -> String {
        var bytes = [UInt8](repeating: 0, count: ECChargePolicy.firmwareLength)
        var size = bytes.count
        let code = bytes.withUnsafeMutableBytes { buffer in
            IOConnectCallStructMethod(connection, 0, nil, 0, buffer.baseAddress, &size)
        }
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "读取 EC 固件标识", code: code) }
        guard size == ECChargePolicy.firmwareLength, let firmware = ECChargePolicy.firmware(from: bytes) else {
            throw ECError.invalid("EC 固件标识格式异常，保持只读")
        }
        return firmware
    }

    public func readByte(at address: UInt8) throws -> UInt8 {
        var input: UInt64 = UInt64(address)
        var output: UInt64 = 0
        var count: UInt32 = 1
        let code = IOConnectCallScalarMethod(connection, 1, &input, 1, &output, &count)
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "读取 EC \(String(format: "0x%02X", address))", code: code) }
        guard count == 1, let byte = UInt8(exactly: output) else { throw ECError.invalid("EC 返回值不是单字节") }
        return byte
    }

    /// Reads the Smart Battery-style capacity fields exposed by this MSI EC.
    /// This is intentionally read-only and returns nil when the capacity tuple is invalid.
    public func batteryReading() throws -> ECBatteryReading? {
        let design = UInt16(try readByte(at: 0x38)) | UInt16(try readByte(at: 0x39)) << 8
        let full = UInt16(try readByte(at: 0x44)) | UInt16(try readByte(at: 0x45)) << 8
        let remaining = UInt16(try readByte(at: 0x48)) | UInt16(try readByte(at: 0x49)) << 8
        let voltage = UInt16(try readByte(at: 0x4A)) | UInt16(try readByte(at: 0x4B)) << 8
        let currentRaw = UInt16(try readByte(at: 0x46)) | UInt16(try readByte(at: 0x47)) << 8
        guard design > 100, full > 100, remaining <= full else { return nil }
        let current = Int16(bitPattern: currentRaw)
        return ECBatteryReading(
            designCapacity: Int(design),
            fullChargeCapacity: Int(full),
            remainingCapacity: Int(remaining),
            voltageMillivolts: Int(voltage),
            currentMilliamps: Int(current)
        )
    }

    public func performanceBytes() throws -> (UInt8, UInt8) {
        guard try firmware() == "15P2EMS1.110" else { throw ECError.unavailable("当前固件不支持性能档读取") }
        return (try readByte(at: 0xD2), try readByte(at: 0xD4))
    }

    public func setPerformance(profile: Int, expectedShift: UInt8, expectedFan: UInt8) throws -> (UInt8, UInt8) {
        guard apiVersion >= 5, (0...2).contains(profile),
              ((expectedShift == 0xC1 && [0x0D, 0x1D].contains(expectedFan)) ||
               (expectedShift == 0xC4 && expectedFan == 0x0D)),
              try firmware() == "15P2EMS1.110" else { throw ECError.unavailable("性能切换需要 MSIECBridge 0.3.2 和本机固件") }
        let input: [UInt64] = [UInt64(profile), UInt64(expectedShift), UInt64(expectedFan)]
        var output: [UInt64] = [0, 0]
        var count: UInt32 = 2
        let result = input.withUnsafeBufferPointer { values in
            output.withUnsafeMutableBufferPointer { receipt in
                IOConnectCallScalarMethod(connection, 6, values.baseAddress, 3, receipt.baseAddress, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw ECError.system(operation: "切换性能档，可能部分生效；请重新读取", code: result) }
        let targetShift: UInt64 = profile == 2 ? 0xC4 : 0xC1
        let targetFan: UInt64 = profile == 0 ? 0x1D : 0x0D
        guard count == 2, output == [targetShift, targetFan] else {
            throw ECError.mismatch("性能档读回不匹配，可能部分生效；请重新读取")
        }
        return (UInt8(targetShift), UInt8(targetFan))
    }

    public func snapshot() throws -> ECBridgeSnapshot {
        let version = try firmware()
        // Unknown firmware can be diagnosed without reading a guessed charge register.
        let charge = ECChargePolicy.supports(version) && (version != "15P2EMS1.110" || apiVersion >= 4)
            ? try readByte(at: UInt8(ECChargePolicy.address)) : nil
        return ECBridgeSnapshot(apiVersion: apiVersion, driverVersion: driverVersion, firmware: version, chargeByte: charge)
    }

    public func setChargeLimit(_ percent: Int, expected: UInt8) throws -> ECWriteReceipt {
        guard ECChargePolicy.encode(percent) != nil, ECChargePolicy.validCurrent(expected) else {
            throw ECError.invalid("充电上限或预期 EC 值无效")
        }
        let firmware = try firmware()
        guard ECChargePolicy.supports(firmware) else { throw ECError.unavailable("当前固件 \(firmware) 尚未适配充电写入") }
        guard firmware != "15P2EMS1.110" || apiVersion >= 4 else { throw ECError.unavailable("本机充电控制需要 MSIECBridge 0.3.1") }
        let input: [UInt64] = [UInt64(percent), UInt64(expected)]
        var output: [UInt64] = [0, 0]
        var count: UInt32 = 2
        let code = input.withUnsafeBufferPointer { values in
            output.withUnsafeMutableBufferPointer { results in
                IOConnectCallScalarMethod(connection, 2, values.baseAddress, 2, results.baseAddress, &count)
            }
        }
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "写入并读回充电上限", code: code) }
        guard count == 2, let before = UInt8(exactly: output[0]), let after = UInt8(exactly: output[1]), before == expected else {
            throw ECError.mismatch("驱动返回的充电写入记录异常，请重新读取")
        }
        let receipt = ECWriteReceipt(firmware: firmware, percent: percent, before: before, after: after)
        guard receipt.isVerified else { throw ECError.mismatch("EC 读回值不匹配，未确认充电上限生效") }
        return receipt
    }

    public func setFanMode(_ mode: ECFanMode, expected: UInt8) throws -> ECFanModeReceipt {
        guard ECFanMode(rawValueByte: expected) != nil else { throw ECError.invalid("当前 D4 风扇模式无法确认") }
        let input: [UInt64] = [UInt64(mode.rawValueByte), UInt64(expected)]
        var output: [UInt64] = [0, 0]
        var count: UInt32 = 2
        let code = input.withUnsafeBufferPointer { values in
            output.withUnsafeMutableBufferPointer { results in
                IOConnectCallScalarMethod(connection, 3, values.baseAddress, 2, results.baseAddress, &count)
            }
        }
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "写入并读回风扇模式", code: code) }
        guard count == 2, let before = UInt8(exactly: output[0]), let after = UInt8(exactly: output[1]), before == expected else {
            throw ECError.mismatch("驱动返回的风扇模式记录异常，请重新读取")
        }
        let receipt = ECFanModeReceipt(mode: mode, before: before, after: after)
        guard receipt.isVerified else { throw ECError.mismatch("风扇模式读回值不匹配") }
        return receipt
    }

    public func fanCurve(fan: Int) throws -> ECFanCurve {
        guard fan == 0 || fan == 1, try firmware() == "15P2EMS1.110" else {
            throw ECError.unavailable("当前固件不支持自定义风扇曲线")
        }
        let temperature: UInt8 = fan == 0 ? 0x69 : 0x81
        let speed: UInt8 = fan == 0 ? 0x72 : 0x8A
        let curve = ECFanCurve(temperatures: try (0..<6).map { try readByte(at: temperature + UInt8($0)) },
                               speeds: try (0..<6).map { try readByte(at: speed + UInt8($0)) })
        guard curve.isValid else { throw ECError.invalid("EC 曲线节点不符合已验证范围，保持只读") }
        return curve
    }

    public func setFanCurve(fan: Int, expected: ECFanCurve, speeds: [UInt8], expectedMode: UInt8) throws -> ECFanCurveReceipt {
        guard apiVersion >= 3 else { throw ECError.unavailable("曲线控制需要 MSIECBridge 0.3.0，配置驱动并重启后再试") }
        guard fan == 0 || fan == 1, expected.isValid,
              ECFanCurve(temperatures: expected.temperatures, speeds: speeds).isValid,
              speeds.allSatisfy({ (20...150).contains($0) }),
              ECFanMode(rawValueByte: expectedMode) != nil else { throw ECError.invalid("曲线参数无效") }
        let request = [UInt8(fan)] + expected.temperatures + expected.speeds + speeds + [expectedMode]
        var output = [UInt8](repeating: 0, count: 7)
        var size = output.count
        let code = request.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { result in
                IOConnectCallStructMethod(connection, 5, input.baseAddress, input.count, result.baseAddress, &size)
            }
        }
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "写入风扇曲线，可能部分生效；请重新读取", code: code) }
        guard size == 7, Array(output.prefix(6)) == speeds, output[6] == ECFanMode.advanced.rawValueByte else {
            throw ECError.mismatch("曲线读回不匹配，可能部分生效；请重新读取")
        }
        return ECFanCurveReceipt(speeds: Array(output.prefix(6)), mode: output[6])
    }

    public func setCoolerBoost(_ enabled: Bool, expected: UInt8) throws -> ECCoolerBoostReceipt {
        guard apiVersion >= 3 else { throw ECError.unavailable("强冷需要 MSIECBridge 0.3.0，配置驱动并重启后再试") }
        let input: [UInt64] = [enabled ? 1 : 0, UInt64(expected)]
        var output: [UInt64] = [0, 0]
        var count: UInt32 = 2
        let code = input.withUnsafeBufferPointer { values in
            output.withUnsafeMutableBufferPointer { result in
                IOConnectCallScalarMethod(connection, 4, values.baseAddress, 2, result.baseAddress, &count)
            }
        }
        guard code == KERN_SUCCESS else { throw ECError.system(operation: "写入强冷并读回", code: code) }
        let target = (expected & 0x7F) | (enabled ? 0x80 : 0)
        guard count == 2, output[0] == expected, output[1] == target else { throw ECError.mismatch("强冷读回不匹配") }
        return ECCoolerBoostReceipt(before: expected, after: target)
    }
}
