import Foundation

public enum LightingAction: Sendable {
    case turnOff
    case solid(red: UInt8, green: UInt8, blue: UInt8)
    case frame(colors: [LightingRGB], previous: [LightingRGB]? = nil)
    case loadSaved

    public var title: String {
        switch self {
        case .turnOff: "关灯（24 区设为黑色）"
        case .solid: "设置 24 区纯色"
        case .frame: "设置 24 区颜色"
        case .loadSaved: "载入键盘已保存灯效"
        }
    }

    var isValid: Bool {
        guard case let .frame(colors, previous) = self else { return true }
        return colors.count == LightingConfiguration.zoneCount &&
            (previous == nil || previous?.count == LightingConfiguration.zoneCount)
    }

    var isIncrementalFrame: Bool {
        if case let .frame(_, previous) = self { return previous != nil }
        return false
    }
}

enum MysticLightProtocol {
    static let vendorID = 0x1462
    static let productID = 0x1603
    static let reportID = 2
    static let reportLength = 64

    // Protocol facts from MSI-KeyLight's 1462:1603 MSI Center captures.
    // 0xB0 is documented by natanalt and msi-crosshair-16-rgb.
    // See outputs/键盘灯说明.md for pinned research revisions.
    static func reports(for action: LightingAction) -> [[UInt8]] {
        switch action {
        case .loadSaved:
            return [padded([0x02, 0xB0])]
        case .turnOff:
            return colorReports(red: 0, green: 0, blue: 0)
        case let .solid(red, green, blue):
            return colorReports(red: red, green: green, blue: blue)
        case let .frame(colors, previous):
            guard action.isValid else { return [] }
            var groups: [(color: LightingRGB, mask: UInt32)] = []
            for (zone, color) in colors.enumerated() {
                if previous?[zone] == color { continue }
                if let index = groups.firstIndex(where: { $0.color == color }) { groups[index].mask |= 1 << zone }
                else { groups.append((color, 1 << zone)) }
            }
            return groups.flatMap { colorReports(red: $0.color.red, green: $0.color.green, blue: $0.color.blue, mask: $0.mask) }
        }
    }

    private static func colorReports(red: UInt8, green: UInt8, blue: UInt8, mask: UInt32 = 0x00FF_FFFF) -> [[UInt8]] {
        // Select exactly 24 zones; a one-byte mask only reaches the first 8.
        let zones = padded([0x02, 0x01, UInt8(truncatingIfNeeded: mask), UInt8(truncatingIfNeeded: mask >> 8), UInt8(truncatingIfNeeded: mask >> 16), 0])
        // Steady effect, 600 timing units, two identical color keyframes.
        // The 0x64 byte is the final keyframe time, NOT hardware brightness.
        let color = padded([
            0x02, 0x02, 0x01, 0x58, 0x02, 0x00, 0x32, 0x08, 0x01, 0x01,
            0x00, red, green, blue, 0x64, red, green, blue
        ])
        return [zones, color]
    }

    private static func padded(_ bytes: [UInt8]) -> [UInt8] {
        bytes + Array(repeating: 0, count: reportLength - bytes.count)
    }
}

// Compute each Feature Report's wire length from its HID descriptor, including
// the nonzero Report ID. Unknown or malformed layouts cannot authorize writes.
enum HIDFeatureLayout {
    private struct Globals {
        var size = 0
        var count = 0
        var reportID = 0
    }

    static func parse(_ descriptor: Data) -> [Int: Int]? {
        let bytes = [UInt8](descriptor)
        guard !bytes.isEmpty else { return nil }
        var offset = 0
        var globals = Globals()
        var stack: [Globals] = []
        var featureBits: [Int: Int] = [:]
        var collections = 0
        while offset < bytes.count {
            let prefix = bytes[offset]
            offset += 1
            guard prefix != 0xFE else { return nil } // unsupported long item
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard offset + size <= bytes.count else { return nil }
            var value = 0
            for index in 0..<size { value |= Int(bytes[offset + index]) << (index * 8) }
            offset += size
            let type = (prefix >> 2) & 3
            let tag = prefix >> 4
            if type == 1 {
                switch tag {
                case 7:
                    guard value <= 64 else { return nil }
                    globals.size = value
                case 8:
                    guard (1...255).contains(value) else { return nil }
                    globals.reportID = value
                case 9:
                    guard value <= 65_536 else { return nil }
                    globals.count = value
                case 10:
                    guard stack.count < 32 else { return nil }
                    stack.append(globals)
                case 11:
                    guard let previous = stack.popLast() else { return nil }
                    globals = previous
                default: break
                }
            } else if type == 0 {
                switch tag {
                case 10: collections += 1
                case 12:
                    guard collections > 0 else { return nil }
                    collections -= 1
                case 11:
                    guard collections > 0, globals.size > 0, globals.count > 0 else { return nil }
                    let total = featureBits[globals.reportID, default: 0] + globals.size * globals.count
                    guard total <= 524_288 else { return nil }
                    featureBits[globals.reportID] = total
                default: break
                }
            }
        }
        guard collections == 0, stack.isEmpty else { return nil }
        return featureBits.mapValues { ($0 + 7) / 8 }.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value + (entry.key == 0 ? 0 : 1)
        }
    }
}
