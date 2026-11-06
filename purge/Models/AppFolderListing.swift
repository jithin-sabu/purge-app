import Foundation

/// The folders the App Uninstaller lists apps from, as Settings shows them
/// (#99). Read off the main thread: it lists `/Volumes` and asks each drive
/// about its file system.
nonisolated struct AppFolderListing: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `/Applications` and `~/Applications`, always read.
        case builtIn
        /// A drive's top-level `Applications` folder, read while it is plugged in.
        case drive
        /// A folder the user added.
        case added
    }

    struct Row: Equatable, Sendable, Identifiable {
        var id: String { path }
        let path: String
        let name: String
        let kind: Kind
        /// False for an added folder that is not there now, most often because
        /// its drive is unplugged, or that no longer passes the rules.
        let isAvailable: Bool
    }

    var rows: [Row] = []

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppFolderListing {
        let fm = FileManager.default
        var rows: [Row] = AppFolders.builtInRoots(home: home).map { root in
            Row(path: root.path, name: fm.displayName(atPath: root.path), kind: .builtIn, isAvailable: true)
        }
        let drives = AppFolders.driveRoots()
        rows += drives.map { root in
            Row(path: root.path, name: volumeName(of: root), kind: .drive, isAvailable: true)
        }
        let listed = Set(AppFolders.roots(home: home).map(\.path))
        rows += AppFolders.pickedFolders().map { folder in
            Row(
                path: folder.path,
                name: (folder.path as NSString).lastPathComponent,
                kind: .added,
                isAvailable: listed.contains(folder.path)
            )
        }
        return AppFolderListing(rows: rows)
    }

    /// The drive's name as Finder shows it, such as "SSD".
    private static func volumeName(of root: URL) -> String {
        let volume = root.deletingLastPathComponent()
        return (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? volume.lastPathComponent
    }

    /// What Settings says when a folder can't be added.
    static func message(for refusal: AppFolders.Refusal) -> String {
        switch refusal {
        case .notAFolder:
            String(localized: "That folder can't be found.")
        case .outsideHomeAndDrives:
            String(localized: "Choose a folder in your home folder or on a drive.")
        case .tooBroad:
            String(localized: "Choose the folder that holds your apps, not your home folder or a whole drive.")
        case .insideLibraryOrBundle:
            String(localized: "Purge doesn't look for apps in Library, in hidden folders, or inside other apps.")
        case .throughLink:
            String(localized: "That folder is reached through an alias or link. Choose the folder it leads to.")
        case .notOnWritableLocalDisk:
            String(localized: "Purge only lists apps on drives attached to this Mac that it can move files on, not network or read-only drives.")
        case .holdsWholeDisk:
            String(localized: "That folder holds a copy of a Mac or of a home folder, or is inside one. Choose a folder with apps you use.")
        case .syncs:
            String(localized: "That folder syncs with iCloud Drive, so moving an app from it to the Trash would remove it from your other devices too.")
        case .alreadyIncluded:
            String(localized: "Purge already looks in that folder.")
        case .holdsAnotherFolder:
            String(localized: "That folder holds one Purge already looks in. Remove that one first.")
        }
    }
}
