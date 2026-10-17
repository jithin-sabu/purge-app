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

    /// The hidden home folders apps write, by bundle id (#224). The shipped
    /// catalog in the app; tests hand in a small one.
    private let catalog: AppDotFolderCatalog

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        installedApps: @escaping @Sendable () -> OrphanLeftoverScanPolicy.InstalledAppIndex = {
            OrphanLeftoverScanPolicy.makeInstalledAppIndex()
        },
        ledger: @escaping @Sendable (URL) -> LeftoverOwnerLedger = { home in
            LeftoverOwnerLedgerStore.shared.current(home: home)
        },
        catalog: AppDotFolderCatalog = .shared
    ) {
        self.home = home
        self.defaults = defaults
        self.installedApps = installedApps
        self.ledger = ledger
        self.catalog = catalog
    }

    /// Streams each orphaned leftover as an `UninstallItem`, sized before it is
    /// emitted so the list is complete and sortable when it appears. The scan
    /// finishes with nothing when the installed-app view looks incomplete (an
    /// unmounted volume, an unreadable app root), rather than flag everything.
    func orphanStream() -> AsyncStream<UninstallItem> {
        AsyncStream { [home, defaults, installedApps, ledger, catalog] continuation in
            let staleDays = OrphanLeftoverScanPolicy.effectiveStaleDays(userDefaults: defaults)
            let task = Task.detached(priority: .userInitiated) {
                Self.run(
                    home: home,
                    staleDays: staleDays,
                    installed: installedApps(),
                    ledger: ledger(home),
                    catalog: catalog,
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
        let ownerBundleIDs: [String]
        let modified: Date
    }

    private static func run(
        home: URL,
        staleDays: Int,
        installed: OrphanLeftoverScanPolicy.InstalledAppIndex,
        ledger: LeftoverOwnerLedger,
        catalog: AppDotFolderCatalog,
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

                candidates.append(
                    Candidate(
                        url: entry,
                        category: root.category,
                        appName: orphan.appName
                            ?? OrphanLeftoverScanPolicy.friendlyName(bundleID: orphan.owner.displayName, url: entry),
                        evidence: orphan.evidence,
                        ownerBundleIDs: orphan.ownerBundleIDs,
                        modified: orphan.lastModified
                    )
                )
            }
        }

        // Hidden home folders of removed apps, from the catalog alone (#224).
        for dotFolder in OrphanLeftoverScanPolicy.dotFolderCandidates(
            catalog: catalog, home: home, installed: installed, cutoff: cutoff
        ) {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            guard AppUninstallScanPolicy.isEligibleForUninstallDeletion(
                dotFolder.url, home: home, dotFolderCatalog: catalog
            ) else { continue }
            guard !ExcludedPathsStore.isExcluded(dotFolder.url) else { continue }
            guard seen.insert(dotFolder.url.standardizedFileURL.path).inserted else { continue }
            candidates.append(
                Candidate(
                    url: dotFolder.url,
                    category: .homeFolderData,
                    appName: dotFolder.entry.displayName,
                    evidence: .dotFolderCatalog,
                    ownerBundleIDs: [dotFolder.entry.bundleID],
                    modified: dotFolder.lastModified
                )
            )
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
                    ownerBundleIDs: candidate.ownerBundleIDs
                )
            )
        }
        continuation.finish()
    }
}
