import Foundation

/// Streams leftovers whose owning app is no longer installed (issue #26).
///
/// `nonisolated` is load-bearing for the same reason as the other scanners (see
/// the note on `CacheScanner`): under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// this type would be implicitly main-actor isolated and the `Task.detached`
/// below would hop straight back to the UI thread, running the directory walks,
/// the Launch Services lookups, and the `du` sizing there.
nonisolated final class OrphanLeftoverScanner {

    /// Where the scan looks for the user's Library, and where the Dev Tools
    /// staleness setting is read. Tests hand in a temporary home and throwaway
    /// defaults so they never touch the user's own (#171).
    private let home: URL
    private let defaults: UserDefaults

    /// What is installed, which decides what counts as orphaned. The live one
    /// walks every app root and reads each app's signature, which takes seconds
    /// and blocks a thread, so tests hand in a small fixed index.
    private let installedApps: @Sendable () -> OrphanLeftoverScanPolicy.InstalledAppIndex

    /// Which app each human-named folder belonged to while it was installed
    /// (#224). The live one is the shared ledger file, pruned of folders that
    /// are gone; tests hand in one built on a throwaway folder.
    private let ledger: @Sendable (URL) -> LeftoverOwnerLedger

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        installedApps: @escaping @Sendable () -> OrphanLeftoverScanPolicy.InstalledAppIndex = {
            OrphanLeftoverScanPolicy.makeInstalledAppIndex()
        },
        ledger: @escaping @Sendable (URL) -> LeftoverOwnerLedger = { home in
            LeftoverOwnerLedgerStore.shared.current(home: home)
        }
    ) {
        self.home = home
        self.defaults = defaults
        self.installedApps = installedApps
        self.ledger = ledger
    }

    /// Streams each orphaned leftover as an `UninstallItem`, sized before it is
    /// emitted so the list is complete and sortable when it appears. The scan
    /// finishes with nothing when the installed-app view looks incomplete (an
    /// unmounted volume, an unreadable app root), rather than flag everything.
    func orphanStream() -> AsyncStream<UninstallItem> {
        AsyncStream { [home, defaults, installedApps, ledger] continuation in
            let staleDays = OrphanLeftoverScanPolicy.effectiveStaleDays(userDefaults: defaults)
            let task = Task.detached(priority: .userInitiated) {
                Self.run(
                    home: home,
                    staleDays: staleDays,
                    installed: installedApps(),
                    ledger: ledger(home),
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Candidate {
        let url: URL
        let category: UninstallCategory
        let appName: String
        let evidence: MatchReason
        let ownerBundleID: String?
        let modified: Date
    }

    private static func run(
        home: URL,
        staleDays: Int,
        installed: OrphanLeftoverScanPolicy.InstalledAppIndex,
        ledger: LeftoverOwnerLedger,
        continuation: AsyncStream<UninstallItem>.Continuation
    ) {
        let fm = FileManager.default

        guard installed.looksComplete else {
            continuation.finish()
            return
        }
        let cutoff = OrphanLeftoverScanPolicy.staleCutoff(staleDays: staleDays)
        // Which ids Preferences and Caches carry, read once for every
        // human-named Application Support folder (#224).
        let clues = OrphanLeftoverScanPolicy.LibraryIdentifierClues.gather(home: home)

        var candidates: [Candidate] = []
        var seen = Set<String>()

        for root in OrphanLeftoverScanPolicy.orphanRoots(home: home) {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            guard let entries = try? fm.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                // Owner, orphaned, and untouched all the way down, in one
                // tested decision.
                guard let orphan = OrphanLeftoverScanPolicy.orphanCandidate(
                    at: entry,
                    category: root.category,
                    installed: installed,
                    cutoff: cutoff,
                    home: home,
                    ledger: ledger,
                    clues: clues
                ) else { continue }

                // Defend in depth: only offer what the delete gate would accept.
                // Orphan data lives outside the cache allowlist, so this is the
                // same authority the deletion pass uses (`deleteUserSelectedFiles`),
                // not `DeletionSafetyPolicy.isOfferedForCleanup`.
                guard AppUninstallScanPolicy.isEligibleForUninstallDeletion(entry, home: home) else { continue }
                guard !ExcludedPathsStore.isExcluded(entry) else { continue }

                let key = entry.standardizedFileURL.path
                guard seen.insert(key).inserted else { continue }

                let ownerBundleID: String?
                switch orphan.owner {
                case .bundleID(let id): ownerBundleID = id
                case .appGroup: ownerBundleID = nil
                }
                candidates.append(
                    Candidate(
                        url: entry,
                        category: root.category,
                        appName: orphan.appName
                            ?? OrphanLeftoverScanPolicy.friendlyName(bundleID: orphan.owner.displayName, url: entry),
                        evidence: orphan.evidence,
                        ownerBundleID: ownerBundleID,
                        modified: orphan.lastModified
                    )
                )
            }
        }

        let sizes = FolderSizing.directorySizes(at: candidates.map(\.url))

        for candidate in candidates {
            if Task.isCancelled { break }
            let size = sizes[candidate.url.standardizedFileURL.path] ?? 0
            let safety = OrphanLeftoverScanPolicy.safetyInfo(
                appName: candidate.appName,
                category: candidate.category
            )
            continuation.yield(
                UninstallItem(
                    path: candidate.url,
                    sizeBytes: size,
                    category: candidate.category,
                    safetyInfo: safety,
                    matchReason: candidate.evidence,
                    // App data that does not regenerate: the user opts in per item.
                    isSelected: false,
                    lastModified: candidate.modified,
                    ownerBundleID: candidate.ownerBundleID
                )
            )
        }
        continuation.finish()
    }
}
