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
        return checkFirstReason == nil ? info : info.heldAtCheckFirst(path: path)
    }

    /// Holds an artifact of a project that may still be in use at Check First, so
    /// Clean Safe Items and scheduled cleans leave it alone while it stays listed.
    /// The reason is shown once on the project card, so the folder's own explanation
    /// is kept as is. A manual override of this exact path is the user's decision.
    nonisolated func heldAtCheckFirst(path: URL) -> SafetyInfo {
        guard UserOverridesStore.read(path: path) == nil else { return self }
        switch level {
        case .safe:
            return SafetyInfo(
                level: .medium,
                headline: headline,
                explanation: explanation,
                recoverySteps: recoverySteps,
                reinstallCommand: reinstallCommand
            )
        case .medium, .unknown:
            return self
        }
    }
}
