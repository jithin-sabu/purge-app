import Foundation

/// Rules for noticing an app leave the Applications folders outside Purge and
/// deciding whether its leftovers are worth a review (issue #65). Pure, so every
/// decision can be tested without a live FSEvents stream.
nonisolated enum RemovedAppWatchPolicy {

    /// How long a vanished bundle must stay gone before Purge speaks up. Updaters
    /// (Sparkle, the App Store, `brew upgrade`) move the old bundle out and the new
    /// one in; prompting inside that window would offer to trash the support files
    /// of an app that is being updated, not removed.
    static let settleDelay: Duration = .seconds(3)

    /// FSEvents can report `/Applications` by its data-volume path, and directory
    /// events carry a trailing slash. Both are folded away so paths compare equal to
    /// the roots `AppUninstallScanPolicy` hands out.
    static func normalizedPath(_ path: String) -> String {
        var result = path
        let dataVolume = "/System/Volumes/Data"
        if result.hasPrefix(dataVolume + "/") {
            result.removeFirst(dataVolume.count)
        }
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// Whether a change reported at `path` can add or remove a watched bundle: the
    /// root itself, or a folder directly inside it (a vendor folder, or a bundle being
    /// swapped). Anything deeper is a bundle's own internals churning during an update
    /// or a launch, which is most of the traffic under `/Applications`.
    static func isRelevantChange(atPath path: String, roots: [String]) -> Bool {
        let normalized = normalizedPath(path)
        for root in roots {
            if normalized == root { return true }
            guard normalized.hasPrefix(root + "/") else { continue }
            return !normalized.dropFirst(root.count + 1).contains("/")
        }
        return false
    }

    /// Bundles in `previous` that are missing from `current`, both keyed by bundle path.
    static func departedApps(
        previous: [String: InstalledApp],
        current: [String: InstalledApp]
    ) -> [InstalledApp] {
        previous
            .filter { current[$0.key] == nil }
            .map(\.value)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether a bundle that left, and stayed gone through `settleDelay`, gets a
    /// leftovers review.
    ///
    /// - A bundle back at its path was an update, not a removal.
    /// - Another bundle with the same identifier still in the app roots means the app
    ///   was moved or renamed, or a second copy is staying; its support files are
    ///   still in use.
    /// - Purge's own uninstaller already reviewed what it removed.
    /// - Without a bundle identifier only weak name matches are possible, which is
    ///   not enough to interrupt the user for.
    static func shouldOfferReview(
        for app: InstalledApp,
        bundleStillExists: Bool,
        installedBundleIDs: Set<String>,
        removedByPurge: Bool
    ) -> Bool {
        guard !removedByPurge, !bundleStillExists else { return false }
        // Kept free of `AppUninstallScanPolicy` so the background agent can share
        // this file. The agent and the main app both treat Purge and anything under
        // `/System` as off-limits.
        let path = app.bundleURL.standardizedFileURL.path
        if path.hasPrefix("/System/") { return false }
        if let id = app.bundleID?.lowercased(), id == "io.getpurge.app" { return false }
        guard let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty else { return false }
        return !installedBundleIDs.contains(bundleID)
    }

    /// `/Applications` and `~/Applications` — the same roots the uninstaller
    /// enumerates. Duplicated here so the agent binary does not need that policy.
    static func installedAppRoots() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
    }
}
