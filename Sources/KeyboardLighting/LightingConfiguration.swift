import Foundation

public enum LightingEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, solid, rainbow, breathing, colorCycle, wave, ripple, roulette

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: "关闭"
        case .solid: "纯色模式"
        case .rainbow: "彩虹"
        case .breathing: "呼吸"
        case .colorCycle: "色彩循环"
        case .wave: "波浪"
        case .ripple: "舞动"
        case .roulette: "色轮"
        }
    }
    public var isAnimated: Bool { self != .off && self != .solid }
    public var usesSelectedColors: Bool { [.solid, .breathing, .wave, .ripple].contains(self) }
    public var detail: String {
        switch self {
        case .off: "关闭全部区域的背光。"
        case .solid: "全部区域使用同一颜色，也可展开分区配色。"
        case .rainbow: "完整光谱沿 24 个逻辑区域连续流动，自动配色。"
        case .breathing: "使用所选颜色，平滑地由亮到暗再亮起。"
        case .colorCycle: "全部区域同步循环红、绿、蓝等光谱颜色，自动配色。"
        case .wave: "使用所选颜色，明暗波沿逻辑区域依次移动。"
        case .ripple: "使用所选颜色，从中间逻辑区域向两侧扩散律动，无需按键或音频输入。"
        case .roulette: "彩色光带沿逻辑区域循环追逐，自动配色。"
        }
    }
}

public struct LightingRGB: Codable, Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = LightingRGB(red: 0, green: 0, blue: 0)
    public static let defaultColor = LightingRGB(red: 219, green: 51, blue: 20)

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8((value >> 16) & 255), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
    }

    public static func spectrum(at hue: Double) -> LightingRGB {
        LightingRGB(red: 255, green: 0, blue: 0).rotatingHue(by: hue.isFinite ? hue : 0)
    }

    public func scaled(by factor: Double) -> LightingRGB {
        let factor = factor.isFinite ? min(1, max(0, factor)) : 0
        func channel(_ value: UInt8) -> UInt8 { UInt8((Double(value) * factor).rounded()) }
        return LightingRGB(red: channel(red), green: channel(green), blue: channel(blue))
    }

    func rotatingHue(by offset: Double) -> LightingRGB {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maximum = max(r, g, b), minimum = min(r, g, b), delta = maximum - minimum
        guard delta > 0 else { return self }
        var hue: Double
        if maximum == r { hue = (g - b) / delta }
        else if maximum == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        hue = ((hue / 6 + offset).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let sector = hue * 6
        let x = delta * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let values: (Double, Double, Double)
        switch Int(sector) {
        case 0: values = (delta, x, 0)
        case 1: values = (x, delta, 0)
        case 2: values = (0, delta, x)
        case 3: values = (0, x, delta)
        case 4: values = (x, 0, delta)
        default: values = (delta, 0, x)
        }
        func channel(_ value: Double) -> UInt8 { UInt8(min(255, max(0, ((value + minimum) * 255).rounded()))) }
        return LightingRGB(red: channel(values.0), green: channel(values.1), blue: channel(values.2))
    }
}

public struct LightingConfiguration: Codable, Equatable, Sendable {
    public static let zoneCount = 24
    public static let periodRange = 0.5...12.0
    public var effect: LightingEffect = .solid
    public var colors: [LightingRGB] = Array(repeating: .defaultColor, count: zoneCount)
    public var brightness = 4
    public var period = 2.0

    public init() {}

    public var isValid: Bool {
        colors.count == Self.zoneCount &&
        (0...4).contains(brightness) && period.isFinite && Self.periodRange.contains(period)
    }

    public mutating func setColor(_ color: LightingRGB, zone: Int?) {
        guard colors.count == Self.zoneCount else { return }
        if let zone {
            guard colors.indices.contains(zone) else { return }
            colors[zone] = color
        } else { colors = Array(repeating: color, count: Self.zoneCount) }
    }

    public func frame(at elapsed: Double) -> [LightingRGB] {
        guard isValid else { return [] }
        guard effect != .off else { return Array(repeating: .black, count: Self.zoneCount) }
        let elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let phase = elapsed.truncatingRemainder(dividingBy: period) / period
        let brightnessScale = Double(brightness) / 4
        switch effect {
        case .off:
            return Array(repeating: .black, count: Self.zoneCount)
        case .solid:
            return colors.map { $0.scaled(by: brightnessScale) }
        case .rainbow:
            return (0..<Self.zoneCount).map { zone in
                LightingRGB.spectrum(at: Double(zone) / Double(Self.zoneCount) - phase).scaled(by: brightnessScale)
            }
        case .breathing:
            let envelope = (cos(min(phase, 1 - phase) * 2 * .pi) + 1) / 2
            return colors.map { $0.scaled(by: brightnessScale * envelope) }
        case .colorCycle:
            return Array(repeating: LightingRGB.spectrum(at: phase).scaled(by: brightnessScale), count: Self.zoneCount)
        case .wave:
            return colors.enumerated().map { zone, color in
                let position = Double(zone) / Double(Self.zoneCount)
                let envelope = pow((cos((position - phase) * 2 * .pi) + 1) / 2, 2)
                return color.scaled(by: brightnessScale * envelope)
            }
        case .ripple:
            return colors.enumerated().map { zone, color in
                let distance = abs(2 * Double(zone) / Double(Self.zoneCount - 1) - 1)
                let envelope = pow((cos((phase - distance * 0.45) * 2 * .pi) + 1) / 2, 3)
                return color.scaled(by: brightnessScale * envelope)
            }
        case .roulette:
            let color = LightingRGB.spectrum(at: phase)
            return (0..<Self.zoneCount).map { zone in
                let distance = (phase - Double(zone) / Double(Self.zoneCount) + 1).truncatingRemainder(dividingBy: 1)
                return color.scaled(by: brightnessScale * max(0, 1 - distance * 3))
            }
        }
    }

    public static func restore(from data: Data?) -> LightingConfiguration {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return Self() }
        return value
    }
}
