import Foundation

enum CleanFailureReason: Equatable, Error {
    case needsFullDiskAccess
    case inUse
    case systemProtected
    case unknown

    var explanation: String {
        switch self {
        case .needsFullDiskAccess:
            "Purge needs Full Disk Access to remove this."
        case .inUse:
            "An app is still using this. Quit it and clean again."
        case .systemProtected:
            "macOS protects this one and won't let it be removed."
        case .unknown:
            "This one couldn't be removed."
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

    /// Maps a deletion error to a user-facing reason, upgrading permission errors to
    /// `systemProtected` when Full Disk Access is already granted.
    static func resolved(from error: Error, fullDiskAccessGranted: Bool) -> CleanFailureReason? {
        guard let reason = from(error: error) else { return nil }
        if fullDiskAccessGranted, reason == .needsFullDiskAccess {
            return .systemProtected
        }
        return reason
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
            reason: .systemProtected,
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
