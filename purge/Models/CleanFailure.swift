import Foundation

/// Whether the filesystem itself will refuse to give a file up, no matter what
/// permissions Purge holds. This is the only thing that justifies telling
/// someone macOS protects a file — an ordinary permission error does not.
nonisolated enum FileProtection {
    static func isImmutable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUserImmutableKey, .isSystemImmutableKey])
        return values?.isUserImmutable == true || values?.isSystemImmutable == true
    }

    /// SIP marks its own files with a `com.apple.rootless` xattr.
    static func isRootlessProtected(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return false }
            return getxattr(pointer, "com.apple.rootless", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    /// Removing a file means unlinking it from its directory, so an immutable
    /// *parent* refuses the removal even when the file itself looks ordinary —
    /// verified: `trashItem` then fails with `NSFileWriteNoPermissionError`
    /// while the file still reports as mutable.
    ///
    /// The parent is checked for immutability only, deliberately. A directory
    /// can carry `com.apple.rootless` and still hand its contents over freely —
    /// the per-user temp directory is marked `com.apple.rootless: folders` and
    /// files inside it trash without complaint. Testing the parent for rootless
    /// would condemn every one of them.
    static func blocksRemoval(_ url: URL) -> Bool {
        if isImmutable(url) || isRootlessProtected(url) { return true }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return false }
        return isImmutable(parent)
    }
}

/// The raw values are saved in Cleanup History (#303), so renaming a case turns
/// its old entries into `.unknown`.
nonisolated enum CleanFailureReason: String, Equatable, Error {
    case needsFullDiskAccess
    case needsAdministrator
    /// The helper is on, the account using Purge is not an administrator, and no
    /// administrator approved the move: the password dialog was cancelled (#182,
    /// #299, #314).
    case needsAdministratorAccount
    case inUse
    case systemProtected
    case safetySkipped
    case keptForOtherApp
    /// Xcode was updated and its license waits to be accepted, so `simctl` won't run.
    case xcodeLicenseNotAccepted
    /// CoreSimulator's service is older than the installed Xcode, until a restart.
    case simulatorServiceNeedsRestart
    /// No `simctl` on this Mac could be run, so nothing can remove a simulator.
    case simulatorToolsMissing
    /// An app on a drive or in a folder the user added that macOS would not let
    /// Purge move. The root helper takes apps only from the two Applications
    /// folders, so it can't move this one either (#99).
    case moveInFinder
    case unknown

    var explanation: String {
        switch self {
        case .needsFullDiskAccess:
            String(localized: "Purge needs Full Disk Access to remove this.")
        case .needsAdministrator:
            String(localized: "This app was installed by an administrator, so macOS won't let it be moved on its own. Set up secure removal once and Purge can finish it.")
        case .needsAdministratorAccount:
            String(localized: "An administrator installed this, so removing it takes an administrator's name and password.")
        case .inUse:
            String(localized: "An app is still using this. Quit it and clean again.")
        case .systemProtected:
            String(localized: "macOS protects this one and won't let it be removed.")
        case .safetySkipped:
            String(localized: "Purge left this one alone to stay on the safe side.")
        case .keptForOtherApp:
            String(localized: "Another app you still have installed uses this too, so Purge kept it.")
        case .xcodeLicenseNotAccepted:
            String(localized: "Open Xcode once to accept its license, then try again.")
        case .simulatorServiceNeedsRestart:
            String(localized: "Apple's simulator service is out of date. Restart your Mac, then clean again.")
        case .simulatorToolsMissing:
            String(localized: "Apple's simulator tools aren't working on this Mac, so Purge can't remove simulators. Reinstalling Xcode fixes this.")
        case .moveInFinder:
            String(localized: "macOS won't let Purge move this app from where it is. Drag it to the Trash in Finder, then retry to remove what it left behind.")
        case .unknown:
            String(localized: "This one couldn't be removed. Try again.")
        }
    }

    var systemImage: String {
        switch self {
        case .needsFullDiskAccess:
            "lock.fill"
        case .needsAdministrator:
            "lock.fill"
        case .needsAdministratorAccount:
            "person.badge.key.fill"
        case .inUse:
            "app.badge.fill"
        case .systemProtected:
            "lock.shield.fill"
        case .safetySkipped:
            "hand.raised.fill"
        case .keptForOtherApp:
            "square.on.square"
        case .xcodeLicenseNotAccepted:
            "hammer.fill"
        case .simulatorServiceNeedsRestart:
            "arrow.clockwise.circle.fill"
        case .simulatorToolsMissing:
            "hammer.fill"
        case .moveInFinder:
            "externaldrive.fill"
        case .unknown:
            "exclamationmark.circle.fill"
        }
    }

    var showsOpenSettings: Bool {
        self == .needsFullDiskAccess
    }

    /// Only where tapping it can work while the result is still on screen. Accepting
    /// the Xcode license takes a minute; a restart or a reinstall does not fit.
    var showsRetry: Bool {
        switch self {
        case .inUse, .unknown, .needsAdministrator, .needsAdministratorAccount, .xcodeLicenseNotAccepted,
             .moveInFinder:
            true
        case .needsFullDiskAccess, .systemProtected, .safetySkipped, .keptForOtherApp,
             .simulatorServiceNeedsRestart, .simulatorToolsMissing:
            false
        }
    }

    /// The retry button's label. The administrator cases say what the tap will do —
    /// set up the helper, or show the administrator dialog (#314) — rather than the bare
    /// "Retry" that fits the transient failures.
    var retryTitle: String {
        switch self {
        case .needsAdministrator:
            String(localized: "Set Up Secure Removal")
        case .needsAdministratorAccount:
            String(localized: "Enter Password")
        case .needsFullDiskAccess, .inUse, .systemProtected, .safetySkipped, .keptForOtherApp,
             .xcodeLicenseNotAccepted, .simulatorServiceNeedsRestart, .simulatorToolsMissing,
             .moveInFinder, .unknown:
            String(localized: "Retry")
        }
    }

    /// Returns `nil` for file-not-found / already-gone errors that should be dropped silently.
    static func from(error: Error) -> CleanFailureReason? {
        let ns = error as NSError
        if isFileNotFound(ns) { return nil }

        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .needsFullDiskAccess
            case NSFileWriteVolumeReadOnlyError:
                return .systemProtected
            case NSFileLockingError:
                return .inUse
            default:
                break
            }
        }

        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(EACCES), Int(EPERM):
                return .needsFullDiskAccess
            case Int(EBUSY):
                return .inUse
            case Int(EROFS):
                return .systemProtected
            default:
                break
            }
        }

        let message = error.localizedDescription.lowercased()
        if message.contains("busy") || message.contains("in use") {
            return .inUse
        }
        if message.contains("read-only") || message.contains("read only") {
            return .systemProtected
        }

        return .unknown
    }

    /// Reads a failed `simctl` call: `nil` when none could be launched. Texts that
    /// name no known cause, and timeouts, stay `.unknown`.
    static func fromSimctl(_ output: ProcessRunner.Output?) -> CleanFailureReason {
        guard let output else { return .simulatorToolsMissing }
        if output.timedOut { return .unknown }
        let text = output.stderrText.lowercased()
        if Simctl.mentionsXcodeLicense(text) { return .xcodeLicenseNotAccepted }
        // "CoreSimulator is out of date. Current version (…) is older than build
        // version (…)", and the dropped connection that comes with it.
        if text.contains("coresimulator is out of date")
            || text.contains("coresimulatorservice connection became invalid") {
            return .simulatorServiceNeedsRestart
        }
        if Simctl.xcrunRefused(output) { return .simulatorToolsMissing }
        return .unknown
    }

    /// Maps a deletion error to a user-facing reason. When Full Disk Access is
    /// already granted a permission error clearly isn't about FDA — but that on
    /// its own says nothing about macOS protecting the file, so we only claim
    /// protection when the file — or the directory holding it — really is
    /// immutable or SIP-marked. Anything else is honestly unknown, and offering
    /// a retry beats inventing a cause.
    ///
    /// `fullDiskAccessGranted` probes the disk, so it is only asked for a
    /// permission error.
    static func resolved(
        from error: Error,
        path: String,
        fullDiskAccessGranted: @autoclosure () -> Bool
    ) -> CleanFailureReason? {
        guard let reason = from(error: error) else { return nil }
        guard reason == .needsFullDiskAccess, fullDiskAccessGranted() else { return reason }
        return FileProtection.blocksRemoval(URL(fileURLWithPath: path)) ? .systemProtected : .unknown
    }

    private static func isFileNotFound(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
            return true
        }
        return false
    }
}

/// Which `FileDeleter` route tried an item, kept on its failure so Retry goes back
/// through the same gate (#174). A retry can then never remove more than the first
/// attempt could: the cache route answers to `DeletionSafetyPolicy.evaluate`, the
/// user-selected route to the four policy gates, with the flags the first call set.
nonisolated enum DeletionRoute: Hashable, Sendable {
    /// `FileDeleter.deleteItems`: caches, Dev Tools, simulators and runtimes.
    case cache
    /// `FileDeleter.deleteUserSelectedFiles`, with the flags that call passed for
    /// this path. `isAIModel` keeps a model component on the model gate alone (#157);
    /// `privilegedEligible` lets the helper move it when the plain move fails.
    case userSelected(isAIModel: Bool, privilegedEligible: Bool)
    /// The one "needs your OK" row for a held app, finished bundle first by
    /// `PurgeStore.completeLockedUninstall`. Never retried by `FileDeleter` itself.
    case lockedUninstall
}

struct CleanFailureItem: Identifiable, Equatable {
    let id: UUID
    let path: String
    let displayName: String
    let reason: CleanFailureReason
    let sizeBytes: Int64
    let route: DeletionRoute

    init(
        id: UUID = UUID(),
        path: String,
        displayName: String,
        reason: CleanFailureReason,
        sizeBytes: Int64 = 0,
        route: DeletionRoute = .cache
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.reason = reason
        self.sizeBytes = sizeBytes
        self.route = route
    }

    /// The same row with the reason a retry just came back with. Keeps the id, so
    /// the list does not rebuild the row.
    func replacingReason(_ reason: CleanFailureReason) -> CleanFailureItem {
        CleanFailureItem(
            id: id,
            path: path,
            displayName: displayName,
            reason: reason,
            sizeBytes: sizeBytes,
            route: route
        )
    }

    /// A whole app Purge couldn't move, for a reason Finder can still get past: an
    /// administrator's password, a quit app, or a second try. Not a protected or
    /// skipped one, and not one waiting on setup, which has its own panel (#299).
    var offersFinderRemoval: Bool {
        guard route == .lockedUninstall else { return false }
        switch reason {
        case .needsAdministratorAccount, .inUse, .moveInFinder, .unknown:
            return true
        case .needsFullDiskAccess, .needsAdministrator, .systemProtected, .safetySkipped, .keptForOtherApp,
             .xcodeLicenseNotAccepted, .simulatorServiceNeedsRestart, .simulatorToolsMissing:
            return false
        }
    }

    /// An entry a finished macOS update left in `macOS Install Data` (#127). These go
    /// through the helper together, never one by one. Read in view bodies, so it
    /// checks the string only: the clean already standardized every path.
    var isMacOSInstallLeftover: Bool {
        MacOSInstallLeftovers.isEntryPath(path)
    }

    init(failed: FailedDeletionItem) {
        self.init(
            id: failed.id,
            path: failed.path,
            displayName: failed.displayName,
            reason: failed.reason,
            sizeBytes: failed.sizeBytes,
            route: failed.route
        )
    }

    init(skipped: SkippedDeletionItem) {
        self.init(
            id: skipped.id,
            path: skipped.path,
            displayName: skipped.displayName,
            reason: .safetySkipped,
            sizeBytes: 0,
            route: skipped.route
        )
    }
}

extension DeletionReport {
    var userVisibleFailures: [CleanFailureItem] {
        let failed = failedItems.map(CleanFailureItem.init(failed:))
        let skipped = skippedItems.lazy.filter(\.isUserVisible).map(CleanFailureItem.init(skipped:))
        return failed + skipped
    }

    /// The same report with more failed items, for a caller that keeps some
    /// failures outside the engine's report, as the uninstaller does for held apps.
    func addingFailures(_ items: [CleanFailureItem]) -> DeletionReport {
        guard !items.isEmpty else { return self }
        var report = DeletionReport(
            bytesMovedToTrash: bytesMovedToTrash,
            bytesRemovedDirectly: bytesRemovedDirectly,
            deletedItems: deletedItems,
            failedItems: failedItems + items.map {
                FailedDeletionItem(path: $0.path, displayName: $0.displayName, reason: $0.reason, sizeBytes: $0.sizeBytes, route: $0.route)
            },
            skippedItems: skippedItems,
            capacityBefore: capacityBefore,
            capacityAfter: capacityAfter,
            timestamp: timestamp
        )
        report.ownershipWarningPaths = ownershipWarningPaths
        report.keptRuntimeDownloads = keptRuntimeDownloads
        return report
    }
}
