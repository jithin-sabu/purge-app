import Foundation

/// The language a usage alias is asked for when Download Again subscribes to
/// a set (#179). pared's catalog ships `language_en` for every alias, which on
/// a Mac set to another language asks for the English models. System Settings
/// subscribes each alias as `language_<code>` for the Siri language, which is
/// also Apple Intelligence's: the two share one Language setting. Purge does
/// the same, and falls back to English for a language the alias does not
/// define, which is what it sent before and keeps the models usable.
///
/// Purge only lists the values to try. The worker keeps the first one macOS
/// knows for each alias and leaves out an alias macOS no longer knows (#385):
/// the alias folders on disk are not the whole answer, since macOS also
/// accepts the values a release moved to `UsageAliases/Deprecated`, and 27.2
/// removed `VisualGeneration.GenerativePlayground` altogether.
nonisolated enum AppleIntelligenceAliasLanguage {
    static let english = "language_en"
    /// What an alias that has no language value is asked for, such as
    /// `spatialPhotos.relive.main`. Tried last, after English.
    static let defaultValue = "default"

    /// Siri's language as System Settings stores it, such as `en-US`, `pt-BR`
    /// or `zh-TW`. Nil when it has never been set.
    static func siriLanguage() -> String? {
        CFPreferencesCopyAppValue("Session Language" as CFString, "com.apple.assistant.backedup" as CFString) as? String
    }

    /// The values to try for a Siri language, most specific first: `zh-TW`
    /// gives `language_zh_TW` then `language_zh`, and `pt-BR` gives
    /// `language_pt_BR` then `language_pt`.
    static func candidates(for siriLanguage: String) -> [String] {
        let locale = Locale(identifier: siriLanguage)
        guard let code = locale.language.languageCode?.identifier, !code.isEmpty else { return [] }
        var values: [String] = []
        if let region = locale.region?.identifier, !region.isEmpty {
            values.append("language_\(code)_\(region)")
        }
        values.append("language_\(code)")
        return values
    }

    /// Every value a language alias is tried with, in order: the Siri
    /// language's own values, then English, then `default`. The
    /// `_useDefault_false` and 27.2's `isIFPEnabled_` values are never sent:
    /// what they change is not known, and the plain ones still work.
    static func values(siriLanguage: String?) -> [String] {
        var values: [String] = []
        for value in (siriLanguage.map(candidates(for:)) ?? []) + [english, defaultValue]
        where !values.contains(value) {
            values.append(value)
        }
        return values
    }
}
