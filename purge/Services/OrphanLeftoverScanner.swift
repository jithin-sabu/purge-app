import Foundation

/// Streams leftovers whose owning app is no longer installed (issue #26).
///
/// `nonisolated` is load-bearing for the same reason as the other scanners (see
/// the note on `CacheScanner`): under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// this type would be implicitly main-actor isolated and the `Task.detached`
/// below would hop straight back to the UI thread, running the directory walks,
/// the Launch Services lookups, and the `du` sizing there.
nonisolated final class OrphanLeftoverScanner {

    /// Streams each orphaned leftover as an `UninstallItem`, sized before it is
    /// emitted so the list is complete and sortable when it appears. The scan
    /// finishes with nothing when the installed-app view looks incomplete (an
    /// unmounted volume, an unreadable app root), rather than flag everything.
    func orphanStream() -> AsyncStream<UninstallItem> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                Self.run(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Candidate {
        let url: URL
        let category: UninstallCategory
        let appName: String
        let modified: Date
    }

    private static func run(continuation: AsyncStream<UninstallItem>.Continuation) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let installed = OrphanLeftoverScanPolicy.makeInstalledAppIndex()
        guard installed.looksComplete else {
            continuation.finish()
            return
        }
        let staleDays = OrphanLeftoverScanPolicy.effectiveStaleDays()
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 24 * 60 * 60)

        var candidates: [Candidate] = []
        var seen = Set<String>()

        for root in OrphanLeftoverScanPolicy.orphanRoots(home: home) {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            guard let entries = try? fm.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                let name = entry.lastPathComponent
                guard let owner = OrphanLeftoverScanPolicy.candidateOwner(
                    entryName: name,
                    category: root.category,
                    url: entry
                ) else { continue }
                guard OrphanLeftoverScanPolicy.isOrphan(owner, installed: installed) else {
                    continue
                }

                // The folder's own date first: it is free, and a recent one
                // already means in use.
                let folderDate = FolderSizing.contentModificationDate(at: entry)
                guard OrphanLeftoverScanPolicy.isStale(modifiedAt: folderDate, staleDays: staleDays, now: now) else {
                    continue
                }

                // Defend in depth: only offer what the delete gate would accept.
                // Orphan data lives outside the cache allowlist, so this is the
                // same authority the deletion pass uses (`deleteUserSelectedFiles`),
                // not `DeletionSafetyPolicy.isOfferedForCleanup`.
                guard AppUninstallScanPolicy.isEligibleForUninstallDeletion(entry) else { continue }
                guard !ExcludedPathsStore.isExcluded(entry) else { continue }

                let key = entry.standardizedFileURL.path
                guard seen.insert(key).inserted else { continue }

                // Then everything inside: a folder's own date stays old while an
                // app writes deeper in. This is the second line of defence, so
                // data in use is kept even if its owner was misjudged above.
                guard case .untouchedSince(let modified) = OrphanLeftoverScanPolicy.contentAge(
                    of: entry,
                    cutoff: cutoff
                ) else { continue }

                candidates.append(
                    Candidate(
                        url: entry,
                        category: root.category,
                        appName: OrphanLeftoverScanPolicy.friendlyName(bundleID: owner.displayName, url: entry),
                        modified: modified
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
                    matchReason: .bundleID,
                    // App data that does not regenerate: the user opts in per item.
                    isSelected: false,
                    lastModified: candidate.modified
                )
            )
        }
        continuation.finish()
    }
}
