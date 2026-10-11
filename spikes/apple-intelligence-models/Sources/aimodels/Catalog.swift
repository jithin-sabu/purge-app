import Foundation

/// How macOS downloads a set again: a subscription the spike sends on Download
/// again. Aliases and usages are what pared's catalog ships for macOS 27.
struct Recovery {
    let name: String
    let usageAliases: [String: String]
    let assetSetUsages: [String: [String: String]]
    /// Download-only dependencies that come with the set. Never removed or purged.
    let additionalAssetSets: [String]
}

/// One group of models macOS manages as an *asset set*.
struct ModelSet {
    /// The asset set name the subscription service works with.
    let name: String
    /// The MobileAsset type. Its folder under /System/Library/AssetsV2 is this
    /// with every dot replaced by an underscore.
    let assetType: String
    let title: String
    /// Features that stop working once the set is gone, for the confirmation.
    let consumers: [String]
    let recovery: Recovery?

    var folderName: String { assetType.replacingOccurrences(of: ".", with: "_") }
}

/// The asset sets behind Apple Intelligence. Names, types, consumers and
/// recovery mappings come from pared's catalog (github.com/4evy/pared, MIT),
/// checked on macOS 27 only. `aimodels check` confirms each mapping against
/// the running macOS before anything is sent.
enum Catalog {
    /// The subscriber name the spike's own download requests carry, so Download
    /// again can unsubscribe exactly those and nothing Apple or another app owns.
    static let subscriber = "io.getpurge.spike"

    static let foundation = "com.apple.modelcatalog"
    static let visual = "com.apple.MobileAsset.UAF.FM.Visual"
    static let code = "com.apple.MobileAsset.UAF.FM.CodeLM"
    static let cleanUp = "com.apple.MobileAsset.UAF.Photos.MagicCleanup"
    static let spatial = "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive"

    static let sets: [ModelSet] = [
        ModelSet(
            name: foundation,
            assetType: "com.apple.MobileAsset.UAF.FM.GenerativeModels",
            title: "Core Apple Intelligence models",
            consumers: [
                "Siri", "Writing Tools", "Genmoji", "Image Playground", "Mail summaries and smart replies",
                "Messages, Notes, Safari and notification summaries", "Visual Intelligence",
                "Calendar natural-language editing", "apps using the Foundation Models framework",
                "the Use Model action in Shortcuts",
            ],
            recovery: Recovery(
                name: "foundationModels",
                usageAliases: ["com.apple.Settings.AppleIntelligence": "language_en"],
                assetSetUsages: [:],
                additionalAssetSets: [
                    "com.apple.MobileAsset.UAF.FM.Overrides",
                    "com.apple.MobileAsset.UAF.Shortcuts.Generator",
                ])),
        ModelSet(
            name: visual,
            assetType: visual,
            title: "Image generation models",
            consumers: ["Genmoji", "Image Playground", "Visual Intelligence"],
            recovery: Recovery(
                name: "imageGeneration",
                usageAliases: [
                    "VisualGeneration.GenerativePlayground": "language_en",
                    "VisualGeneration.KeyboardEmojiGenerator": "language_en",
                ],
                assetSetUsages: [:],
                additionalAssetSets: ["com.apple.MobileAsset.UAF.FM.Overrides"])),
        ModelSet(
            name: code,
            assetType: code,
            title: "Code generation models",
            consumers: ["Xcode predictive code completion"],
            recovery: Recovery(
                name: "codeIntelligence",
                usageAliases: [:],
                assetSetUsages: [
                    code: [
                        "com.apple.fm.code.generate_small_v3.base.generic": "ENABLED",
                        "com.apple.fm.code.generate_small_v3.base.draft.generic": "ENABLED",
                        "com.apple.fm.code.generate_small_v3.tokenizer.generic": "ENABLED",
                        "com.apple.fm.code.generate_large_v3.base.generic": "ENABLED",
                        "com.apple.fm.code.generate_large_v3.base.draft.generic": "ENABLED",
                        "com.apple.fm.code.generate_large_v3.tokenizer.generic": "ENABLED",
                        "com.apple.fm.code.generate_safety_guardrail.base.generic": "ENABLED",
                        "com.apple.fm.code.generate_safety_guardrail.tokenizer.generic": "ENABLED",
                    ],
                ],
                additionalAssetSets: [])),
        ModelSet(
            name: cleanUp,
            assetType: cleanUp,
            title: "Photos Clean Up models",
            consumers: ["Clean Up in Photos"],
            recovery: Recovery(
                name: "photosCleanup",
                usageAliases: ["GenerativeEdit.CleanUp": "language_en"],
                assetSetUsages: [:],
                additionalAssetSets: [])),
        ModelSet(
            name: spatial,
            assetType: spatial,
            title: "Spatial Photos models",
            consumers: ["Spatial Photos"],
            recovery: Recovery(
                name: "spatialPhotos",
                usageAliases: ["spatialPhotos.relive.main": "default"],
                assetSetUsages: [:],
                additionalAssetSets: [])),
    ]

    static func set(named name: String) -> ModelSet? {
        sets.first { $0.name == name }
    }

    /// The sets a `--sets a,b` argument names, or every set. Unknown names are an error.
    static func select(_ argument: String?) throws -> [ModelSet] {
        guard let argument else { return sets }
        var selected: [ModelSet] = []
        for raw in argument.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard let set = set(named: name) else {
                throw Failure("unknown asset set \(name). Known sets: " + sets.map(\.name).joined(separator: ", "))
            }
            if !selected.contains(where: { $0.name == set.name }) { selected.append(set) }
        }
        guard !selected.isEmpty else { throw Failure("--sets named no asset set") }
        return selected
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
