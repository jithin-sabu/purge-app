import Foundation

/// Where the listed apps come from, for the App Uninstaller's header (#99).
///
/// Most Macs list apps from `/Applications` and `~/Applications` only, and for
/// them there is nothing to say: `isWorthShowing` stays false and the header
/// reads as it always has. It turns on only when an app comes from a drive or
/// a folder the user added, or the user added a folder themselves.
///
/// Built from paths only, never the disk, since the header reads it on every
/// render.
nonisolated struct AppFolderSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case builtIn
        case drive
        case added
    }

    struct Folder: Equatable, Sendable, Identifiable {
        var id: String { path }
        let path: String
        let name: String
        let kind: Kind
        let appCount: Int
        /// False for an added folder that isn't there now, such as one on a
        /// drive that is out.
        var isAvailable = true
    }

    var folders: [Folder] = []

    var isWorthShowing: Bool {
        folders.contains { $0.kind == .added || ($0.kind == .drive && $0.appCount > 0) }
    }

    /// The folders that hold a listed app, and every folder the user added,
    /// even one with no apps yet or on a drive that is out.
    /// - Parameters:
    ///   - appPaths: the bundle paths of the listed apps, as listed.
    ///   - roots: the folders Purge reads now, built-in first (`AppFolders.roots()`).
    ///   - builtIn: the two built-in folders' paths.
    ///   - added: the folders the user added, whether or not they are there now.
    ///   - driveNames: the drive's name for a drive folder's path, such as "SSD".
    static func make(
        appPaths: [String],
        roots: [String],
        builtIn: Set<String>,
        added: [String],
        driveNames: [String: String] = [:]
    ) -> AppFolderSummary {
        var counts: [String: Int] = [:]
        for path in appPaths {
            // The longest match, so an added folder inside a drive's
            // `Applications` would count its own apps.
            if let root = roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
                counts[root, default: 0] += 1
            }
        }
        var folders: [Folder] = []
        var seen = Set<String>()
        for root in roots + added where seen.insert(root).inserted {
            let kind: Kind = builtIn.contains(root) ? .builtIn : (added.contains(root) ? .added : .drive)
            let count = counts[root] ?? 0
            guard count > 0 || kind == .added else { continue }
            folders.append(Folder(
                path: root,
                name: name(of: root, kind: kind, driveNames: driveNames),
                kind: kind,
                appCount: count,
                isAvailable: roots.contains(root)
            ))
        }
        return AppFolderSummary(folders: folders)
    }

    private static func name(of path: String, kind: Kind, driveNames: [String: String]) -> String {
        switch kind {
        case .builtIn:
            return (path as NSString).abbreviatingWithTildeInPath
        case .drive:
            return driveNames[path] ?? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        case .added:
            return (path as NSString).lastPathComponent
        }
    }
}

/// The folder paths `AppFolderSummary` is built from, read together off the
/// main thread.
nonisolated struct AppFolderPaths: Equatable, Sendable {
    var roots: [String] = []
    var builtIn: Set<String> = []
    var added: [String] = []
    var driveNames: [String: String] = [:]

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppFolderPaths {
        let builtIn = AppFolders.builtInRoots(home: home).map(\.path)
        let roots = AppFolders.roots(home: home).map(\.path)
        let added = AppFolders.pickedFolders().map(\.path)
        var names: [String: String] = [:]
        for root in roots where !builtIn.contains(root) && !added.contains(root) {
            let volume = URL(fileURLWithPath: root).deletingLastPathComponent()
            if let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName {
                names[root] = name
            }
        }
        return AppFolderPaths(roots: roots, builtIn: Set(builtIn), added: added, driveNames: names)
    }
}
