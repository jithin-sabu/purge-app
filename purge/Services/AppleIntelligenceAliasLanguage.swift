import Foundation

/// The language a usage alias is asked for when Download Again subscribes to
/// a set (#179). pared's catalog ships `language_en` for every alias, which on
/// a Mac set to another language asks for the English models. System Settings
/// subscribes each alias as `language_<code>` for the Siri language, which is
/// also Apple Intelligence's: the two share one Language setting. Purge does
/// the same, and falls back to English for a language the alias does not
/// define, which is what it sent before and keeps the models usable.
nonisolated enum AppleIntelligenceAliasLanguage {
    /// One folder per alias, one plist per value it accepts.
    static let usageAliasesDirectory = "/System/Library/UnifiedAssetFramework/UsageAliases"
    static let english = "language_en"

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

    /// The first candidate `alias` defines on this Mac, else English.
    static func value(
        for alias: String,
        siriLanguage: String?,
        definedValues: (String) -> Set<String> = { defined(for: $0) }
    ) -> String {
        guard let siriLanguage else { return english }
        let defined = definedValues(alias)
        return candidates(for: siriLanguage).first { defined.contains($0) } ?? english
    }

    /// The values macOS ships for `alias`: the plist names in its folder.
    /// Empty when the folder is missing or unreadable, which falls back to English.
    static func defined(for alias: String, directory: String = usageAliasesDirectory) -> Set<String> {
        let folder = (directory as NSString).appendingPathComponent(alias)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return Set(names.filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(".plist".count)) })
    }
}
