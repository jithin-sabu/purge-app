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

    /// macOS defines `language_zh`, `language_zh_HK` and `language_zh_TW` for
    /// the Settings alias, but only `language_en` and `language_zh` for Photos
    /// Clean Up, so each alias is resolved against its own values.
    @Test func theValueIsTheMostSpecificOneTheAliasDefines() {
        let settings: Set<String> = ["default", "language_en", "language_zh", "language_zh_HK", "language_zh_TW", "language_pt"]
        let cleanUp: Set<String> = ["language_en", "language_zh"]
        let defined: (String) -> Set<String> = { $0 == "GenerativeEdit.CleanUp" ? cleanUp : settings }

        #expect(Language.value(for: "settings", siriLanguage: "zh-TW", definedValues: defined) == "language_zh_TW")
        #expect(Language.value(for: "settings", siriLanguage: "zh-CN", definedValues: defined) == "language_zh")
        #expect(Language.value(for: "settings", siriLanguage: "pt-BR", definedValues: defined) == "language_pt")
        #expect(Language.value(for: "settings", siriLanguage: "en-GB", definedValues: defined) == "language_en")
        #expect(Language.value(for: "GenerativeEdit.CleanUp", siriLanguage: "zh-TW", definedValues: defined) == "language_zh")
        // A language the alias has nothing for, and no language at all: English, as before.
        #expect(Language.value(for: "GenerativeEdit.CleanUp", siriLanguage: "fr-FR", definedValues: defined) == "language_en")
        #expect(Language.value(for: "settings", siriLanguage: nil, definedValues: defined) == "language_en")
        #expect(Language.value(for: "settings", siriLanguage: "fr-FR", definedValues: { _ in [] }) == "language_en")
    }

    @Test func theCatalogResolvesItsLanguageAliasesAndKeepsTheFixedOnes() throws {
        let core = try #require(AppleIntelligenceCatalog.sets.first { $0.recovery.name == "foundationModels" })
        #expect(core.recovery.resolvedUsageAliases { _ in "language_fr" }
            == ["com.apple.Settings.AppleIntelligence": "language_fr"])
        let spatial = try #require(AppleIntelligenceCatalog.sets.first { $0.recovery.name == "spatialPhotos" })
        #expect(spatial.recovery.resolvedUsageAliases { _ in "language_fr" } == ["spatialPhotos.relive.main": "default"])
        let code = try #require(AppleIntelligenceCatalog.sets.first { $0.recovery.name == "codeIntelligence" })
        #expect(code.recovery.resolvedUsageAliases { _ in "language_fr" }.isEmpty)
    }

    /// The values come from the plist names in the alias's folder.
    @Test func definedValuesAreReadFromTheAliasFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ai-aliases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("Some.Alias")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        for name in ["language_en.plist", "language_zh.plist", "notes.txt"] {
            try Data().write(to: alias.appendingPathComponent(name))
        }
        #expect(Language.defined(for: "Some.Alias", directory: root.path) == ["language_en", "language_zh"])
        #expect(Language.defined(for: "Other.Alias", directory: root.path).isEmpty)
    }

    /// On macOS 27, the one version the feature runs on, every language alias
    /// in the catalog has English and at least one other language, so the
    /// catalog's aliases are ones macOS resolves by language. The macOS 26
    /// runner on CI ships different folders, so it is not checked there.
    @Test(.enabled(if: AppleIntelligenceModelStore.isSupported
        && FileManager.default.fileExists(atPath: AppleIntelligenceAliasLanguage.usageAliasesDirectory)))
    func thisMacDefinesEveryLanguageAliasInTheCatalog() {
        for set in AppleIntelligenceCatalog.sets {
            for (alias, value) in set.recovery.usageAliases where value == .language {
                let defined = Language.defined(for: alias)
                #expect(defined.contains("language_en"), "\(alias)")
                #expect(defined.contains { $0.hasPrefix("language_") && $0 != "language_en" }, "\(alias)")
            }
        }
    }
}
