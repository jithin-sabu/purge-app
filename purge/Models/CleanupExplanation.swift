import Foundation

extension SafetyInfo {
    /// Local `explanations.json` only (no live AI). Used for dev tool rows.
    /// `bundle` is for tests, which read the Chinese text the English test host
    /// would not show.
    nonisolated static func fromExplanationDatabase(
        key: String,
        friendlyFallback: String? = nil,
        reinstallCommand: String? = nil,
        bundle: Bundle = .main
    ) -> SafetyInfo {
        let fallback = friendlyFallback ?? key

        if let record = ExplanationDatabase.matchBundledDatabase(folderName: key) {
            return ExplanationDatabase.safetyInfo(from: record, reinstallCommand: reinstallCommand, bundle: bundle)
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

    /// Safety for project artifacts shown after staleness filtering. The level is the
    /// artifact rule's tier from `ProjectArtifactCatalog`, which callers must pass:
    /// Unity and Unreal are Check First because rebuilding them costs real time even
    /// though it is automatic. A project that may still be in use is held at Check First.
    nonisolated static func forStaleProjectArtifact(
        kind: DeletableArtifactKind,
        reinstallCommand: String? = nil,
        level: SafetyLevel,
        checkFirstReason: ProjectCheckFirstReason? = nil
    ) -> SafetyInfo {
        let base = fromExplanationDatabase(
            key: kind.explanationKey,
            friendlyFallback: kind.rowTag,
            reinstallCommand: reinstallCommand
        )
        let info = SafetyInfo(
            level: level,
            headline: base.headline,
            explanation: base.explanation,
            recoverySteps: base.recoverySteps,
            reinstallCommand: base.reinstallCommand
        )
        return checkFirstReason == nil ? info : info.heldAtCheckFirst()
    }

    /// Holds an artifact of a project that may still be in use at Check First, so
    /// Clean Safe Items and scheduled cleans leave it alone while it stays listed.
    /// The reason is shown once on the project card, so the folder's own explanation
    /// is kept as is.
    nonisolated func heldAtCheckFirst() -> SafetyInfo {
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
