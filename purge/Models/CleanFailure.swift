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
    case inUse
    case systemProtected
    case safetySkipped
    case unknown

    var explanation: String {
        switch self {
        case .needsFullDiskAccess:
            "Purge needs Full Disk Access to remove this."
        case .inUse:
            "An app is still using this. Quit it and clean again."
        case .systemProtected:
            "macOS protects this one and won't let it be removed."
        case .safetySkipped:
            "Purge left this one alone to stay on the safe side."
        case .unknown:
            "This one couldn't be removed. Try again."
        }
    }

    var systemImage: String {
        switch self {
        case .needsFullDiskAccess:
            "lock.fill"
        case .inUse:
            "app.badge.fill"
        case .systemProtected:
            "lock.shield.fill"
        case .safetySkipped:
            "hand.raised.fill"
        case .unknown:
            "exclamationmark.circle.fill"
        }
    }

    var showsOpenSettings: Bool {
        self == .needsFullDiskAccess
    }

    var showsRetry: Bool {
        self == .inUse || self == .unknown
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

    /// Maps a deletion error to a user-facing reason. When Full Disk Access is
    /// already granted a permission error clearly isn't about FDA — but that on
    /// its own says nothing about macOS protecting the file, so we only claim
    /// protection when the file — or the directory holding it — really is
    /// immutable or SIP-marked. Anything else is honestly unknown, and offering
    /// a retry beats inventing a cause.
    static func resolved(
        from error: Error,
        path: String,
        fullDiskAccessGranted: Bool
    ) -> CleanFailureReason? {
        guard let reason = from(error: error) else { return nil }
        guard fullDiskAccessGranted, reason == .needsFullDiskAccess else { return reason }
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
