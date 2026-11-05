import Foundation

/// The folders the App Uninstaller lists apps from (#99): `/Applications` and
/// `~/Applications`, the `Applications` folder at the top of each drive attached
/// to this Mac, and the folders the user adds in Settings.
///
/// The picker, the delete gate, the Finder service check, the removal watcher
/// and the orphan index all read this one list, and `AppBundleReach` says how
/// deep inside each folder they look. The watch agent compiles this file too,
/// so it uses Foundation only. The root helper does not: it moves bundles into
/// `~/.Trash` with a rename, which can't reach another volume, so it keeps the
/// two built-in folders.
nonisolated enum AppFolders {
    /// Where drives are mounted. Tests bind it to a temporary folder with
    /// `AppFolders.$volumes.withValue`, so they never read the real drives.
    @TaskLocal static var volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)

    /// Every folder the uninstaller lists apps from right now: the built-in
    /// two, then each attached drive's, then each folder the user added that
    /// is there and still passes `refusal(forPicked:)`. A drive that is
    /// unplugged adds nothing.
    static func roots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var result = builtInRoots(home: home) + driveRoots()
        for folder in pickedFolders() {
            let url = URL(fileURLWithPath: folder.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard refusal(forPicked: url, home: home, otherRoots: result) == nil else { continue }
            result.append(url)
        }
        return result
    }

    /// `/Applications` and `~/Applications`. `/System/Applications` is left
    /// out on purpose, so Apple's own apps are never listed.
    static func builtInRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    // MARK: Drives

    /// The `Applications` folder at the top of each drive that is attached to
    /// this Mac and can be written to. Left out:
    /// - the startup disk's entry, which is a link to `/`;
    /// - a network share or a cloud drive mounted as a disk, where a move to
    ///   the Trash can delete on every device;
    /// - a read-only volume, such as an installer disk image, which carries
    ///   an `Applications` link of its own;
    /// - another Mac's system or data volume, or a Time Machine drive;
    /// - an `Applications` that is a link.
    static func driveRoots(
        volumes: URL = AppFolders.volumes,
        isLocalDisk: (URL) -> Bool = { AppFolders.isOnLocalDisk($0) }
    ) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: volumes.path) else { return [] }
        return names.sorted().compactMap { name -> URL? in
            guard !name.hasPrefix(".") else { return nil }
            let volume = volumes.appendingPathComponent(name, isDirectory: true)
            guard isRealFolder(volume),
                  isLocalDisk(volume),
                  !isReadOnly(volume),
                  !holdsWholeDisk(volume, markers: driveMarkers)
            else { return nil }
            let applications = volume.appendingPathComponent("Applications", isDirectory: true)
            return isRealFolder(applications) ? applications : nil
        }
    }

    /// Folders that mark a whole Mac (`System`, `Users`) or a Time Machine
    /// drive (`Backups.backupdb`).
    private static let driveMarkers = ["System", "Users", "Backups.backupdb"]

    /// The same, plus `Library`, which marks a copy of a home folder.
    private static let pickedMarkers = driveMarkers + ["Library"]

    // MARK: Folders the user adds

    struct PickedFolder: Codable, Equatable, Sendable {
        var path: String
        var dateAdded: Date
    }

    /// Why a folder can't be added, or can no longer be read from.
    enum Refusal: Equatable, Sendable {
        /// Not there, or not a folder.
        case notAFolder
        /// Not in the home folder or on a drive under `/Volumes`.
        case outsideHomeAndDrives
        /// The home folder, a folder above it, or a whole drive.
        case tooBroad
        /// In `~/Library`, in a hidden folder, or inside an app or package.
        case insideLibraryOrBundle
        /// A link, or reached through one.
        case throughLink
        /// On a network share, a cloud drive, or a read-only volume.
        case notOnWritableLocalDisk
        /// Holds a copy of a Mac, a home folder, or a Time Machine backup.
        case holdsWholeDisk
        /// Already one of the folders, or inside one.
        case alreadyIncluded
        /// Holds one of the other folders.
        case holdsAnotherFolder
    }

    /// The reason `folder` can't be one of the folders Purge lists apps from,
    /// or nil when it can. Asked when the user adds it, and again every time
    /// the list is read, so a folder replaced by a link later drops out.
    ///
    /// A folder the user adds widens what the uninstaller's delete gate takes,
    /// so the rules are the ones a moved Large Files folder follows: in the
    /// home folder or on a drive attached to this Mac, never `~/Library`, never
    /// a whole drive or a copy of one, never reached through a link.
    static func refusal(
        forPicked folder: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        otherRoots: [URL],
        volumes: URL = AppFolders.volumes,
        isLocalDisk: (URL) -> Bool = { AppFolders.isOnLocalDisk($0) }
    ) -> Refusal? {
        let url = folder.standardizedFileURL
        let path = url.path
        guard isFolder(url) else { return .notAFolder }

        let homePath = home.standardizedFileURL.path
        let volumesPath = volumes.standardizedFileURL.path
        let inHome = isInside(path, homePath)
        let onDrive = isInside(path, volumesPath)
        if path == homePath || isInside(homePath, path) { return .tooBroad }
        guard inHome || onDrive else { return .outsideHomeAndDrives }
        if onDrive, url.deletingLastPathComponent().path == volumesPath { return .tooBroad }
        if (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true { return .tooBroad }

        let base = inHome ? homePath : volumesPath
        let below = path.dropFirst(base.count + 1).split(separator: "/")
        for name in below {
            if name.hasPrefix(".") || AppBundleReach.isBundleFolderName(name)
                || name.caseInsensitiveCompare("Library") == .orderedSame {
                return .insideLibraryOrBundle
            }
        }
        // Each folder from the home folder or the drive down, so a link
        // anywhere on the way is caught, and a package by what is on disk.
        var current = base
        for name in below {
            current += "/" + name
            let values = try? URL(fileURLWithPath: current)
                .resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey])
            if values?.isSymbolicLink == true { return .throughLink }
            if values?.isPackage == true { return .insideLibraryOrBundle }
        }
        guard isLocalDisk(url), !isReadOnly(url) else { return .notOnWritableLocalDisk }
        if holdsWholeDisk(url, markers: pickedMarkers) { return .holdsWholeDisk }

        for other in otherRoots {
            let otherPath = other.standardizedFileURL.path
            if path == otherPath || isInside(path, otherPath) { return .alreadyIncluded }
            if isInside(otherPath, path) { return .holdsAnotherFolder }
        }
        return nil
    }

    /// The folders the user added, whether or not they are there now.
    static func pickedFolders() -> [PickedFolder] {
        guard let data = try? Data(contentsOf: pickedFoldersFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PickedFolder].self, from: data)) ?? []
    }

    /// Adds `folder` unless `refusal(forPicked:)` refuses it. Returns the
    /// refusal, or nil once it is saved. `saveFailed` is true when it passed
    /// but the list could not be written.
    @discardableResult
    static func add(
        _ folder: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        date: Date = Date()
    ) -> (refusal: Refusal?, saveFailed: Bool) {
        if let refusal = refusal(forPicked: folder, home: home, otherRoots: roots(home: home)) {
            return (refusal, false)
        }
        var folders = pickedFolders()
        folders.append(PickedFolder(path: folder.standardizedFileURL.path, dateAdded: date))
        return (nil, !save(folders))
    }

    /// Returns false when the list could not be saved.
    @discardableResult
    static func remove(path: String) -> Bool {
        let folders = pickedFolders()
        let kept = folders.filter { $0.path != path }
        guard kept.count != folders.count else { return true }
        return save(kept)
    }

    /// Next to the files the watch agent and Purge already share, so the
    /// agent reads the same list.
    static var pickedFoldersFile: URL {
        RemovedAppHandoff.root.appendingPathComponent("app-folders.json", isDirectory: false)
    }

    private static func save(_ folders: [PickedFolder]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: pickedFoldersFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(folders).write(to: pickedFoldersFile, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    // MARK: Disks

    /// File systems macOS trashes on by itself, on a disk attached to this Mac.
    /// A network share or a cloud drive mounted as a disk (rclone, macFUSE)
    /// can pass a move to its Trash on as a delete on every device.
    private static let localFileSystems: Set<String> = ["apfs", "hfs", "exfat", "msdos"]

    static func isOnLocalDisk(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.path, &info) == 0, info.f_flags & UInt32(MNT_LOCAL) != 0 else { return false }
        let type = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return localFileSystems.contains(type)
    }

    static func isReadOnly(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? true
    }

    /// True when `url` is on the same volume as the home folder. Only a bundle
    /// there can go to the root helper, whose move can't cross volumes.
    static func isOnHomeVolume(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        var own = stat()
        var homeInfo = stat()
        guard lstat(url.path, &own) == 0, stat(home.path, &homeInfo) == 0 else { return false }
        return own.st_dev == homeInfo.st_dev
    }

    // MARK: Helpers

    private static func isRealFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// A folder, or a link to one.
    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func holdsWholeDisk(_ url: URL, markers: [String]) -> Bool {
        markers.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        folder == "/" ? path != "/" : path.hasPrefix(folder + "/")
    }
}
