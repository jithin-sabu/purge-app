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

nonisolated enum CleanFailureReason: Equatable, Error {
    case needsFullDiskAccess
    case needsAdministrator
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
    case unknown

    var explanation: String {
        switch self {
        case .needsFullDiskAccess:
            String(localized: "Purge needs Full Disk Access to remove this.")
        case .needsAdministrator:
            String(localized: "This app was installed by an administrator, so macOS won't let it be moved on its own. Set up secure removal once and Purge can finish it.")
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
        case .inUse, .unknown, .needsAdministrator, .xcodeLicenseNotAccepted:
            true
        case .needsFullDiskAccess, .systemProtected, .safetySkipped, .keptForOtherApp,
             .simulatorServiceNeedsRestart, .simulatorToolsMissing:
            false
        }
    }

    /// The retry button's label. The administrator case says what the tap will do —
    /// summon the password prompt — rather than the bare "Retry" that fits the
    /// transient failures.
    var retryTitle: String {
        self == .needsAdministrator ? String(localized: "Set Up Secure Removal") : String(localized: "Retry")
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

struct CleanFailureItem: Identifiable, Equatable {
    let id: UUID
    let path: String
    let displayName: String
    let reason: CleanFailureReason
    let sizeBytes: Int64

    init(
        id: UUID = UUID(),
        path: String,
        displayName: String,
        reason: CleanFailureReason,
        sizeBytes: Int64 = 0
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.reason = reason
        self.sizeBytes = sizeBytes
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
            sizeBytes: failed.sizeBytes
        )
    }

    init(skipped: SkippedDeletionItem) {
        self.init(
            id: skipped.id,
            path: skipped.path,
            displayName: skipped.displayName,
            reason: .safetySkipped,
            sizeBytes: 0
        )
    }
}

extension DeletionReport {
    var userVisibleFailures: [CleanFailureItem] {
        let failed = failedItems.map(CleanFailureItem.init(failed:))
        let skipped = skippedItems.lazy.filter(\.isUserVisible).map(CleanFailureItem.init(skipped:))
        return failed + skipped
    }
}
