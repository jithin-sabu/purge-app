import Foundation

/// Ordered resolution: user override -> AI disk cache -> bundled DB -> tier list -> AI placeholder.
/// User overrides are keyed by exact path and trump every automatic source.
enum ExplanationResolver {
    nonisolated static let checkingExplanation = "Checking..."
    nonisolated static let unsureExplanation = "We are not sure what this is. We recommend leaving it alone."

    nonisolated static func isAwaitingAI(_ info: SafetyInfo) -> Bool {
        info.explanation == checkingExplanation
    }

    /// Resolution order:
    /// 1. `user_overrides.json` keyed by exact path (when provided)
    /// 2. `ai_cache.json` keyed by folder name
    /// 3. Bundled `explanations.json`
    /// 4. `SafetyTierList`
    /// 5. Placeholder while async AI resolution runs
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
        if let tierLevel = SafetyTierList.evaluate(folderName: folderName) {
            return tierSafetyInfo(level: tierLevel, headline: friendlyHeadline)
        }
        return SafetyInfo(
            level: .unknown,
            headline: friendlyHeadline,
            explanation: checkingExplanation,
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
        case .danger:
            explanation = "This folder can contain passwords, credentials, or critical system data. Leave it alone."
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

    nonisolated static func unsureSafetyInfo(headline: String) -> SafetyInfo {
        SafetyInfo(
            level: .unknown,
            headline: headline,
            explanation: unsureExplanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }

    private static let coordinator = AIFetchCoordinator()

    /// Call after scan for each distinct folder name that is still `Checking...`.
    static func resolveWithAIIfNeeded(
        folderName: String,
        friendlyHeadline: String,
        path: URL? = nil
    ) async -> SafetyInfo {
        await coordinator.resolve(
            folderName: folderName,
            friendlyHeadline: friendlyHeadline,
            path: path
        )
    }

    /// Force a fresh remote categorization. Skips caches and tier list so the
    /// model can produce a different answer than what is on disk today. The new
    /// result is written back to `ai_cache.json`. User overrides still win.
    static func recategorizeWithAI(
        folderName: String,
        friendlyHeadline: String,
        path: URL? = nil
    ) async -> SafetyInfo {
        if let path,
           let override = UserOverridesStore.read(path: path) {
            return UserOverridesStore.safetyInfo(from: override, friendlyHeadline: friendlyHeadline)
        }
        return await coordinator.forceFreshFetch(folderName: folderName, friendlyHeadline: friendlyHeadline)
    }
}

private actor AIFetchCoordinator {
    private var inFlight: [String: Task<SafetyInfo, Never>] = [:]

    func resolve(folderName: String, friendlyHeadline: String, path: URL?) async -> SafetyInfo {
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
        if let tierLevel = SafetyTierList.evaluate(folderName: folderName) {
            return ExplanationResolver.tierSafetyInfo(level: tierLevel, headline: friendlyHeadline)
        }

        let key = folderName.lowercased()
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<SafetyInfo, Never> {
            await self.fetchAndPersist(folderName: folderName, friendlyHeadline: friendlyHeadline)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    func forceFreshFetch(folderName: String, friendlyHeadline: String) async -> SafetyInfo {
        let key = folderName.lowercased()
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<SafetyInfo, Never> {
            await self.fetchAndPersist(folderName: folderName, friendlyHeadline: friendlyHeadline)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func fetchAndPersist(folderName: String, friendlyHeadline: String) async -> SafetyInfo {
        do {
            let payload = try await OpenRouterExplanationClient.fetchExplanation(folderName: folderName)
            let balancedTag = applyBalancedDowngrade(tag: payload.tag, confidence: payload.confidence)
            AICacheStore.write(
                folderName: folderName,
                displayName: payload.displayName,
                tag: balancedTag,
                explanation: payload.explanation,
                confidence: payload.confidence
            )
            if let again = AICacheStore.read(folderName: folderName) {
                return AICacheStore.safetyInfo(from: again)
            }
            return Self.makeSafety(from: payload)
        } catch {
            return ExplanationResolver.unsureSafetyInfo(headline: friendlyHeadline)
        }
    }

    private nonisolated static func makeSafety(from payload: AIExplanationResult) -> SafetyInfo {
        let balancedTag = applyBalancedDowngrade(tag: payload.tag, confidence: payload.confidence)
        let level: SafetyLevel
        switch balancedTag {
        case "safe": level = .safe
        case "medium": level = .medium
        case "danger": level = .danger
        case "unknown": level = .unknown
        default: level = .unknown
        }
        return SafetyInfo(
            level: level,
            headline: payload.displayName,
            explanation: payload.explanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }
}
