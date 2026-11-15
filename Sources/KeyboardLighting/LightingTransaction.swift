import Foundation

public struct LightingDevice: Codable, Sendable, Identifiable {
    public let id: UInt64
    public let vendorID: Int
    public let productID: Int
    public let name: String
    public let manufacturer: String
    public let transport: String
    public let usagePage: Int
    public let usage: Int
    public let maximumFeatureBytes: Int
    public let featureReports: [Int: Int]?
    public let descriptorHex: String?

    public var supportsTrial: Bool {
        vendorID == MysticLightProtocol.vendorID &&
        productID == MysticLightProtocol.productID &&
        featureReports?[MysticLightProtocol.reportID] == MysticLightProtocol.reportLength
    }

    public var identifier: String { String(format: "%04X:%04X", vendorID, productID) }
    public var compatibility: String {
        if supportsTrial { return "匹配实验性 24 区协议；实际效果待确认" }
        if vendorID != MysticLightProtocol.vendorID || productID != MysticLightProtocol.productID {
            return "此硬件编号尚未适配"
        }
        return "Feature Report 2 不是已知的 64 字节格式，不能发送"
    }
}

public struct LightingScan: Codable, Sendable {
    public let devices: [LightingDevice]
    public let error: String?

    public var candidates: [LightingDevice] { devices.filter(\.supportsTrial) }
    public var status: String {
        if let error { return error }
        if candidates.count == 1 { return "已匹配 1 个实验性灯控接口" }
        if candidates.count > 1 { return "发现多个匹配接口；请导出诊断以确认目标" }
        return devices.isEmpty ? "未发现 MSI / SteelSeries HID 接口" : "发现设备，但没有匹配的 24 区灯控接口"
    }
}

public struct HIDTrace: Codable, Sendable {
    public let operation: String
    public let returnCode: String
    public let bytes: String?
}

public struct LightingResult: Codable, Sendable {
    public let action: String
    public let reportsSent: Int
    public let allReportsSent: Bool
    public let message: String
    public let trace: [HIDTrace]
}

public struct LightingReport: Codable, Sendable {
    public let createdAt: Date
    public let scan: LightingScan
    public let result: LightingResult?

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

protocol LightingTransport {
    func open() -> Int32
    func close()
    func send(_ bytes: [UInt8]) -> Int32
    func readReply() -> (code: Int32, bytes: [UInt8])
}

enum LightingTransaction {
    static func perform(_ action: LightingAction, device: LightingDevice, transport: any LightingTransport) -> LightingResult {
        guard device.supportsTrial else {
            return rejected(action, message: "接口与已知协议不匹配，未发送任何报文")
        }
        guard action.isValid else { return rejected(action, message: "区域颜色与前帧颜色数量必须为 24，未发送任何报文") }
        let reports = MysticLightProtocol.reports(for: action)
        if reports.isEmpty {
            return LightingResult(action: action.title, reportsSent: 0, allReportsSent: true,
                                  message: "颜色没有变化，无需重复发送", trace: [])
        }
        var trace: [HIDTrace] = []
        let openCode = transport.open()
        trace.append(HIDTrace(operation: "open (non-exclusive)", returnCode: hexCode(openCode), bytes: nil))
        guard openCode == 0 else {
            return LightingResult(action: action.title, reportsSent: 0, allReportsSent: false,
                                  message: "打开灯控接口失败（\(hexCode(openCode))）；请导出诊断", trace: trace)
        }
        defer { transport.close() }
        var sent = 0
        for report in reports {
            let writeCode = transport.send(report)
            trace.append(HIDTrace(operation: "set feature report 2", returnCode: hexCode(writeCode), bytes: hexBytes(report)))
            guard writeCode == 0 else {
                return LightingResult(action: action.title, reportsSent: sent, allReportsSent: false,
                                      message: "发送失败（\(hexCode(writeCode))，已发送 \(sent) 个报文）；请导出诊断", trace: trace)
            }
            sent += 1
            // Keep the initial diagnostic handshake. Subsequent stream frames
            // follow MSI-KeyLight's observed 1603 Set_Report-only write path.
            // This optional reply is not a physical lighting state readback.
            if !action.isIncrementalFrame && device.featureReports?[1] == 64 {
                let reply = transport.readReply()
                trace.append(HIDTrace(operation: "get feature report 1 (optional reply)",
                                      returnCode: hexCode(reply.code), bytes: hexBytes(reply.bytes)))
            }
        }
        return LightingResult(action: action.title, reportsSent: sent, allReportsSent: true,
                              message: "\(action.title)报文已发送；请观察目标机键盘确认效果", trace: trace)
    }

    static func rejected(_ action: LightingAction, message: String) -> LightingResult {
        LightingResult(action: action.title, reportsSent: 0, allReportsSent: false, message: message, trace: [])
    }

    static func hexCode(_ value: Int32) -> String { String(format: "0x%08X", UInt32(bitPattern: value)) }
    static func hexBytes(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
