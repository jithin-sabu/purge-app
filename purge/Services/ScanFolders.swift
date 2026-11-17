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
        isLocalDisk: (URL) -> Bool = { AppFolders.isOnLocalDisk($0) },
        including: (String) -> Bool = { _ in true },
        insideHomeOnly: Bool = false
    ) -> [Entry] {
        var others = fixedRoots(home: home, volumes: volumes, isLocalDisk: isLocalDisk, insideHomeOnly: insideHomeOnly)
        return pickedFolders().filter { including($0.path) }.map { folder in
            // A saved folder in home that became a link out of it is refused by
            // `readlink` alone, before anything could read where it leads (#318
            // review): `refusal` asks `fileExists` first.
            if insideHomeOnly, ProtectedLocations.resolvedStayingInside(folder.path, root: home) == nil {
                return Entry(path: folder.path, refusal: .throughLink)
            }
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
    ///
    /// `insideHomeOnly` is for a scan without Full Disk Access: a folder whose
    /// link, or chain of links, leads out of the home folder is left out by
    /// `readlink` alone, so nothing on another drive is read (#318 review).
    static func fixedRoots(
        home: URL,
        volumes: URL = AppFolders.volumes,
        isLocalDisk: (URL) -> Bool = { AppFolders.isOnLocalDisk($0) },
        insideHomeOnly: Bool = false
    ) -> [URL] {
        LargeFileScanPolicy.scanRoots(home: home).compactMap { root in
            if insideHomeOnly, ProtectedLocations.resolvedStayingInside(root.path, root: home) == nil {
                return nil
            }
            return LargeFileScanPolicy.walkedFolder(for: root, home: home, volumes: volumes, isLocalDisk: isLocalDisk)
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

    // MARK: Inside an added folder

    /// A folder below an added one that Large Files and Developer Projects
    /// never walk into, and whose files and projects their gates refuse (#318
    /// review). The pick itself was judged when it was added, but a whole
    /// drive can hold what no pick could be:
    /// - a copy of a Mac or a Time Machine backup (`System`, `Users`,
    ///   `Backups.backupdb`, `backup_manifest.plist`, a `<date>.backup`);
    /// - a copy of a home folder: `Library` beside `Desktop`, `Documents` or
    ///   `Downloads`. `Library` alone is a Unity project's build folder;
    /// - a folder another sync service keeps.
    static func isOffLimits(_ folder: URL) -> Bool {
        if AppFolders.isTimeMachineBackupName(folder.lastPathComponent) { return true }
        if AppFolders.holdsWholeDisk(folder, markers: AppFolders.driveMarkers) { return true }
        if AppFolders.holdsWholeDisk(folder, markers: ["Library"]),
           AppFolders.holdsWholeDisk(folder, markers: homeCopyMarkers) {
            return true
        }
        return AppFolders.isSyncedByAnotherService(folder)
    }

    /// The same rule from a folder's name and the names in it, for a walk that
    /// has listed the folder already.
    static func isOffLimits(name: String, childNames: Set<String>) -> Bool {
        if AppFolders.isTimeMachineBackupName(name) { return true }
        if AppFolders.driveMarkers.contains(where: childNames.contains) { return true }
        if childNames.contains("Library"), homeCopyMarkers.contains(where: childNames.contains) { return true }
        return AppFolders.syncServiceMarkers.contains(where: childNames.contains)
    }

    /// Whether a folder from just below `root` down to `folder`, both
    /// included, is off limits.
    static func crossesOffLimits(from root: String, to folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        guard PathContainment.isInside(path, root) else { return false }
        var current = root
        for name in path.dropFirst(root.count + 1).split(separator: "/") {
            current += "/" + name
            if isOffLimits(URL(fileURLWithPath: current, isDirectory: true)) { return true }
        }
        return false
    }

    private static let homeCopyMarkers = ["Desktop", "Documents", "Downloads"]

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
    ///
    /// `insideHomeOnly` is for a scan without Full Disk Access: folders
    /// outside the home folder are left out by their saved path, before
    /// anything on their drive is read, so macOS never asks about a removable
    /// volume (#318 review). The saved list comes from the paths alone.
    @discardableResult
    static func refreshSnapshot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        insideHomeOnly: Bool = false
    ) -> [URL] {
        let homePath = home.standardizedFileURL.path
        let saved = pickedFolders().map(\.path)
        let all = entries(home: home, including: { path in
            !insideHomeOnly || PathContainment.isInside(path, homePath)
        }, insideHomeOnly: insideHomeOnly)
        let roots = all.filter(\.isAvailable).map(\.url)
        let next = Snapshot(
            walked: roots.map { $0.standardizedFileURL.path },
            saved: saved
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

    /// The walked folder outside the home folder that holds `path`, or nil.
    /// Only those make a project Check First and keep it out of Clean Safe
    /// Items. A folder added inside home, such as `~/Developer`, holds what
    /// the home rules already cover, and adding it must not change how its
    /// projects clean (#318 review).
    static func addedRootOutsideHome(
        holding path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    ) -> String? {
        snapshot.first { !PathContainment.isSameOrInside($0, home) && PathContainment.isSameOrInside(path, $0) }
    }

    /// Whether `path` is a saved folder outside the home folder or inside one,
    /// walked or not. Clean Safe Items and scheduled cleans drop every such
    /// path, even one on a drive that is unplugged now. Compared by spelling
    /// only, so nothing on disk is read: the caller may be on the main thread,
    /// and without Full Disk Access a `stat` through a link can raise a prompt.
    static func isInsideSavedFolder(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    ) -> Bool {
        savedSnapshot.contains { !PathContainment.isSameOrInside($0, home) && PathContainment.isSameOrInside(path, $0) }
    }

    struct Snapshot: Equatable, Sendable {
        var walked: [String]
        var saved: [String]
    }

    /// Tests bind this instead of saving a list.
    @TaskLocal static var snapshotOverride: Snapshot?

    private static let snapshotStore = OSAllocatedUnfairLock<Snapshot>(initialState: Snapshot(walked: [], saved: []))
}
