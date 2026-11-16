import Foundation

/// How macOS downloads a set again: the subscription Download Again sends.
/// Aliases and usages are what pared's catalog ships for macOS 27, except that
/// a language alias is resolved on the Mac when the request is sent (#179),
/// and an alias macOS no longer knows is left out (#385).
nonisolated struct AppleIntelligenceRecovery: Equatable, Sendable {
    /// What a usage alias is asked for. macOS defines each alias's values under
    /// `/System/Library/UnifiedAssetFramework/UsageAliases/<alias>/`, one plist
    /// per value: `default`, or one `language_<code>` per Apple Intelligence
    /// language.
    enum AliasValue: Equatable, Sendable {
        /// `language_<code>` for the Mac's Siri language, which is how System
        /// Settings subscribes: its own row reads `<alias>_language_en` on an
        /// en-US Mac. See `AppleIntelligenceAliasLanguage`.
        case language
        case fixed(String)
    }

    let name: String
    let usageAliases: [String: AliasValue]
    let assetSetUsages: [String: [String: String]]

    /// The values to try for each alias, in order: `languageValues` for a
    /// language alias, the one fixed value otherwise. The worker keeps the
    /// first value macOS knows and leaves out an alias it knows none of (#385).
    func usageAliasCandidates(languageValues: [String]) -> [String: [String]] {
        var candidates: [String: [String]] = [:]
        for (alias, value) in usageAliases {
            switch value {
            case .language: candidates[alias] = languageValues
            case .fixed(let fixed): candidates[alias] = [fixed]
            }
        }
        return candidates
    }
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
    var folderName: String { AppleIntelligenceModelReader.folderName(for: assetType) }
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
                usageAliases: ["com.apple.Settings.AppleIntelligence": .language],
                assetSetUsages: [:])),
        AppleIntelligenceModelSet(
            name: "com.apple.MobileAsset.UAF.FM.Visual",
            assetType: "com.apple.MobileAsset.UAF.FM.Visual",
            title: String(localized: "Image generation models"),
            recovery: AppleIntelligenceRecovery(
                name: "imageGeneration",
                // macOS 27.2 removed the GenerativePlayground alias, so there
                // the subscription goes with KeyboardEmojiGenerator alone. On
                // 27.0 both ask for the same three FM.Visual models (#385).
                usageAliases: [
                    "VisualGeneration.GenerativePlayground": .language,
                    "VisualGeneration.KeyboardEmojiGenerator": .language,
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
                usageAliases: ["GenerativeEdit.CleanUp": .language],
                assetSetUsages: [:])),
        AppleIntelligenceModelSet(
            name: "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive",
            assetType: "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive",
            title: String(localized: "Spatial Photos models"),
            recovery: AppleIntelligenceRecovery(
                name: "spatialPhotos",
                usageAliases: ["spatialPhotos.relive.main": .fixed("default")],
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
    /// Records whose asset folder is on disk, or that couldn't be checked.
    /// A record left from a purged version doesn't count (#305).
    let recordsOnDisk: Int
    /// Records macOS is removing right now.
    let eliminating: Int
    /// Apple's own byte count, newest version of each model only. Several
    /// versions of one model can be on the filesystem at once, and summing them
    /// all overstates what a removal frees. Nil when a record had no readable
    /// size or its asset folder couldn't be checked.
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
    /// `reason` is short enough for the row. `details` is everything macOS
    /// answered, for the Details button; nil when Purge has no more to say (#343).
    case someLeft(removed: Int, left: Int, reason: String, details: String?)
    /// The user stopped the removal between sets, and nothing failed.
    case stopped(removed: Int, left: Int)
    /// The profile was never installed, so nothing was released.
    case profileNotInstalled
    case notReady(String, details: String?)
    case downloadRequested
    /// Download Again was accepted, but nothing arrived while Purge watched.
    case downloadNotStarted
    /// The profile is still installed, so downloads stay blocked.
    case profileStillInstalled
    case downloadRequestFailed(String, details: String?)

    /// What macOS answered when the action failed, for the row's Details button.
    var details: String? {
        switch self {
        case .someLeft(_, _, _, let details), .notReady(_, let details), .downloadRequestFailed(_, let details):
            return details
        case .removed, .stopped, .profileNotInstalled, .downloadRequested, .downloadNotStarted, .profileStillInstalled:
            return nil
        }
    }

    /// What the user can do after a failed Remove or Download Again, for the
    /// row's Details. `undoTitle` is the title the button that lifts the block
    /// has right now, so the steps name the button the row shows.
    ///
    /// A restart comes first: it lets go of a model something still holds
    /// (RemoveMacAI's issue 38) and of a download stuck on the block (its issue
    /// 109). The second step is what got the removal through on the macOS 27.3
    /// beta, where the service dropped every release (its issue 123, #343).
    func nextSteps(undoTitle: String) -> [String] {
        switch self {
        case .someLeft:
            return [
                String(localized: "Restart your Mac, then click Remove again."),
                String(localized: "If they still stay, click \(undoTitle), leave your Mac on until macOS has finished downloading the models, then click Remove again."),
            ]
        case .downloadRequestFailed:
            return [
                String(localized: "Restart your Mac, then click Download Again."),
                String(localized: "The profile is gone, so macOS also downloads the models by itself when you use a feature that needs them."),
            ]
        case .removed, .stopped, .notReady, .profileNotInstalled, .downloadRequested, .downloadNotStarted,
             .profileStillInstalled:
            return []
        }
    }
}
