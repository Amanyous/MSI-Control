import ECControl
import Foundation

// No shell commands, arbitrary register writes, installation, or background service.
do {
    let args = CommandLine.arguments
    guard getuid() == 0 else { throw ECError.unavailable("写入 EC 需要管理员授权") }
    guard args.count >= 4 else { throw ECError.invalid("EC 写入参数不足") }
    let connection = try ECBridgeConnection()
    let json: Data
    if args.count == 9, args[1] == "set-cpu-power", let mode = Int(args[2]),
       (0...5).contains(mode), let eco = UInt64(args[3]), eco <= 1,
       let generation = UInt64(args[4]), let package = UInt64(args[5]),
       let shift = UInt64(args[6]), let fan = UInt64(args[7]), args[8] == "v1" {
        let expected = try connection.powerControlStatus()
        guard expected.generation == generation, expected.current == package,
              expected.words[8] == shift, expected.words[9] == fan else {
            throw ECError.mismatch("授权期间功耗或 EC 状态已变化，未写入")
        }
        json = try JSONEncoder().encode(connection.setPowerPreset(
            CPUPowerPreset(rawValue: mode), eco: eco == 1, expected: expected))
    } else if args.count == 6, args[1] == "set-common", let featureID = UInt64(args[2]),
       let feature = ECCommonFeature(rawValue: featureID), let desired = UInt8(args[3]),
       let expected = UInt8(args[4]), try connection.firmware() == args[5] {
        json = try JSONEncoder().encode(connection.setCommonFeature(feature, desired: desired, expected: expected))
    } else if args.count == 4, args[1] == "set-charge-limit", let percent = Int(args[2]), ECChargePolicy.encode(percent) != nil, let expected = UInt8(args[3]), ECChargePolicy.validCurrent(expected) {
        json = try JSONEncoder().encode(connection.setChargeLimit(percent, expected: expected))
    } else if args.count == 5, args[1] == "set-performance", let profile = Int(args[2]),
              let expectedShift = UInt8(args[3]), let expectedFan = UInt8(args[4]) {
        let result = try connection.setPerformance(profile: profile, expectedShift: expectedShift, expectedFan: expectedFan)
        json = try JSONEncoder().encode([result.0, result.1])
    } else if args.count == 4, args[1] == "set-fan-mode", let expected = UInt8(args[3]), let mode = ["auto": ECFanMode.automatic, "advanced": .advanced][args[2]] {
        json = try JSONEncoder().encode(connection.setFanMode(mode, expected: expected))
    } else if args.count == 4, args[1] == "set-cooler-boost", let expected = UInt8(args[3]), ["on", "off"].contains(args[2]) {
        guard let profile = ECFeatureProfile.match(try connection.firmware()),
              try connection.readByte(at: profile.fanAddress) == ECFanMode.advanced.rawValueByte else {
            throw ECError.unavailable("请先应用手动模式")
        }
        json = try JSONEncoder().encode(connection.setCoolerBoost(args[2] == "on", expected: expected))
    } else if args.count == 7, args[1] == "set-fan-curve", let fan = Int(args[2]),
              let expectedMode = UInt8(args[3]) {
        let expectedTemperatures = args[4].split(separator: ",").compactMap { UInt8($0) }
        let expectedSpeeds = args[5].split(separator: ",").compactMap { UInt8($0) }
        let speeds = args[6].split(separator: ",").compactMap { UInt8($0) }
        guard expectedMode == ECFanMode.advanced.rawValueByte,
              try connection.readByte(at: 0xD4) == expectedMode,
              expectedTemperatures.count == 6, expectedSpeeds.count == 6, speeds.count == 6 else {
            throw ECError.invalid("曲线必须包含六个有效节点")
        }
        let curve = try connection.fanCurve(fan: fan)
        guard curve.temperatures == expectedTemperatures, curve.speeds == expectedSpeeds else {
            throw ECError.mismatch("授权期间曲线已变化，请重新读取")
        }
        json = try JSONEncoder().encode(connection.setFanCurve(fan: fan, expected: curve, speeds: speeds, expectedMode: expectedMode))
    } else {
        throw ECError.invalid("参数无效；风扇模式只支持 auto、silent、advanced")
    }
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
