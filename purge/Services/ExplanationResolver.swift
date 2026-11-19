import Foundation

/// Ordered resolution: bundled DB -> tier list -> unknown.
///
/// Safety levels set by hand in Purge 1.0 and 1.1 are left in `user_overrides.json`
/// but never read (#415). An old Safe label outranked every automatic rule, so it
/// could take a Check First folder into Clean Safe Items and scheduled cleans.
///
/// Guesses left in `ai_cache.json` by the removed AI classifier are deliberately not
/// read. They outranked the reviewed list, so a guess could mark a folder Safe that
/// the bundled data never vetted, and only on Macs that ran an early build.
enum ExplanationResolver {
    nonisolated static let unsureExplanation = String(localized: "We could not identify this folder. We recommend leaving it alone.")

    /// Resolution order:
    /// 1. Bundled `explanations.json`
    /// 2. `SafetyTierList`
    /// 3. Return unknown
    nonisolated static func initialSafetyForCacheFolder(
        folderName: String,
        friendlyHeadline: String,
        path: URL? = nil
    ) -> SafetyInfo {
        if let record = ExplanationDatabase.matchBundledDatabase(folderName: folderName) {
            return ExplanationDatabase.safetyInfo(from: record)
        }
        if let tierLevel = SafetyTierList.evaluate(folderName: folderName, path: path) {
            return tierSafetyInfo(level: tierLevel, headline: friendlyHeadline)
        }
        return SafetyInfo(
            level: .unknown,
            headline: friendlyHeadline,
            explanation: unsureExplanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }

    nonisolated static func tierSafetyInfo(level: SafetyLevel, headline: String) -> SafetyInfo {
        let explanation: String
        switch level {
        case .safe:
            explanation = String(localized: "This is a known cache folder that apps or developer tools recreate automatically.")
        case .medium:
            explanation = String(localized: "This folder may involve synced or user-facing app data. Deleting it can be safe, but it may cause inconvenience.")
        case .unknown:
            explanation = unsureExplanation
        }
        return SafetyInfo(
            level: level,
            headline: headline,
            explanation: explanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }
}
