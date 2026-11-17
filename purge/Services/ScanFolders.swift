import Foundation
import os

/// Folders the user adds in Settings for Large Files and Dev Projects to walk
/// too (#318), most often on a drive that stays plugged in.
///
/// What is found there is the user's own data, so it only reaches features
/// where the user picks each row. Large Files' gate takes a file under an
/// added folder, and `evaluate` takes a project artifact under one, but the
/// rows are Check First and `PurgeStore.manualSafeCleanupCandidates` drops any
/// path inside an added folder, so Clean Safe Items and scheduled cleans never
/// reach them.
///
/// The rules are the uninstaller's (`AppFolders.refusal(forPicked:)`), with one
/// difference: a whole drive may be added, as long as it is not a copy of a Mac
/// or a Time Machine drive. Only disks attached to this Mac count, so a network
/// share or a macFUSE mount is refused.
nonisolated enum ScanFolders {
    /// One saved folder, as it reads now.
    struct Entry: Equatable, Sendable, Identifiable {
        var id: String { path }
        let path: String
        /// Nil when the folder is walked. `.notAFolder` most often means its
        /// drive is unplugged: the folder stays saved and is skipped, never read
        /// as empty.
        let refusal: AppFolders.Refusal?

        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
        var isAvailable: Bool { refusal == nil }
        var isDisconnected: Bool { refusal == .notAFolder }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// Next to the uninstaller's list.
    static var file: URL {
        RemovedAppHandoff.root.appendingPathComponent("scan-folders.json", isDirectory: false)
    }

    /// The folders the user added, whether or not they are there now.
    static func pickedFolders() -> [AppFolders.PickedFolder] {
        AppFolders.pickedFolders(in: file)
    }

    /// Every saved folder, each judged again from disk. A folder is checked
    /// against Large Files' own folders and the saved folders before it, so
    /// two saved folders never overlap.
    static func entries(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumes: URL = AppFolders.volumes,
        isLocalDisk: (URL) -> Bool = { AppFolders.isOnLocalDisk($0) }
    ) -> [Entry] {
        var others = fixedRoots(home: home, volumes: volumes, isLocalDisk: isLocalDisk)
        return pickedFolders().map { folder in
            let url = URL(fileURLWithPath: folder.path, isDirectory: true)
            let refusal = refusal(forPicked: url, home: home, otherRoots: others, volumes: volumes, isLocalDisk: isLocalDisk)
            if refusal == nil { others.append(url) }
            return Entry(path: folder.path, refusal: refusal)
        }
    }

    /// The saved folders that are walked right now.
    static func roots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumes: URL = AppFolders.volumes,
        isLocalDisk: (URL) -> Bool = { AppFolders.isOnLocalDisk($0) }
    ) -> [URL] {
        entries(home: home, volumes: volumes, isLocalDisk: isLocalDisk).filter(\.isAvailable).map(\.url)
    }

    /// Large Files' six home folders, each where it is walked (a moved folder
    /// is walked where its link leads, #273). Adding one of them, or a folder
    /// inside one, adds nothing.
    static func fixedRoots(
        home: URL,
        volumes: URL = AppFolders.volumes,
        isLocalDisk: (URL) -> Bool = { AppFolders.isOnLocalDisk($0) }
    ) -> [URL] {
        LargeFileScanPolicy.scanRoots(home: home).compactMap {
            LargeFileScanPolicy.walkedFolder(for: $0, home: home, volumes: volumes, isLocalDisk: isLocalDisk)
        }
    }

    static func refusal(
        forPicked folder: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        otherRoots: [URL],
        volumes: URL = AppFolders.volumes,
        isLocalDisk: (URL) -> Bool = { AppFolders.isOnLocalDisk($0) }
    ) -> AppFolders.Refusal? {
        AppFolders.refusal(
            forPicked: folder,
            home: home,
            otherRoots: otherRoots,
            volumes: volumes,
            isLocalDisk: isLocalDisk,
            allowsWholeDrive: true
        )
    }

    /// Adds `folder` unless `refusal(forPicked:)` refuses it. Returns the
    /// refusal, or nil once it is saved. `saveFailed` is true when it passed
    /// but the list could not be written.
    @discardableResult
    static func add(
        _ folder: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumes: URL = AppFolders.volumes,
        isLocalDisk: (URL) -> Bool = { AppFolders.isOnLocalDisk($0) },
        date: Date = Date()
    ) -> (refusal: AppFolders.Refusal?, saveFailed: Bool) {
        let others = fixedRoots(home: home, volumes: volumes, isLocalDisk: isLocalDisk)
            + roots(home: home, volumes: volumes, isLocalDisk: isLocalDisk)
        if let refusal = refusal(forPicked: folder, home: home, otherRoots: others, volumes: volumes, isLocalDisk: isLocalDisk) {
            return (refusal, false)
        }
        var folders = pickedFolders()
        folders.append(AppFolders.PickedFolder(path: folder.standardizedFileURL.path, dateAdded: date))
        return (nil, !AppFolders.save(folders, to: file))
    }

    /// Returns false when the list could not be saved.
    @discardableResult
    static func remove(path: String) -> Bool {
        let folders = pickedFolders()
        let kept = folders.filter { $0.path != path }
        guard kept.count != folders.count else { return true }
        return AppFolders.save(kept, to: file)
    }

    // MARK: Snapshot

    /// The walked folders as last read, for `DeletionSafetyPolicy.evaluate`,
    /// which runs for every scanned item and must never read the list from
    /// disk. Refreshed when the list changes, when a drive comes or goes, at
    /// the start of each Dev Projects scan and before each clean. Empty in the
    /// test host until a test binds `snapshotOverride`.
    static var snapshot: [String] {
        if let snapshotOverride { return snapshotOverride.walked }
        return snapshotStore.withLock { $0.walked }
    }

    /// Every saved folder as last read, walked or not, such as one on a drive
    /// that is unplugged now.
    static var savedSnapshot: [String] {
        if let snapshotOverride { return snapshotOverride.saved }
        return snapshotStore.withLock { $0.saved }
    }

    /// Reads the list from disk and keeps the folders' paths. Off the main
    /// thread: it asks each folder's disk about its file system.
    @discardableResult
    static func refreshSnapshot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let all = entries(home: home)
        let roots = all.filter(\.isAvailable).map(\.url)
        let next = Snapshot(
            walked: roots.map { $0.standardizedFileURL.path },
            saved: all.map(\.path)
        )
        let changed = snapshotStore.withLock { stored -> Bool in
            defer { stored = next }
            return stored != next
        }
        // `isOfferedForCleanup` keeps `evaluate`'s answers, which read this list.
        if changed { DeletionSafetyPolicy.clearOfferedForCleanupCache() }
        return roots
    }

    /// The walked folder that holds `path`, or nil.
    static func snapshotRoot(holding path: String) -> String? {
        snapshot.first { PathContainment.isSameOrInside(path, $0) }
    }

    /// Whether `path` is a saved folder or inside one, walked or not. Clean
    /// Safe Items and scheduled cleans drop every such path, even one on a
    /// drive that is unplugged now. Compared by spelling only, so nothing on
    /// disk is read: the caller may be on the main thread, and without Full
    /// Disk Access a `stat` through a link can raise a prompt.
    static func isInsideSavedFolder(_ path: String) -> Bool {
        savedSnapshot.contains { PathContainment.isSameOrInside(path, $0) }
    }

    struct Snapshot: Equatable, Sendable {
        var walked: [String]
        var saved: [String]
    }

    /// Tests bind this instead of saving a list.
    @TaskLocal static var snapshotOverride: Snapshot?

    private static let snapshotStore = OSAllocatedUnfairLock<Snapshot>(initialState: Snapshot(walked: [], saved: []))
}
