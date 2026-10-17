import Foundation

/// One folder the Everything else walk measures, and the group it feeds.
nonisolated struct EverythingElseMeasureRoot: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        /// Each folder directly inside is sized on its own, and the loose files
        /// beside them are summed, so the group can list its biggest folders.
        case children
        /// Sized as one folder. For libraries and other users' homes, whose
        /// insides are not something to list.
        case whole
    }

    let group: EverythingElseGroup
    let url: URL
    let kind: Kind
    /// True when a limited scan must not touch this root. The row then says
    /// "Needs Full Disk Access" and the remainder absorbs it.
    let isLockedWithoutAccess: Bool

    var path: String { OverviewSizedItem.normalized(url.path) }
}

/// Which folders are walked for each group, given how much of the disk the scan
/// may read. Pure: the lists that need the disk (other users' homes, Steam's
/// libraries) are passed in, so the plan can be checked without a Mac behind it.
nonisolated enum EverythingElseRootPlan {
    /// The folders that hold the user's own files, each as a whole.
    static let yourFileFolders = ["Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures"]

    /// The managed libraries Large Files never descends into, by home-relative path.
    /// Mail and Messages are protected roots; the rest live in the media folders.
    static let managedLibraryFolders = [
        "Library/Mail",
        "Library/Messages",
        "Pictures/Photos Library.photoslibrary",
        "Pictures/Photo Booth Library",
        "Movies/TV",
        "Movies/iMovie Library.imovielibrary",
        "Movies/iMovie Theater.theater",
        "Music/Music",
        "Music/GarageBand"
    ]

    /// Where apps installed outside Applications keep their installs, by
    /// home-relative path. Steam libraries are added from `libraryfolders.vdf`.
    static let appStoreFolders = [
        "Library/Application Support/JetBrains/Toolbox/apps",
        "Library/Application Support/itch/apps"
    ]

    /// Epic's default install folder on a Mac, shared between users.
    static let epicGamesFolder = "/Users/Shared/Epic Games"

    /// Hidden folders in the home folder that are not tool folders.
    static let ignoredHiddenFolders: Set<String> = [".Trash"]

    /// `steamLibraries` are the library roots from `libraryfolders.vdf`, each
    /// holding a `steamapps` folder. `otherUserHomes` are the folders directly in
    /// `/Users` other than this user's, `Shared` included. `usersFolder` is the
    /// parent of those homes, `/Users` outside tests.
    static func roots(
        home: URL,
        access: ScanAccess,
        steamLibraries: [URL],
        otherUserHomes: [URL],
        usersFolder: URL = URL(fileURLWithPath: "/Users", isDirectory: true)
    ) -> [EverythingElseMeasureRoot] {
        var roots: [EverythingElseMeasureRoot] = []

        func add(_ group: EverythingElseGroup, _ url: URL, _ kind: EverythingElseMeasureRoot.Kind) {
            let locked = access == .limited && !ProtectedLocations.isReadable(url, access: access, home: home)
            roots.append(EverythingElseMeasureRoot(group: group, url: url, kind: kind, isLockedWithoutAccess: locked))
        }

        for library in steamLibraries {
            add(.appsOutsideApplications, library.appendingPathComponent("steamapps/common", isDirectory: true), .children)
        }
        for relative in appStoreFolders {
            add(.appsOutsideApplications, home.appendingPathComponent(relative, isDirectory: true), .children)
        }
        add(.appsOutsideApplications, usersFolder.appendingPathComponent("Shared/Epic Games", isDirectory: true), .children)

        for relative in managedLibraryFolders {
            add(.managedLibraries, home.appendingPathComponent(relative, isDirectory: true), .whole)
        }

        add(.uncleanableCaches, home.appendingPathComponent("Library/Caches", isDirectory: true), .children)

        for relative in ["Library/Application Support", "Library/Containers", "Library/Group Containers"] {
            add(.appData, home.appendingPathComponent(relative, isDirectory: true), .children)
        }

        for name in yourFileFolders {
            add(.yourFiles, home.appendingPathComponent(name, isDirectory: true), .children)
        }

        // The home folder itself: only its hidden folders are measured, see the
        // measurer. Home is never a protected root, so it is never locked.
        add(.hiddenToolFolders, home, .children)

        for other in otherUserHomes {
            add(.otherUsers, other, .whole)
        }

        return roots
    }

    /// The folders directly in `/Users` other than the current home. Pure string
    /// work over a listing the caller made.
    static func otherUserHomes(in usersFolder: URL, names: [String], home: URL) -> [URL] {
        let homeName = home.standardizedFileURL.lastPathComponent
        return names
            .filter { !$0.hasPrefix(".") && $0 != homeName }
            .sorted()
            .map { usersFolder.appendingPathComponent($0, isDirectory: true) }
    }
}

/// Steam's `libraryfolders.vdf` lists every library the user added, by its root.
/// The format is Valve's KeyValues: quoted keys and values, nested in braces.
/// Only the `"path"` entries matter here.
nonisolated enum SteamLibraryFolders {
    static func libraryRoots(fromVDF text: String) -> [URL] {
        var roots: [URL] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: true)
                .map { String($0) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard parts.count == 2, parts[0] == "path" else { continue }
            let path = parts[1].replacingOccurrences(of: "\\\\", with: "\\")
            guard path.hasPrefix("/") else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if !roots.contains(url) { roots.append(url) }
        }
        return roots
    }

    /// Where Steam keeps the list on a Mac.
    static func vdfURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Steam/steamapps/libraryfolders.vdf")
    }
}

/// A game Steam installed, from its `appmanifest_<id>.acf` in a library's
/// `steamapps` folder. The id lets a row open the game's uninstall in Steam.
nonisolated struct SteamGame: Equatable, Sendable {
    let appID: String
    let name: String
    /// The game's folder inside `steamapps/common`.
    let installPath: String

    /// Reads the three fields out of Valve's KeyValues text. Nil when the manifest
    /// lacks any of them.
    static func parse(manifest text: String, commonFolder: URL) -> SteamGame? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: true)
                .map { String($0) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1]
        }
        guard let appID = fields["appid"], let name = fields["name"], let installDir = fields["installdir"],
              !appID.isEmpty, !installDir.isEmpty
        else { return nil }
        return SteamGame(
            appID: appID,
            name: name,
            installPath: OverviewSizedItem.normalized(commonFolder.appendingPathComponent(installDir).path)
        )
    }
}

/// One root the walk finished: the folders directly inside it and what they hold.
nonisolated struct EverythingElseMeasuredRoot: Equatable, Sendable {
    let root: EverythingElseMeasureRoot
    /// Each folder directly inside the root, with its size. For a `whole` root this
    /// is empty and `totalBytes` carries the figure.
    let folders: [OverviewSizedItem]
    /// Files directly inside the root, not in any folder.
    let looseFileBytes: Int64
    /// Everything under the root as counted.
    var totalBytes: Int64 {
        folders.reduce(looseFileBytes) { $0 + $1.bytes }
    }

    init(root: EverythingElseMeasureRoot, folders: [OverviewSizedItem], looseFileBytes: Int64) {
        self.root = root
        self.folders = folders
        self.looseFileBytes = max(0, looseFileBytes)
    }

    /// A whole-folder root: one figure, nothing listed inside.
    init(root: EverythingElseMeasureRoot, totalBytes: Int64) {
        self.init(root: root, folders: [], looseFileBytes: totalBytes)
    }
}

/// What the measurer reports as it goes.
nonisolated enum EverythingElseMeasureEvent: Equatable, Sendable {
    /// The roots the walk will visit, locked ones included, so rows can show
    /// which groups are coming and which need access.
    case planned([EverythingElseMeasureRoot])
    /// A root a limited scan must not read, or one that is not on this Mac.
    case skipped(EverythingElseMeasureRoot, locked: Bool)
    case measured(EverythingElseMeasuredRoot)
    /// The system volume's used space.
    case macOS(Int64)
    /// The games a Steam library holds, so their rows can say what they are.
    case steamGames([SteamGame])
}

/// Everything the walk found so far. Groups fill in as their roots finish.
nonisolated struct EverythingElseMeasurement: Equatable, Sendable {
    var access: ScanAccess
    var plannedRoots: [EverythingElseMeasureRoot] = []
    var measuredRoots: [EverythingElseMeasuredRoot] = []
    /// Roots the walk did not read because the scan was limited.
    var lockedRoots: [EverythingElseMeasureRoot] = []
    var macOSBytes: Int64?
    /// Steam's games by install folder.
    var steamGames: [String: SteamGame] = [:]
    var isComplete = false
    var completedAt: Date?

    init(access: ScanAccess) {
        self.access = access
    }

    mutating func apply(_ event: EverythingElseMeasureEvent) {
        switch event {
        case .planned(let roots):
            plannedRoots = roots
        case .skipped(let root, let locked):
            if locked, !lockedRoots.contains(root) { lockedRoots.append(root) }
        case .measured(let measured):
            measuredRoots.removeAll { $0.root == measured.root }
            measuredRoots.append(measured)
        case .macOS(let bytes):
            macOSBytes = max(0, bytes)
        case .steamGames(let games):
            for game in games {
                steamGames[game.installPath] = game
            }
        }
    }

    /// Whether every root of the group has been visited, read or not.
    func hasFinished(_ group: EverythingElseGroup) -> Bool {
        guard group.isMeasured else { return isComplete }
        if isComplete { return true }
        // Nothing planned yet means the walk has not started. A group with no
        // roots on this Mac (no other users, say) has nothing to wait for.
        guard !plannedRoots.isEmpty else { return false }
        let planned = plannedRoots.filter { $0.group == group }
        return planned.allSatisfy { root in
            lockedRoots.contains(root) || measuredRoots.contains { $0.root == root }
        }
    }

    /// Whether a limited scan left part of the group unread.
    func isLocked(_ group: EverythingElseGroup) -> Bool {
        lockedRoots.contains { $0.group == group }
    }
}

/// One folder on a group's list, after the categories took their share.
nonisolated struct EverythingElseFolder: Equatable, Identifiable, Sendable {
    let path: String
    /// What this folder adds once the parts a category already counted are out.
    let bytes: Int64
    /// Everything under the folder, as counted by the walk.
    let measuredBytes: Int64
    let group: EverythingElseGroup

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// One group's figures: its total, the folders over the floor, and the rest in a line.
nonisolated struct EverythingElseGroupBreakdown: Equatable, Sendable {
    let group: EverythingElseGroup
    let bytes: Int64
    /// Biggest first, only those over the floor.
    let folders: [EverythingElseFolder]
    /// How many folders fell under the floor.
    let smallerFolderCount: Int
    /// What the folders under the floor and the loose files add up to.
    let smallerBytes: Int64
    /// A limited scan left part of this group unread.
    let isLocked: Bool
    /// Every root of the group has been visited.
    let isFinished: Bool
    /// The measured roots held nothing at all: not on this Mac, or empty.
    var isEmpty: Bool { bytes == 0 && folders.isEmpty && smallerFolderCount == 0 }
}

/// The unsorted space split into groups. Each byte is counted once: the five
/// Overview categories claim theirs first, in their own order, then the groups
/// claim in `EverythingElseGroup` order, with the same `ClaimedPaths` logic the
/// Overview uses. So a cache App Caches already found adds nothing under App data,
/// and a Steam game under Apps outside Applications comes out of Steam's App data.
nonisolated struct EverythingElseBreakdown: Equatable, Sendable {
    /// Folders under this are rolled into the "smaller folders" line.
    static let defaultFloorBytes: Int64 = 1_000_000_000

    let groups: [EverythingElseGroup: EverythingElseGroupBreakdown]
    /// The Overview's Everything else figure, which this breaks down.
    let everythingElseBytes: Int64
    let macOSBytes: Int64?
    let isComplete: Bool
    let completedAt: Date?

    var measuredBytes: Int64 {
        groups.values.reduce(0) { $0 + $1.bytes }
    }

    /// The remainder on the drill-in, after macOS has its line.
    var notMeasuredBytes: Int64 {
        max(0, everythingElseBytes - measuredBytes - (macOSBytes ?? 0))
    }

    /// The remainder on the Overview, where macOS has no line and stays in it.
    var notMeasuredOnOverviewBytes: Int64 {
        max(0, everythingElseBytes - measuredBytes)
    }

    func bytes(for group: EverythingElseGroup) -> Int64 {
        switch group {
        case .macOS: return macOSBytes ?? 0
        case .notMeasured: return notMeasuredBytes
        case .appsOutsideApplications, .managedLibraries, .uncleanableCaches, .appData,
             .yourFiles, .hiddenToolFolders, .otherUsers:
            return groups[group]?.bytes ?? 0
        }
    }

    subscript(group: EverythingElseGroup) -> EverythingElseGroupBreakdown? {
        groups[group]
    }

    /// Measured groups with something in them, biggest first, then the rest in
    /// claim order so unfinished and locked groups keep a stable place.
    var measuredGroupsBySize: [EverythingElseGroup] {
        EverythingElseGroup.measured.sorted { lhs, rhs in
            let left = groups[lhs]?.bytes ?? 0
            let right = groups[rhs]?.bytes ?? 0
            if left != right { return left > right }
            return EverythingElseGroup.allCases.firstIndex(of: lhs)! < EverythingElseGroup.allCases.firstIndex(of: rhs)!
        }
    }

    /// `claimedFirst` are the five categories' live items in Overview claim order.
    init(
        measurement: EverythingElseMeasurement,
        claimedFirst: [OverviewSizedItem],
        everythingElseBytes: Int64,
        floorBytes: Int64 = EverythingElseBreakdown.defaultFloorBytes
    ) {
        var claims = ClaimedPaths()
        for item in claimedFirst {
            _ = claims.claim(item)
        }

        var groups: [EverythingElseGroup: EverythingElseGroupBreakdown] = [:]
        for group in EverythingElseGroup.measured {
            let roots = measurement.measuredRoots.filter { $0.root.group == group }
            var folders: [EverythingElseFolder] = []
            var smallerCount = 0
            var smallerBytes: Int64 = 0
            var total: Int64 = 0
            for measured in roots {
                // Children before the root, biggest first, so a nested claim is
                // subtracted from its parent once and never twice.
                for folder in measured.folders.sorted(by: { $0.bytes > $1.bytes }) {
                    let added = claims.claim(folder)
                    guard added > 0 else { continue }
                    total += added
                    if added >= floorBytes {
                        folders.append(EverythingElseFolder(path: folder.path, bytes: added, measuredBytes: folder.bytes, group: group))
                    } else {
                        smallerCount += 1
                        smallerBytes += added
                    }
                }
                if measured.root.kind == .whole {
                    let added = claims.claim(OverviewSizedItem(path: measured.root.path, bytes: measured.totalBytes))
                    guard added > 0 else { continue }
                    total += added
                    if added >= floorBytes {
                        folders.append(EverythingElseFolder(path: measured.root.path, bytes: added, measuredBytes: measured.totalBytes, group: group))
                    } else {
                        smallerCount += 1
                        smallerBytes += added
                    }
                } else if measured.looseFileBytes > 0 {
                    // Loose files are not a folder anyone can open, so they join
                    // the smaller line rather than getting a row of their own.
                    let loose = OverviewSizedItem(path: measured.root.path, bytes: measured.totalBytes)
                    let added = claims.claim(loose)
                    total += added
                    smallerBytes += added
                }
            }
            folders.sort { $0.bytes > $1.bytes }
            groups[group] = EverythingElseGroupBreakdown(
                group: group,
                bytes: total,
                folders: folders,
                smallerFolderCount: smallerCount,
                smallerBytes: smallerBytes,
                isLocked: measurement.isLocked(group),
                isFinished: measurement.hasFinished(group)
            )
        }

        self.groups = groups
        self.everythingElseBytes = max(0, everythingElseBytes)
        self.macOSBytes = measurement.macOSBytes
        self.isComplete = measurement.isComplete
        self.completedAt = measurement.completedAt
    }
}
