import Foundation
import Observation

/// The language Spectre shows, chosen in Settings › General
/// (docs/localization.md).
///
/// The choice is the app's own `AppleLanguages`, which System Settings ›
/// Language & Region › Applications also sets, so both show the same. A
/// change applies to Spectre's windows at once, through the `locale` in
/// their environment; what the system draws (its menu items, panels) and
/// text made before the change keep the old language until the next launch.
@MainActor @Observable
final class AppLanguage {
    /// The languages the app has, by their identifiers ("en", "zh-Hans").
    static let available: [String] = Bundle.main.localizations.filter { $0 != "Base" }

    /// As Settings lists them: by their names.
    static let byName = available.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }

    /// The language chosen for Spectre; nil follows the system's.
    private(set) var chosen: String?
    /// The language the app started in, which the system's parts still show.
    let launched: String

    init() {
        chosen = Self.appLanguages.flatMap(Self.match)
        launched = Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// The language Spectre's windows show now.
    var current: String { chosen ?? Self.systemLanguage }

    /// The user's own locale (region, calendar, number formats) in the
    /// shown language.
    var locale: Locale {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: current)
        return Locale(components: components)
    }

    /// Some of the app keeps the language it started in until it starts again.
    var needsRelaunch: Bool { current != launched }

    func choose(_ language: String?) {
        chosen = language
        let defaults = UserDefaults.standard
        if let language {
            defaults.set([language], forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }

    /// A language's name in itself: "日本語", "Español".
    static func name(_ language: String) -> String {
        let locale = Locale(identifier: language)
        let name = locale.localizedString(forIdentifier: language) ?? language
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    private static let key = "AppleLanguages"

    /// The app's own setting (or `-AppleLanguages` at launch), not the
    /// system's list it falls back to.
    private static var appLanguages: [String]? {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return (arguments[key] ?? defaults.persistentDomain(forName: id)?[key]) as? [String]
    }

    /// The system's languages, whatever the app's own setting.
    private static var systemLanguage: String {
        let preferred = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,
                                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return match(preferred ?? Locale.preferredLanguages) ?? "en"
    }

    /// The app's language for a list like ["ja-JP", "en"].
    private static func match(_ preferences: [String]) -> String? {
        Bundle.preferredLocalizations(from: available, forPreferences: preferences).first
    }
}
