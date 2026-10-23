import Foundation

/// One file whose download was removed. It is still in iCloud and still at
/// `path`, as a placeholder.
nonisolated struct ICloudDownloadRemoval: Hashable, Sendable {
    let path: String
    /// Measured: what the file used on disk before, less what it uses after.
    let bytesFreed: Int64
}

nonisolated struct ICloudDownloadSkip: Hashable, Sendable {
    let path: String
    /// English, translated when shown. See `ICloudDownloadDecision.skipReasonKey`.
    let reasonKey: String

    var localizedReason: String {
        Bundle.main.localizedString(forKey: reasonKey, value: reasonKey, table: nil)
    }
}

nonisolated struct ICloudDownloadReport: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let removed: [ICloudDownloadRemoval]
    let skipped: [ICloudDownloadSkip]

    var bytesFreed: Int64 {
        removed.reduce(Int64(0)) { $0 + $1.bytesFreed }
    }
}

/// Removes the downloads of iCloud files the user picked in Large Files (#106).
/// Each file passes `ICloudDownloadPolicy` again here, read fresh from disk,
/// then `FileManager.evictUbiquitousItem(at:)` drops the local copy. Nothing
/// goes to the Trash and nothing is deleted: the file stays in iCloud and in
/// its folder, and opening it downloads it again.
///
/// Only `PurgeStore.confirmRemoveDownloads` calls this, after the user picked
/// the rows and confirmed. Clean Safe Items and scheduled cleans never do.
nonisolated final class ICloudDownloadRemover: Sendable {
    typealias Evict = @Sendable (URL) throws -> Void
    typealias ReadState = @Sendable (URL) -> ICloudDownloadState?

    private let home: URL
    private let readState: ReadState
    private let evict: Evict
    /// The user's open files, as `lsof` lists them. See `OpenFileCheck`.
    private let listOpenFiles: OpenFileCheck.Lister
    private let now: @Sendable () -> Date
    /// How long to wait for the space to show as free after the last eviction.
    /// iCloud drops the copy before `evict` returns in practice (0.5 s in the
    /// #106 test); this only covers a slow one, so the freed figure isn't 0.
    private let settleAttempts: Int
    private let settleInterval: Duration

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        readState: @escaping ReadState = { ICloudDownloadState.read($0) },
        evict: @escaping Evict = { try FileManager.default.evictUbiquitousItem(at: $0) },
        listOpenFiles: @escaping OpenFileCheck.Lister = OpenFileCheck.liveListing,
        now: @escaping @Sendable () -> Date = { Date() },
        settleAttempts: Int = 6,
        settleInterval: Duration = .milliseconds(500)
    ) {
        self.home = home
        self.readState = readState
        self.evict = evict
        self.listOpenFiles = listOpenFiles
        self.now = now
        self.settleAttempts = settleAttempts
        self.settleInterval = settleInterval
    }

    @concurrent func removeDownloads(at urls: [URL]) async -> ICloudDownloadReport {
        var seen = Set<String>()
        var ready: [(path: String, state: ICloudDownloadState)] = []
        var evicted: [(path: String, before: Int64)] = []
        var skipped: [ICloudDownloadSkip] = []

        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if Task.isCancelled { break }
            let (decision, state) = ICloudDownloadPolicy.evaluate(
                URL(fileURLWithPath: path), home: home, now: now(), readState: readState
            )
            guard decision == .removable, let state else {
                skipped.append(ICloudDownloadSkip(path: path, reasonKey: decision.skipReasonKey))
                continue
            }
            ready.append((path, state))
        }

        // A file an app has open stays: the app may still be writing it, or
        // reading it, and its copy must not turn into a placeholder under it.
        // One listing covers every file. When it can't be read nothing is
        // removed, since an empty answer is no proof that nothing is open.
        let listing = ready.isEmpty ? "" : listOpenFiles()
        for (path, state) in ready {
            if Task.isCancelled { break }
            guard let listing else {
                skipped.append(ICloudDownloadSkip(path: path, reasonKey: Self.openCheckUnavailableReasonKey))
                continue
            }
            let spellings = Set(OpenFileCheck.spellings(of: URL(fileURLWithPath: path)))
            guard OpenFileCheck.holders(in: listing, folders: spellings).isEmpty else {
                skipped.append(ICloudDownloadSkip(path: path, reasonKey: Self.openInAppReasonKey))
                continue
            }
            do {
                try evict(URL(fileURLWithPath: path))
                evicted.append((path, state.allocatedBytes))
            } catch {
                skipped.append(ICloudDownloadSkip(path: path, reasonKey: Self.evictFailedReasonKey))
            }
        }

        // Measured after, not assumed from the scan: the figure is what the
        // disk got back.
        // A file that can't be read afterwards counts as nothing freed, never as
        // all of it.
        var after: [String: Int64] = [:]
        for attempt in 0..<max(settleAttempts, 1) {
            after = Dictionary(uniqueKeysWithValues: evicted.map { item in
                (item.path, readState(URL(fileURLWithPath: item.path))?.allocatedBytes ?? item.before)
            })
            if after.values.allSatisfy({ $0 == 0 }) || attempt >= settleAttempts - 1 { break }
            try? await Task.sleep(for: settleInterval)
        }

        let removed = evicted.map { item in
            ICloudDownloadRemoval(path: item.path, bytesFreed: max(0, item.before - (after[item.path] ?? item.before)))
        }
        return ICloudDownloadReport(date: now(), removed: removed, skipped: skipped)
    }

    static let evictFailedReasonKey = "macOS couldn't remove the download of this file."
    static let openInAppReasonKey = "This file is open in an app. Quit the app, then try again."
    static let openCheckUnavailableReasonKey = "Purge couldn't check whether an app has this file open."
}
