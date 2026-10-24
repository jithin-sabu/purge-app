import Foundation

/// Whether Purge may remove the download of an iCloud file: drop the copy on
/// this Mac and keep the file in iCloud, where opening it downloads it again
/// (#106). Finder calls this Remove Download.
///
/// Nothing is deleted. `FileManager.evictUbiquitousItem(at:)` turns the file
/// into a placeholder at the same path. The one way it loses data is evicting a
/// file whose latest version has not reached iCloud, so every check here is about
/// that, and each runs again right before the eviction, not only at scan time.
///
/// This is deletion-safety code. Remove Download is only for files the user
/// picks in Large Files. It never feeds Clean Safe Items or scheduled cleans.
nonisolated enum ICloudDownloadDecision: Equatable, Sendable {
    case removable
    /// Not under a folder Large Files walks.
    case outsideLargeFiles
    /// Gone, a folder, or a link.
    case notAFile
    /// A hard link: the file has another name on this disk. Eviction acts on
    /// the file's data, so the other name, which may sit outside iCloud and be
    /// open, would become a placeholder too.
    case hasOtherLinks
    case notInICloud
    case hasConflicts
    /// iCloud does not have this version yet.
    case notUploaded
    /// Nothing on this Mac to remove, or only an older version.
    case notDownloaded
    /// macOS has not marked the copy as safe to drop. A file set to Keep
    /// Downloaded, or one that shares its blocks with another file, stays.
    case keptOnThisMac
    /// Changed within `ICloudDownloadPolicy.quietPeriod`, so it may still be
    /// on its way to iCloud.
    case changedRecently

    /// Why a file was left alone, in English. History stores it as is and
    /// translates it when shown, as it does for every skipped item, so the key
    /// is a plain literal here. `localizedSkipReason` is the shown text.
    var skipReasonKey: String {
        switch self {
        case .removable:
            return ""
        case .outsideLargeFiles, .notAFile:
            return "Purge can't keep this file only in iCloud."
        case .hasOtherLinks:
            return "This file is also linked from another place on this Mac."
        case .notInICloud:
            return "This file isn't stored in iCloud."
        case .hasConflicts:
            return "This file has a sync conflict. Resolve it in Finder first."
        case .notUploaded:
            return "This file isn't fully uploaded to iCloud yet."
        case .notDownloaded:
            return "This file isn't downloaded on this Mac."
        case .keptOnThisMac:
            return "macOS is keeping this file on this Mac, for example because it's set to Keep Downloaded."
        case .changedRecently:
            return "This file changed in the last few minutes and may still be syncing."
        }
    }

    var localizedSkipReason: String {
        Bundle.main.localizedString(forKey: skipReasonKey, value: skipReasonKey, table: nil)
    }
}

/// What the checks read about one file, fresh from disk.
nonisolated struct ICloudDownloadState: Equatable, Sendable {
    var isRegularFile: Bool
    var isUbiquitous: Bool
    var isUploaded: Bool
    var hasConflicts: Bool
    var isDownloadedAndCurrent: Bool
    var allocatedBytes: Int64
    /// APFS `EF_IS_PURGEABLE`. The iCloud and File Provider daemons set it on a
    /// downloaded copy they can drop and fetch again. A copy set to Keep
    /// Downloaded doesn't carry it.
    var isPurgeable: Bool
    var modified: Date?
    /// More than one name for the same file (`st_nlink` above 1).
    var hasOtherLinks = false

    /// Reads the file now, past any cached resource values. Nil when it is gone.
    static func read(_ url: URL) -> ICloudDownloadState? {
        let path = url.standardizedFileURL.path
        // lstat, not the resource values: a link must never stand in for a file.
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let isRegularFile = (info.st_mode & S_IFMT) == S_IFREG
        // A new URL, so no value cached by the scan answers for the file as it is now.
        let fresh = URL(fileURLWithPath: path)
        let values = try? fresh.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemDownloadingStatusKey,
            .totalFileAllocatedSizeKey, .contentModificationDateKey
        ])
        return ICloudDownloadState(
            isRegularFile: isRegularFile,
            isUbiquitous: values?.isUbiquitousItem == true,
            isUploaded: values?.ubiquitousItemIsUploaded == true,
            hasConflicts: values?.ubiquitousItemHasUnresolvedConflicts == true,
            isDownloadedAndCurrent: values?.ubiquitousItemDownloadingStatus == .current,
            allocatedBytes: Int64(values?.totalFileAllocatedSize ?? 0),
            isPurgeable: isRegularFile && hasPurgeableFlag(path),
            modified: values?.contentModificationDate,
            hasOtherLinks: isRegularFile && info.st_nlink > 1
        )
    }

    /// `EF_IS_PURGEABLE` from the file's extended flags, without following a link.
    static func hasPurgeableFlag(_ path: String) -> Bool {
        var request = attrlist(
            bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
            commonattr: 0, volattr: 0, dirattr: 0, fileattr: 0,
            forkattr: attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        )
        // A 4-byte length, then the 8-byte flags, unaligned.
        var buffer = [UInt8](repeating: 0, count: 32)
        let result = getattrlist(
            path, &request, &buffer, buffer.count,
            UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        )
        guard result == 0 else { return false }
        let flags = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        return flags & UInt64(EF_IS_PURGEABLE) != 0
    }
}

nonisolated enum ICloudDownloadPolicy {
    /// How long a file must sit unchanged. iCloud reports a file as uploaded
    /// only once it is, but a save that lands between the check and the
    /// eviction is the one race left, and a few minutes of quiet makes it
    /// unlikely the user is still working on the file.
    static let quietPeriod: TimeInterval = 5 * 60

    /// Remove Download covers the folders Large Files walks and nothing else:
    /// the home folders and iCloud Drive's own folder.
    static func isInScope(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if LargeFileScanPolicy.isInsideExcludedDirectory(url) { return false }
        let roots = LargeFileScanPolicy.scanRoots(home: home) + [LargeFileScanPolicy.iCloudDriveRoot(home: home)]
        return roots.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// The decision for a file as `state` describes it. Pure, so tests can walk
    /// every branch without iCloud.
    static func decision(for state: ICloudDownloadState?, now: Date) -> ICloudDownloadDecision {
        guard let state, state.isRegularFile else { return .notAFile }
        guard !state.hasOtherLinks else { return .hasOtherLinks }
        guard state.isUbiquitous else { return .notInICloud }
        guard !state.hasConflicts else { return .hasConflicts }
        guard state.isUploaded else { return .notUploaded }
        guard state.isDownloadedAndCurrent, state.allocatedBytes > 0 else { return .notDownloaded }
        guard state.isPurgeable else { return .keptOnThisMac }
        // A file with no date, or one dated in the future, has not sat quietly.
        guard let modified = state.modified, now.timeIntervalSince(modified) >= quietPeriod else {
            return .changedRecently
        }
        return .removable
    }

    /// Scope first, so nothing outside Large Files' folders is even read.
    static func evaluate(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        readState: (URL) -> ICloudDownloadState? = ICloudDownloadState.read
    ) -> (decision: ICloudDownloadDecision, state: ICloudDownloadState?) {
        guard isInScope(url, home: home) else { return (.outsideLargeFiles, nil) }
        let state = readState(url)
        return (decision(for: state, now: now), state)
    }
}
