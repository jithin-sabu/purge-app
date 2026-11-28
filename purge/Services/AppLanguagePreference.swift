import Combine
import Foundation

/// The language picked in Settings (#465): System default, or one of the
/// languages Purge ships.
enum AppLanguageChoice: Hashable {
    case system
    /// A localization folder name from the bundle, such as `ru` or `zh-Hans`.
    case language(String)
}

/// The Language row in Settings (#465).
///
/// It writes the same entry System Settings writes for Purge under Language &
/// Region > Applications: `AppleLanguages` in Purge's own preferences, holding
/// the one picked language. System default removes it, so Purge follows the
/// Mac again. Either place can change it, so `refresh()` reads it again
/// whenever Purge comes back to the front.
///
/// Text loads at launch, so a change shows after Purge relaunches. Right-to-left
/// languages mirror the layout only when the Mac's own language is right to
/// left. macOS does the same for every app, so Purge doesn't force it.
@MainActor
final class AppLanguagePreference: ObservableObject {
    static let shared = AppLanguagePreference(
        defaults: .standard,
        domainName: Bundle.main.bundleIdentifier ?? "io.getpurge.app",
        shipped: shippedLanguages(in: Bundle.main),
        launchLanguage: Bundle.main.preferredLocalizations.first ?? "en",
        systemLanguages: macLanguages
    )

    nonisolated static let defaultsKey = "AppleLanguages"

    @Published private(set) var choice: AppLanguageChoice = .system

    /// The languages Purge ships, in menu order.
    let shipped: [String]
    /// The language Purge's text loaded in at this launch.
    let launchLanguage: String

    private let defaults: UserDefaults
    private let domainName: String
    private let systemLanguages: () -> [String]

    init(
        defaults: UserDefaults,
        domainName: String,
        shipped: [String],
        launchLanguage: String,
        systemLanguages: @escaping () -> [String]
    ) {
        self.defaults = defaults
        self.domainName = domainName
        self.shipped = shipped
        self.launchLanguage = launchLanguage
        self.systemLanguages = systemLanguages
        refresh()
    }

    /// System default first, then each shipped language.
    var options: [AppLanguageChoice] {
        [.system] + shipped.map(AppLanguageChoice.language)
    }

    /// The language Purge would load at its next launch.
    var resolvedLanguage: String {
        switch choice {
        case .system:
            return Self.bestMatch(for: systemLanguages(), in: shipped)
        case .language(let language):
            return language
        }
    }

    /// True when the choice loads a different language from the one on screen.
    var needsRelaunch: Bool {
        resolvedLanguage != launchLanguage
    }

    /// Reads the saved entry, which System Settings may have changed.
    func refresh() {
        let saved = defaults.persistentDomain(forName: domainName)?[Self.defaultsKey] as? [String]
        let next = Self.choice(saved: saved, shipped: shipped)
        if next != choice { choice = next }
    }

    func select(_ newChoice: AppLanguageChoice) {
        switch newChoice {
        case .system:
            defaults.removeObject(forKey: Self.defaultsKey)
        case .language(let language):
            defaults.set([language], forKey: Self.defaultsKey)
        }
        refresh()
    }

    func label(for option: AppLanguageChoice) -> String {
        switch option {
        case .system:
            return String(localized: "System default")
        case .language(let language):
            return Self.nativeName(of: language)
        }
    }

    /// What the saved entry means. No entry is System default. A saved
    /// language Purge doesn't ship shows as the one macOS falls back to.
    nonisolated static func choice(saved: [String]?, shipped: [String]) -> AppLanguageChoice {
        guard let saved, !saved.isEmpty else { return .system }
        return .language(bestMatch(for: saved, in: shipped))
    }

    /// The shipped language macOS loads for `preferences`, as the bundle
    /// picks it. English when nothing matches, like the bundle itself.
    nonisolated static func bestMatch(for preferences: [String], in shipped: [String]) -> String {
        Bundle.preferredLocalizations(from: shipped, forPreferences: preferences).first ?? "en"
    }

    /// The bundle's localizations, without Base, sorted by code.
    nonisolated static func shippedLanguages(in bundle: Bundle) -> [String] {
        bundle.localizations.filter { $0 != "Base" }.sorted()
    }

    /// The language's name in that language, so it can be found while Purge
    /// shows another one. Starts with a capital, as a menu item does
    /// (CLDR writes "русский").
    nonisolated static func nativeName(of language: String) -> String {
        let locale = Locale(identifier: language)
        guard let name = locale.localizedString(forIdentifier: language), let first = name.first else {
            return language
        }
        return String(first).uppercased(with: locale) + name.dropFirst()
    }

    /// The Mac's own language list, without Purge's entry on top.
    nonisolated private static func macLanguages() -> [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[defaultsKey] as? [String]
            ?? ["en"]
    }
}
