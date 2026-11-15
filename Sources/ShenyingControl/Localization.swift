import Combine
import ECControl
import Foundation
import KeyboardLighting

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .system: t("language_system")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
}

@MainActor
final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }
    var resolvedLanguage: AppLanguage {
        guard language == .system else { return language }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .chinese : .english
    }
    var locale: Locale { Locale(identifier: resolvedLanguage.rawValue) }

    private var languageBundle: Bundle {
        let resourceBundle = Bundle.module
        guard let path = resourceBundle.path(forResource: resolvedLanguage.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resourceBundle }
        return bundle
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "appLanguage"), let value = AppLanguage(rawValue: raw) {
            language = value
        } else {
            language = .system
        }
    }

    func text(_ key: String) -> String {
        let semanticKey = LegacyLocalizationKeys.aliases[key] ?? key
        return languageBundle.localizedString(forKey: semanticKey, value: key, table: "Localizable")
    }

    func display(_ text: String) -> String {
        guard resolvedLanguage == .english else { return text }
        if LegacyLocalizationKeys.aliases[text] != nil { return self.text(text) }
        var result = text
        for chinese in LegacyLocalizationKeys.aliases.keys.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: chinese, with: self.text(chinese))
        }
        return result
    }


}

@MainActor
func t(_ key: String) -> String { AppLocalization.shared.text(key) }

@MainActor
func translated(_ text: String) -> String { AppLocalization.shared.display(text) }

@MainActor
func effectTitle(_ effect: LightingEffect) -> String {
    if AppLocalization.shared.resolvedLanguage == .chinese { return effect.title }
    switch effect {
    case .off: return "Off"
    case .solid: return "Solid"
    case .rainbow: return "Rainbow"
    case .breathing: return "Breathing"
    case .colorCycle: return "Color cycle"
    case .wave: return "Wave"
    case .ripple: return "Ripple"
    case .roulette: return "Color wheel"
    }
}

@MainActor
func fanModeTitle(_ mode: ECFanMode) -> String {
    if AppLocalization.shared.resolvedLanguage == .chinese { return mode.rawValue }
    switch mode { case .automatic: return "Auto"; case .silent: return "Silent"; case .advanced: return "Advanced" }
}

@MainActor
func effectDetail(_ effect: LightingEffect) -> String {
    if AppLocalization.shared.resolvedLanguage == .chinese { return effect.detail }
    switch effect {
    case .off: return "Turn off backlight for all zones."
    case .solid: return "Use one color for all zones, with optional per-zone colors."
    case .rainbow: return "A full spectrum flows continuously across all 24 logical zones."
    case .breathing: return "The selected colors smoothly fade down and back up."
    case .colorCycle: return "All zones synchronously cycle through the color spectrum."
    case .wave: return "A brightness wave moves through the logical zones using the selected colors."
    case .ripple: return "A pulse spreads from the center zones toward both sides."
    case .roulette: return "A colored band chases around the logical zones."
    }
}

@MainActor
func localized(_ key: String, _ arguments: CVarArg...) -> String {
    let format = t(key)
    return String(format: format, locale: AppLocalization.shared.locale, arguments: arguments)
}
