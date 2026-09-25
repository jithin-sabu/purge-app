import AppKit
import Foundation

/// Rules for noticing an app leave the Applications folders outside Purge and
/// deciding whether its leftovers are worth a review (issue #65). Shared with the
/// background agent, so it stays free of the uninstaller's policy and models.
///
/// A bundle dragged to the Trash is reviewed the moment it lands there. Anything
/// else is followed for a while first (`followDecision`), because that is how
/// updaters work: `brew upgrade` moves the old copy into the Caskroom before the
/// new one arrives, and some installers delete it before writing the new one.
/// Every stage also asks again whether another copy of the app is still on this
/// Mac: the agent before it records the removal, Purge before it shows the review,
/// a live watch while the review is open, and Purge once more when the user
/// confirms.
nonisolated enum RemovedAppWatchPolicy {

    /// Where a departed bundle went, read from a handle opened while it was
    /// still in the app roots (see `ApplicationsFolderWatcher`).
    enum DepartureKind: Equatable, Sendable {
        /// In a Trash: the user deleted it. Reviewed at once.
        case trashed
        /// Still on disk outside the roots: moved to the Desktop, or set aside by
        /// an updater. Not a removal while it stays there.
        case movedElsewhere
        /// Gone from disk, or its whereabouts are unknown.
        case deleted
    }

    /// How long a departure that did not go to the Trash is followed.
    struct FollowTiming: Sendable {
        /// A deleted bundle counts once the app roots have had no changes for this
        /// long. An installer that deletes the old copy first keeps writing while it
        /// installs the new one, which keeps pushing this back; a plain `rm` is
        /// reviewed this long after it happens.
        var quietPeriod: Duration
        /// A deleted bundle counts after this long even if the roots never go quiet,
        /// since other apps can write near the top of `/Applications` at any time.
        var maxDeletedWait: Duration
        /// How long a copy moved out of the roots is followed. Deleting or trashing
        /// it in that time is a removal (`brew uninstall` moves the app into the
        /// Caskroom, then deletes it); still there at the end means it was moved.
        var movedFollowWindow: Duration
        /// How often a followed bundle is checked. Nothing reports on a copy
        /// outside the roots being deleted, so it is polled; one `fcntl` and one
        /// `lstat` per check, only while a departure is being followed.
        var pollInterval: Duration

        static let standard = FollowTiming(
            quietPeriod: .seconds(2),
            maxDeletedWait: .seconds(30),
            movedFollowWindow: .seconds(60),
            pollInterval: .milliseconds(250)
        )
    }

    enum FollowDecision: Equatable, Sendable {
        case report
        case drop
        case keepFollowing
    }

    /// What to do with a departure that did not go straight to the Trash, at one
    /// check. `sinceDeleted` is how long the bundle has been known to be deleted
    /// (nil while it still exists somewhere).
    static func followDecision(
        kind: DepartureKind,
        appIsBack: Bool,
        sinceDeparture: Duration,
        sinceDeleted: Duration?,
        sinceActivity: Duration,
        timing: FollowTiming
    ) -> FollowDecision {
        // The update landed, or the app was put back: nothing was removed.
        if appIsBack { return .drop }
        switch kind {
        case .trashed:
            return .report
        case .movedElsewhere:
            return sinceDeparture >= timing.movedFollowWindow ? .drop : .keepFollowing
        case .deleted:
            if sinceActivity >= timing.quietPeriod { return .report }
            if let sinceDeleted, sinceDeleted >= timing.maxDeletedWait { return .report }
            return .keepFollowing
        }
    }

    /// How long an unhandled removal record stays worth acting on. A record only
    /// waits when Purge cannot show it yet (onboarding, Full Disk Access), and a
    /// review about an app removed more than a week ago would read as a bug.
    static let recordLifetime: TimeInterval = 7 * 24 * 60 * 60

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

    /// Whether a bundle that left gets a leftovers review.
    ///
    /// - A bundle back at its path was an update, not a removal.
    /// - Another bundle with the same identifier still in the app roots, or anywhere
    ///   else on this Mac (`otherCopyExists`), means the app was moved, renamed, or is
    ///   mid-update; its support files are still in use.
    /// - Purge's own uninstaller already reviewed what it removed.
    /// - Without a bundle identifier only weak name matches are possible, which is
    ///   not enough to interrupt the user for.
    static func shouldOfferReview(
        for app: InstalledApp,
        bundleStillExists: Bool,
        installedBundleIDs: Set<String>,
        otherCopyExists: Bool,
        removedByPurge: Bool
    ) -> Bool {
        guard !removedByPurge, !bundleStillExists, !otherCopyExists else { return false }
        let path = app.bundleURL.standardizedFileURL.path
        if path.hasPrefix("/System/") { return false }
        guard let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty else { return false }
        if bundleID == "io.getpurge.app" { return false }
        return !installedBundleIDs.contains(bundleID)
    }

    // MARK: Other copies

    /// Whether Launch Services knows a live copy of `app` somewhere other than the
    /// path it left. Catches what the app-root index cannot: an app dragged to the
    /// Desktop or an external drive, and the copy an updater has staged or set
    /// aside while it swaps bundles.
    static func otherCopyExists(of app: InstalledApp) -> Bool {
        guard let bundleID = app.bundleID, !bundleID.isEmpty else { return false }
        let candidates = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        return candidates.contains { countsAsOtherCopy($0, of: app) }
    }

    /// A Launch Services hit counts when it is really on disk, is not the path the
    /// app left, is not in a Trash, and is not on a read-only volume (a mounted
    /// installer disk image still carries the app the user just deleted).
    static func countsAsOtherCopy(_ url: URL, of app: InstalledApp) -> Bool {
        let path = normalizedPath(url.standardizedFileURL.path)
        guard path != normalizedPath(app.id) else { return false }
        guard !isInTrash(path: path) else { return false }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return !readOnly
    }

    /// Inside any Trash: the home Trash, a volume's `.Trashes`, or iCloud Drive's.
    static func isInTrash(path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    // MARK: Identity

    /// The file-system number of the item at `path`. A move to the Trash on the same
    /// volume keeps it, so it identifies the trashed bundle even after Finder renames
    /// it to avoid a clash with an older copy.
    static func fileNumber(atPath path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    /// Classifies a departure from the path a handle on the bundle reports now.
    /// A handle on a deleted item still reports its last path, so the item there
    /// only counts when it is the same file (`fileNumber`); a path that is empty
    /// or now holds a replacement means the bundle itself is gone.
    static func departureKind(currentPath: String?, fileNumber: UInt64?) -> DepartureKind {
        guard let currentPath, let fileNumber,
              Self.fileNumber(atPath: currentPath) == fileNumber
        else { return .deleted }
        return isInTrash(path: currentPath) ? .trashed : .movedElsewhere
    }

    /// The bundle in `trashDirectory` that is the same file as the one that left.
    /// Never a match by name: a stale copy of the same app from an earlier delete
    /// must not stand in for this one.
    static func trashedCopy(fileNumber: UInt64?, in trashDirectory: URL) -> URL? {
        guard let fileNumber else { return nil }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: trashDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.first {
            $0.pathExtension == "app" && Self.fileNumber(atPath: $0.path) == fileNumber
        }
    }

    // MARK: Records

    /// Checks a removal record before Purge acts on it. The record is a file any
    /// process running as the user could write, so its path must be a bundle the
    /// watcher could really have indexed, its identifier must look like one, and its
    /// name must be short plain text.
    static func isValidRecord(path: String, bundleID: String, name: String, roots: [String]) -> Bool {
        let normalized = normalizedPath(path)
        guard normalized.hasSuffix(".app"), !normalized.contains("/../"), !normalized.contains("/./") else {
            return false
        }
        let parent = (normalized as NSString).deletingLastPathComponent
        let grandparent = (parent as NSString).deletingLastPathComponent
        guard roots.contains(parent) || roots.contains(grandparent) else { return false }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard (1...255).contains(bundleID.count),
              bundleID.unicodeScalars.allSatisfy(allowed.contains),
              bundleID.contains(".")
        else { return false }

        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (1...128).contains(trimmed.count) else { return false }
        return !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// `/Applications` and `~/Applications`, the same roots the uninstaller
    /// enumerates. Duplicated here so the agent binary does not need that policy.
    static func installedAppRoots() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
    }
}
