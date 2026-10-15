import Foundation

extension SafetyInfo {
    /// Local `explanations.json` only (no live AI). Used for dev tool rows.
    /// When `path` is supplied, a manual user override at that exact path
    /// takes priority and is returned instead.
    nonisolated static func fromExplanationDatabase(
        key: String,
        friendlyFallback: String? = nil,
        reinstallCommand: String? = nil,
        path: URL? = nil
    ) -> SafetyInfo {
        let fallback = friendlyFallback ?? key

        if let path,
           let override = UserOverridesStore.read(path: path) {
            let info = UserOverridesStore.safetyInfo(from: override, friendlyHeadline: fallback)
            return SafetyInfo(
                level: info.level,
                headline: info.headline,
                explanation: info.explanation,
                recoverySteps: "",
                reinstallCommand: reinstallCommand
            )
        }

        if let record = ExplanationDatabase.matchBundledDatabase(folderName: key) {
            return ExplanationDatabase.safetyInfo(from: record, reinstallCommand: reinstallCommand)
        }
        let unknown = ExplanationDatabase.safetyInfoForUnknownBundledLookup(friendlyFallback: fallback)
        return SafetyInfo(
            level: unknown.level,
            headline: unknown.headline,
            explanation: unknown.explanation,
            recoverySteps: "",
            reinstallCommand: reinstallCommand
        )
    }

    /// Safety for project artifacts shown after staleness filtering. Safe to Clean by
    /// default, unless the user has overridden this exact path, or the artifact's rule
    /// declares a stricter tier (Unity and Unreal are Check First because rebuilding
    /// them costs real time even though it is automatic).
    nonisolated static func forStaleProjectArtifact(
        kind: DeletableArtifactKind,
        path: URL,
        reinstallCommand: String? = nil,
        level: SafetyLevel = .safe,
        checkFirstReason: ProjectCheckFirstReason? = nil
    ) -> SafetyInfo {
        let base = fromExplanationDatabase(
            key: kind.explanationKey,
            friendlyFallback: kind.rowTag,
            reinstallCommand: reinstallCommand,
            path: path
        )
        if UserOverridesStore.read(path: path) != nil { return base }
        let info = SafetyInfo(
            level: level,
            headline: base.headline,
            explanation: base.explanation,
            recoverySteps: base.recoverySteps,
            reinstallCommand: base.reinstallCommand
        )
        guard let checkFirstReason else { return info }
        return info.checkFirst(for: checkFirstReason, path: path)
    }

    /// Holds an artifact of a project that may still be in use at Check First, so
    /// Clean Safe Items and scheduled cleans leave it alone while it stays listed.
    /// A manual override of this exact path is the user's decision and is kept.
    nonisolated func checkFirst(for reason: ProjectCheckFirstReason, path: URL) -> SafetyInfo {
        guard UserOverridesStore.read(path: path) == nil else { return self }
        switch level {
        case .safe:
            let note: String
            switch reason {
            case .usedRecently:
                note = String(localized: "You worked on this project in the last 6 months, so Purge won't clean it without asking.")
            case .tooBigToCheck:
                note = String(localized: "This project is too big for Purge to check every file for recent changes, so Purge won't clean it without asking.")
            }
            return SafetyInfo(
                level: .medium,
                headline: headline,
                // First, so the row's line limit never cuts it off.
                explanation: explanation.isEmpty ? note : note + " " + explanation,
                recoverySteps: recoverySteps,
                reinstallCommand: reinstallCommand
            )
        case .medium, .unknown:
            return self
        }
    }
}
