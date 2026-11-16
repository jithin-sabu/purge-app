import Foundation
import Testing
@testable import Purge

@Suite("Download Again asks for the models in the Mac's language")
struct AppleIntelligenceAliasLanguageTests {
    private typealias Language = AppleIntelligenceAliasLanguage

    @Test func aSiriLanguageTriesItsRegionFirst() {
        #expect(Language.candidates(for: "en-US") == ["language_en_US", "language_en"])
        #expect(Language.candidates(for: "zh-TW") == ["language_zh_TW", "language_zh"])
        #expect(Language.candidates(for: "pt-BR") == ["language_pt_BR", "language_pt"])
        #expect(Language.candidates(for: "fr") == ["language_fr"])
        #expect(Language.candidates(for: "") == [])
    }

    /// The Siri language's own values come first, then English, then
    /// `default`, each once. The worker keeps the first one macOS knows for
    /// the alias, so Photos Clean Up, which has only `language_en` and
    /// `language_zh`, gets `language_zh` on a zh-TW Mac (#179).
    @Test func languageAliasesTryTheSiriLanguageThenEnglishThenDefault() {
        #expect(Language.values(siriLanguage: "zh-TW") == ["language_zh_TW", "language_zh", "language_en", "default"])
        #expect(Language.values(siriLanguage: "pt-BR") == ["language_pt_BR", "language_pt", "language_en", "default"])
        #expect(Language.values(siriLanguage: "en-GB") == ["language_en_GB", "language_en", "default"])
        #expect(Language.values(siriLanguage: "en") == ["language_en", "default"])
        #expect(Language.values(siriLanguage: nil) == ["language_en", "default"])
        #expect(Language.values(siriLanguage: "") == ["language_en", "default"])
    }

    @Test func theCatalogListsCandidatesForItsLanguageAliasesAndKeepsTheFixedOnes() throws {
        let values = ["language_fr_FR", "language_fr", "language_en", "default"]
        let core = try #require(AppleIntelligenceCatalog.sets.first { $0.recovery.name == "foundationModels" })
        #expect(core.recovery.usageAliasCandidates(languageValues: values)
            == ["com.apple.Settings.AppleIntelligence": values])
        let image = try #require(AppleIntelligenceCatalog.sets.first { $0.recovery.name == "imageGeneration" })
        #expect(image.recovery.usageAliasCandidates(languageValues: values) == [
            "VisualGeneration.GenerativePlayground": values,
            "VisualGeneration.KeyboardEmojiGenerator": values,
        ])
        let spatial = try #require(AppleIntelligenceCatalog.sets.first { $0.recovery.name == "spatialPhotos" })
        #expect(spatial.recovery.usageAliasCandidates(languageValues: values) == ["spatialPhotos.relive.main": ["default"]])
        let code = try #require(AppleIntelligenceCatalog.sets.first { $0.recovery.name == "codeIntelligence" })
        #expect(code.recovery.usageAliasCandidates(languageValues: values).isEmpty)
    }
}
