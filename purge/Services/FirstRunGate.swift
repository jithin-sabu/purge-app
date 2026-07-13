import Foundation

/// Decides, once per install, whether onboarding should run.
///
/// `hasCompletedOnboarding` is absent both on a clean install and on an update from a build that
/// shipped before onboarding existed, so the flag alone cannot tell those two users apart. This
/// gate resolves the ambiguity on the first launch that sees no flag: an install that already has
/// Purge settings or Application Support files behind it has been used before and is marked
/// complete; one with no trace on disk is genuinely new and gets the flow.
///
/// Must run before any code that writes user defaults, so the evidence it reads is the user's, not
/// this launch's.
enum FirstRunGate {
    static let onboardingCompletedKey = "hasCompletedOnboarding"
    static let firstSeenVersionKey = "install.firstSeenVersion"
    static let firstSeenAtKey = "install.firstSeenAt"

    enum Decision: Equatable {
        /// No prior trace of Purge: onboarding runs.
        case freshInstall
        /// Pre-onboarding install detected: onboarding is skipped.
        case existingInstall
        /// The flag was already written by a previous launch; left untouched.
        case alreadyResolved
    }

    /// Keys any shipped version of Purge may have written. Presence of one means the app has run
    /// on this machine before. Registered (non-persistent) defaults never appear here because the
    /// gate reads the persistent domain directly.
    private static let priorUsageKeys: Set<String> = [
        "totalRecoveredBytes",
        "lastScanCompletedAt",
        "lastScanSafeRecoverableBytes",
        "appearance.mode",
        "developerMode.enabled",
        "devTools.stalenessThreshold",
        "scheduledClean.enabled",
        "scheduledClean.enabledAt",
        "scheduledClean.frequency",
        "ScheduledCleaningRegistrar.lastOutcome",
        "ScheduledCleaningRegistrar.lastGraceSweep",
        "cleanCompletion.lastShownTimeQuip",
        "largeFiles.minSizeMB",
        "filter.appCaches",
        "filter.devTools",
        "filter.largeFiles",
        "filter.largeFiles.size",
        "filter.largeFiles.lastUsed",
        "sort.appCaches",
        "sort.devTools",
        "sort.largeFiles",
        "onboarding.pendingCelebration",
    ]

    private static let supportFilenames = [
        "cleanup_history.json",
        "user_overrides.json",
        "excluded_paths.json",
        "ai_cache.json",
    ]

    @discardableResult
    static func resolve(
        defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? "io.getpurge.app",
        supportDirectory: URL? = defaultSupportDirectory(),
        appVersion: String = currentAppVersion(),
        now: Date = Date()
    ) -> Decision {
#if DEBUG
        // Scheme launch argument `-purge.resetFirstRun YES` replays onboarding on a machine that
        // already has Purge state, which is otherwise indistinguishable from an update.
        if defaults.bool(forKey: "purge.resetFirstRun") {
            defaults.set(false, forKey: onboardingCompletedKey)
            defaults.set(false, forKey: "onboarding.pendingCelebration")
            defaults.set(appVersion, forKey: firstSeenVersionKey)
            defaults.set(now, forKey: firstSeenAtKey)
            return .freshInstall
        }
#endif

        let persisted = Set(defaults.persistentDomain(forName: domainName)?.keys ?? [:].keys)

        guard !persisted.contains(onboardingCompletedKey) else {
            return .alreadyResolved
        }

        let hasPriorUsage = !persisted.isDisjoint(with: priorUsageKeys)
            || hasSupportFiles(in: supportDirectory)

        defaults.set(hasPriorUsage, forKey: onboardingCompletedKey)
        defaults.set(appVersion, forKey: firstSeenVersionKey)
        defaults.set(now, forKey: firstSeenAtKey)

        return hasPriorUsage ? .existingInstall : .freshInstall
    }

    static func defaultSupportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("io.getpurge.app", isDirectory: true)
    }

    static func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static func hasSupportFiles(in directory: URL?) -> Bool {
        guard let directory else { return false }
        return supportFilenames.contains { name in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name, isDirectory: false).path
            )
        }
    }
}
