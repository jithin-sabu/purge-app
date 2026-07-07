import Foundation

/// Ordered resolution: user override -> AI disk cache -> bundled DB -> tier list -> unknown.
/// User overrides are keyed by exact path and trump every automatic source.
enum ExplanationResolver {
    nonisolated static let unsureExplanation = "We could not identify this folder. We recommend leaving it alone."

    /// Resolution order:
    /// 1. `user_overrides.json` keyed by exact path (when provided)
    /// 2. `ai_cache.json` keyed by folder name
    /// 3. Bundled `explanations.json`
    /// 4. `SafetyTierList`
    /// 5. Return unknown
    nonisolated static func initialSafetyForCacheFolder(
        folderName: String,
        friendlyHeadline: String,
        path: URL? = nil
    ) -> SafetyInfo {
        if let path,
           let override = UserOverridesStore.read(path: path) {
            return UserOverridesStore.safetyInfo(from: override, friendlyHeadline: friendlyHeadline)
        }
        if let cached = AICacheStore.read(folderName: folderName) {
            return AICacheStore.safetyInfo(from: cached)
        }
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
            explanation = "This is a known cache folder that apps or developer tools recreate automatically."
        case .medium:
            explanation = "This folder may involve synced or user-facing app data. Deleting it can be safe, but it may cause inconvenience."
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
