import Foundation

/// How macOS downloads a set again: the subscription Download again sends.
/// Aliases and usages are what pared's catalog ships for macOS 27.
nonisolated struct AppleIntelligenceRecovery: Equatable, Sendable {
    let name: String
    let usageAliases: [String: String]
    let assetSetUsages: [String: [String: String]]
}

/// One group of models macOS manages as an *asset set*: a name the subscription
/// service works with, and a MobileAsset type whose folder under
/// `/System/Library/AssetsV2` is the type with dots turned into underscores.
nonisolated struct AppleIntelligenceModelSet: Equatable, Sendable, Identifiable {
    let name: String
    let assetType: String
    let title: String
    let recovery: AppleIntelligenceRecovery

    var id: String { name }
    var folderName: String { assetType.replacingOccurrences(of: ".", with: "_") }
}

/// The five asset sets behind Apple Intelligence. Names, types and recovery
/// mappings come from pared's catalog (github.com/4evy/pared, MIT) and were
/// confirmed against macOS 27.0 by the spike. Purge checks each mapping again on
/// the Mac before it sends anything (`AppleIntelligenceModelStore.remove`).
nonisolated enum AppleIntelligenceCatalog {
    /// The subscriber name Purge's own download requests carry, so Download
    /// again replaces exactly those and nothing Apple or another app owns.
    static let subscriber = "io.getpurge.app"

    static let sets: [AppleIntelligenceModelSet] = [
        AppleIntelligenceModelSet(
            name: "com.apple.modelcatalog",
            assetType: "com.apple.MobileAsset.UAF.FM.GenerativeModels",
            title: String(localized: "Core Apple Intelligence models"),
            recovery: AppleIntelligenceRecovery(
                name: "foundationModels",
                usageAliases: ["com.apple.Settings.AppleIntelligence": "language_en"],
                assetSetUsages: [:])),
        AppleIntelligenceModelSet(
            name: "com.apple.MobileAsset.UAF.FM.Visual",
            assetType: "com.apple.MobileAsset.UAF.FM.Visual",
            title: String(localized: "Image generation models"),
            recovery: AppleIntelligenceRecovery(
                name: "imageGeneration",
                usageAliases: [
                    "VisualGeneration.GenerativePlayground": "language_en",
                    "VisualGeneration.KeyboardEmojiGenerator": "language_en",
                ],
                assetSetUsages: [:])),
        AppleIntelligenceModelSet(
            name: "com.apple.MobileAsset.UAF.FM.CodeLM",
            assetType: "com.apple.MobileAsset.UAF.FM.CodeLM",
            title: String(localized: "Code generation models"),
            recovery: AppleIntelligenceRecovery(
                name: "codeIntelligence",
                usageAliases: [:],
                assetSetUsages: [
                    "com.apple.MobileAsset.UAF.FM.CodeLM": [
                        "com.apple.fm.code.generate_small_v3.base.generic": "ENABLED",
                        "com.apple.fm.code.generate_small_v3.base.draft.generic": "ENABLED",
                        "com.apple.fm.code.generate_small_v3.tokenizer.generic": "ENABLED",
                        "com.apple.fm.code.generate_large_v3.base.generic": "ENABLED",
                        "com.apple.fm.code.generate_large_v3.base.draft.generic": "ENABLED",
                        "com.apple.fm.code.generate_large_v3.tokenizer.generic": "ENABLED",
                        "com.apple.fm.code.generate_safety_guardrail.base.generic": "ENABLED",
                        "com.apple.fm.code.generate_safety_guardrail.tokenizer.generic": "ENABLED",
                    ],
                ])),
        AppleIntelligenceModelSet(
            name: "com.apple.MobileAsset.UAF.Photos.MagicCleanup",
            assetType: "com.apple.MobileAsset.UAF.Photos.MagicCleanup",
            title: String(localized: "Photos Clean Up models"),
            recovery: AppleIntelligenceRecovery(
                name: "photosCleanup",
                usageAliases: ["GenerativeEdit.CleanUp": "language_en"],
                assetSetUsages: [:])),
        AppleIntelligenceModelSet(
            name: "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive",
            assetType: "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive",
            title: String(localized: "Spatial Photos models"),
            recovery: AppleIntelligenceRecovery(
                name: "spatialPhotos",
                usageAliases: ["spatialPhotos.relive.main": "default"],
                assetSetUsages: [:])),
    ]

    /// What stops working without the models, for the confirmation. Apple's own
    /// features from pared's consumer map, plus the apps RemoveMacAI's users
    /// found depending on the same models (its issue 40: Lightroom's AI Denoise).
    static let consequences: [String] = [
        String(localized: "Siri, Writing Tools, Genmoji and Image Playground"),
        String(localized: "Summaries in Mail, Messages, Notes, Safari and notifications"),
        String(localized: "Visual Intelligence, Photos Clean Up and Spatial Photos"),
        String(localized: "Xcode's predictive code completion"),
        String(localized: "Apps that use Apple's on-device models, such as Lightroom's AI Denoise"),
    ]
}

/// Whether a set's folder under /System/Library/AssetsV2 still holds files.
nonisolated enum AppleIntelligenceFolderState: String, Sendable {
    case missing
    case empty
    case holdsFiles
    case unknown
}

/// One set as read from MobileAsset's records.
nonisolated struct AppleIntelligenceSetReading: Equatable, Sendable {
    let set: AppleIntelligenceModelSet
    /// Records whose descriptor says the files are on the filesystem.
    let recordsOnDisk: Int
    /// Records macOS is removing right now.
    let eliminating: Int
    /// Apple's own byte count, newest version of each model only. Several
    /// versions of one model can be on the filesystem at once, and summing them
    /// all overstates what a removal frees. Nil when a record had no readable size.
    let latestBytes: Int64?
    let folder: AppleIntelligenceFolderState

    var isPresent: Bool { recordsOnDisk > 0 || folder == .holdsFiles }
}

/// Everything the Overview row shows, read in one pass.
nonisolated struct AppleIntelligenceReading: Equatable, Sendable {
    let sets: [AppleIntelligenceSetReading]
    let readAt: Date

    var present: [AppleIntelligenceSetReading] { sets.filter(\.isPresent) }
    var isAnythingPresent: Bool { !present.isEmpty }
    var isEliminating: Bool { sets.contains { $0.eliminating > 0 } }

    /// Apple's figure for what is on disk, or nil when any present set has no
    /// readable size, so a partial sum is never shown as the whole.
    var latestBytes: Int64? {
        var total: Int64 = 0
        for item in present {
            guard let bytes = item.latestBytes else { return nil }
            total += bytes
        }
        return total
    }
}

/// Another account on this Mac and whether it uses Apple Intelligence. The
/// models are shared by every account, so the confirmation names them.
nonisolated struct AppleIntelligenceAccount: Equatable, Sendable, Identifiable {
    enum Usage: Equatable, Sendable {
        case usesAppleIntelligence
        case off
        /// Its preferences are not readable from this account.
        case unknown
    }

    let name: String
    let usage: Usage

    var id: String { name }
}

/// What the last Remove or Download again did, for the row.
nonisolated enum AppleIntelligenceOutcome: Equatable, Sendable {
    /// Every targeted set is gone. The two figures are the volume's free space
    /// before versus after: as System Settings shows it, and in raw blocks.
    /// Either is nil unless it cleared the noise floor.
    case removed(sets: Int, freedShownBytes: Int64?, freedRawBytes: Int64?)
    case someLeft(removed: Int, left: Int, reason: String)
    /// The profile was never installed, so nothing was released.
    case profileNotInstalled
    case notReady(String)
    case downloadRequested
    /// Download Again was accepted, but nothing arrived while Purge watched.
    case downloadNotStarted
    /// The profile is still installed, so downloads stay blocked.
    case profileStillInstalled
    case downloadRequestFailed(String)
}
