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
        /// Only the hidden folders directly inside, each on its own. The home
        /// folder's dot folders, for Developer. Loose files are left out.
        case hiddenChildren
        /// The visible folders directly inside, apart from the names here,
        /// compared ignoring case, which other roots measure. Loose files are
        /// left out: the folder itself is never claimed, so the roots inside it
        /// keep their own figures.
        case childrenExcept(Set<String>)
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
/// libraries, the names in the home folder) are passed in, so the plan can be
/// checked without a Mac behind it.
nonisolated enum EverythingElseRootPlan {
    /// The folders that hold the user's own files, each walked by folder.
    static let documentFolders = ["Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures"]

    /// The media libraries Large Files never descends into, by home-relative path.
    static let mediaLibraryFolders = [
        "Pictures/Photos Library.photoslibrary",
        "Pictures/Photo Booth Library",
        "Movies/TV",
        "Movies/iMovie Library.imovielibrary",
        "Movies/iMovie Theater.theater",
        "Music/Music",
        "Music/GarageBand"
    ]

    /// Mail's and Messages' folders. Both are protected roots.
    static let mailAndMessagesFolders = ["Library/Mail", "Library/Messages"]

    /// Where apps installed outside Applications keep their installs, by
    /// home-relative path. Steam libraries are added from `libraryfolders.vdf`.
    static let appStoreFolders = [
        "Library/Application Support/JetBrains/Toolbox/apps",
        "Library/Application Support/itch/apps"
    ]

    /// Folders in the home folder that hold code projects, lowercased. Matched
    /// against the names the home folder really has, so `~/Developer` and
    /// `~/developer` on a case-insensitive disk are one folder, walked once (#175).
    static let developerFolderNames: Set<String> = [
        "developer", "projects", "code", "src", "repos", "repositories", "github", "workspace", "dev"
    ]

    /// Folders directly in `~/Library` that a root of their own measures, so the
    /// rest-of-Library root leaves them out.
    static let libraryFoldersMeasuredElsewhere: Set<String> = [
        "Caches", "Application Support", "Containers", "Group Containers", "Mail", "Messages", "Developer"
    ]

    /// Folders directly in the home folder that the rest-of-home root leaves out:
    /// the ones walked on their own, Library, and Applications, whose apps the
    /// Installed apps row counts.
    static let homeFoldersMeasuredElsewhere: Set<String> = Set(documentFolders + ["Library", "Applications"])

    /// Hidden folders in the home folder that are not tool folders. The Trash
    /// has a line of its own from `TrashStore`.
    static let ignoredHiddenFolders: Set<String> = [".Trash"]

    /// Folders a limited walk never reads, on top of `ProtectedLocations`: the
    /// media libraries, which macOS guards with a Photos or Media & Apple Music
    /// prompt (the same stall `ProtectedLocations.mediaCacheRoots` records),
    /// and the address book, which prompts for Contacts. A `du` inside any of
    /// them would put a prompt on screen with Purge's name on it.
    static let limitedWalkSkips: [String] = mediaLibraryFolders + mailAndMessagesFolders + [
        "Library/Application Support/AddressBook"
    ]

    /// Whether a limited walk may size `url`: outside the protected roots and
    /// outside the media and contacts folders above. Pure string work.
    static func isReadableByLimitedWalk(_ url: URL, home: URL) -> Bool {
        guard ProtectedLocations.isReadable(url, access: .limited, home: home) else { return false }
        let homePath = home.standardizedFileURL.path
        let path = url.path
        for relative in limitedWalkSkips {
            let skipped = "\(homePath)/\(relative)"
            if path == skipped || path.hasPrefix(skipped + "/") { return false }
        }
        // A media library anywhere under the media folders, by its bundle name.
        let name = url.lastPathComponent
        if LargeFileScanPolicy.excludedFolderNames.contains(name) { return false }
        let ext = url.pathExtension.lowercased()
        return !["photoslibrary", "imovielibrary", "tvlibrary", "musiclibrary", "theater"].contains(ext)
    }

    /// The project folders among the names directly in the home folder, spelled
    /// as the disk spells them. Hidden names are never project folders here.
    static func developerFolders(inHome home: URL, names: [String]) -> [URL] {
        names
            .filter { !$0.hasPrefix(".") && developerFolderNames.contains($0.lowercased()) }
            .sorted()
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// `steamLibraries` are the library roots from `libraryfolders.vdf` on the
    /// startup disk, each holding a `steamapps` folder. `otherUserHomes` are the
    /// folders directly in `/Users` other than this user's, `Shared` included.
    /// `homeFolderNames` are the names directly in the home folder. `usersFolder`
    /// is the parent of those homes, `/Users` outside tests.
    static func roots(
        home: URL,
        access: ScanAccess,
        steamLibraries: [URL],
        otherUserHomes: [URL],
        homeFolderNames: [String],
        usersFolder: URL = URL(fileURLWithPath: "/Users", isDirectory: true)
    ) -> [EverythingElseMeasureRoot] {
        var roots: [EverythingElseMeasureRoot] = []

        func add(
            _ group: EverythingElseGroup,
            _ url: URL,
            _ kind: EverythingElseMeasureRoot.Kind,
            lockedWhenLimited: Bool = false
        ) {
            let locked = access == .limited && (lockedWhenLimited || !isReadableByLimitedWalk(url, home: home))
            roots.append(EverythingElseMeasureRoot(group: group, url: url, kind: kind, isLockedWithoutAccess: locked))
        }

        for library in steamLibraries {
            add(.otherApps, library.appendingPathComponent("steamapps/common", isDirectory: true), .children)
        }
        for relative in appStoreFolders {
            add(.otherApps, home.appendingPathComponent(relative, isDirectory: true), .children)
        }
        add(.otherApps, usersFolder.appendingPathComponent("Shared/Epic Games", isDirectory: true), .children)

        for relative in mediaLibraryFolders {
            add(.mediaLibraries, home.appendingPathComponent(relative, isDirectory: true), .whole)
        }
        for relative in mailAndMessagesFolders {
            add(.mailAndMessages, home.appendingPathComponent(relative, isDirectory: true), .whole)
        }

        add(.protectedCaches, home.appendingPathComponent("Library/Caches", isDirectory: true), .children)

        let projectFolders = developerFolders(inHome: home, names: homeFolderNames)
        for folder in projectFolders {
            add(.developer, folder, .children)
        }
        add(.developer, home.appendingPathComponent("Library/Developer", isDirectory: true), .children)
        // Only the home folder's hidden folders. Home is never a protected root.
        add(.developer, home, .hiddenChildren)

        for relative in ["Library/Application Support", "Library/Containers", "Library/Group Containers"] {
            add(.appData, home.appendingPathComponent(relative, isDirectory: true), .children)
        }
        // The rest of Library holds Calendars, Reminders and other folders macOS
        // guards with prompts of their own, so a limited walk leaves it whole.
        add(
            .appData,
            home.appendingPathComponent("Library", isDirectory: true),
            .childrenExcept(Set(libraryFoldersMeasuredElsewhere.map { $0.lowercased() })),
            lockedWhenLimited: true
        )

        for name in documentFolders {
            add(.documents, home.appendingPathComponent(name, isDirectory: true), .children)
        }
        let skippedHomeNames = homeFoldersMeasuredElsewhere.union(projectFolders.map(\.lastPathComponent))
        add(.documents, home, .childrenExcept(Set(skippedHomeNames.map { $0.lowercased() })))

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
    /// How far through a root's folders the sizing is, 0...1, so the ring can
    /// move inside a root and not only between roots.
    case progress(EverythingElseMeasureRoot, Double)
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
    /// Roots that are not on this Mac, or that could not be read.
    var skippedRoots: [EverythingElseMeasureRoot] = []
    /// How far into each unfinished root the walk is, 0...1.
    var rootProgress: [EverythingElseMeasureRoot: Double] = [:]
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
            rootProgress[root] = nil
            if locked {
                if !lockedRoots.contains(root) { lockedRoots.append(root) }
            } else if !skippedRoots.contains(root) {
                skippedRoots.append(root)
            }
        case .progress(let root, let fraction):
            rootProgress[root] = min(1, max(0, fraction))
        case .measured(let measured):
            rootProgress[measured.root] = nil
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
        return planned.allSatisfy(isDone)
    }

    /// How many planned roots the walk has dealt with: measured, locked or skipped.
    var finishedRootCount: Int {
        plannedRoots.filter(isDone).count
    }

    /// The measured groups with a root on this Mac, in claim order. What the
    /// page counts progress in: a group lands as one figure, a root does not.
    var plannedGroups: [EverythingElseGroup] {
        EverythingElseGroup.measured.filter { group in plannedRoots.contains { $0.group == group } }
    }

    var finishedGroupCount: Int {
        plannedGroups.filter(hasFinished).count
    }

    /// How far the walk is, 0...1: the roots dealt with, plus how far into the
    /// current one. What the ring shows.
    var walkFraction: Double {
        guard !plannedRoots.isEmpty else { return 0 }
        if isComplete { return 1 }
        let current = currentRoot.flatMap { rootProgress[$0] } ?? 0
        return min(1, (Double(finishedRootCount) + current) / Double(plannedRoots.count))
    }

    /// Where finishing the current root would put `walkFraction`. The ring
    /// creeps toward this between real figures and never past it, so it never
    /// has to move backwards.
    var walkCeiling: Double {
        guard !plannedRoots.isEmpty else { return 0 }
        if isComplete { return 1 }
        return min(1, Double(finishedRootCount + 1) / Double(plannedRoots.count))
    }

    /// The root the walk is on now. Roots are walked in plan order, so it is the
    /// first one not dealt with yet. Nil before the plan arrives and once done.
    var currentRoot: EverythingElseMeasureRoot? {
        plannedRoots.first { !isDone($0) }
    }

    private func isDone(_ root: EverythingElseMeasureRoot) -> Bool {
        lockedRoots.contains(root) || skippedRoots.contains(root) || measuredRoots.contains { $0.root == root }
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
    /// The name to show. A group container is named `<team id>.<group>`, and the
    /// ten-character team id means nothing to a person, so it is left off.
    var displayName: String {
        let name = self.name
        guard let dot = name.firstIndex(of: "."),
              name.distance(from: name.startIndex, to: dot) == 10,
              name[..<dot].allSatisfy({ ($0.isUppercase && $0.isLetter) || $0.isNumber }),
              name.index(after: dot) < name.endIndex
        else { return name }
        return String(name[name.index(after: dot)...])
    }

    /// The folder's name, without the extension a media library's bundle carries.
    var name: String {
        let ext = url.pathExtension.lowercased()
        if ["photoslibrary", "imovielibrary", "tvlibrary", "musiclibrary", "theater"].contains(ext) {
            return url.deletingPathExtension().lastPathComponent
        }
        return url.lastPathComponent
    }
}

/// One group's figures: its total, the folders over the floor, and the rest in a line.
nonisolated struct EverythingElseGroupBreakdown: Equatable, Sendable {
    let group: EverythingElseGroup
    let bytes: Int64
    /// Biggest first, only those over the floor.
    let folders: [EverythingElseFolder]
    /// How many folders fell under the floor.
    let smallerFolderCount: Int
    /// The biggest of those, so the smaller-folders line can say what is in it.
    let smallerFolders: [EverythingElseFolder]
    /// What the folders under the floor and the loose files add up to.
    let smallerBytes: Int64
    /// A limited scan left part of this group unread.
    let isLocked: Bool
    /// Every root of the group has been visited.
    let isFinished: Bool
    /// The measured roots held nothing at all: not on this Mac, or empty.
    var isEmpty: Bool { bytes == 0 && folders.isEmpty && smallerFolderCount == 0 }

    /// The same figures with the total held to `limit`. The folders keep their
    /// own sizes: they are what the walk counted.
    func capped(at limit: Int64) -> EverythingElseGroupBreakdown {
        EverythingElseGroupBreakdown(
            group: group,
            bytes: min(bytes, max(0, limit)),
            folders: folders,
            smallerFolderCount: smallerFolderCount,
            smallerFolders: smallerFolders,
            smallerBytes: smallerBytes,
            isLocked: isLocked,
            isFinished: isFinished
        )
    }
}

/// The unsorted space split into groups. Each byte is counted once: the five
/// Overview categories claim theirs first, in their own order, then the groups
/// claim in `EverythingElseGroup` order, with the same `ClaimedPaths` logic the
/// Overview uses. So a cache App Caches already found adds nothing under App Data,
/// and a Steam game under Other Apps comes out of Steam's App Data.
///
/// The groups never add up to more than Everything else. A category shown from an
/// earlier session's saved total has no paths to claim, so its bytes can be
/// counted again here; the totals are then held to Everything else in claim order
/// and the breakdown says it is approximate.
nonisolated struct EverythingElseBreakdown: Equatable, Sendable {
    /// Folders under this are rolled into the "smaller folders" line.
    static let defaultFloorBytes: Int64 = 1_000_000_000
    /// How many of a group's smaller folders it keeps by name, biggest first.
    static let listedSmallerFolderCount = 8

    let groups: [EverythingElseGroup: EverythingElseGroupBreakdown]
    /// The Overview's Everything else figure, which this breaks down.
    let everythingElseBytes: Int64
    let macOSBytes: Int64?
    /// What is in the Trash, or nil when it can't be read.
    let trashBytes: Int64?
    let isComplete: Bool
    let completedAt: Date?
    /// Some figure was held back to keep the page adding up, or a category is
    /// shown from a saved total. The groups are then close, not exact.
    let isApproximate: Bool

    var measuredBytes: Int64 {
        groups.values.reduce(0) { $0 + $1.bytes }
    }

    /// The remainder, after macOS and the Trash have their lines.
    var systemDataBytes: Int64 {
        max(0, everythingElseBytes - measuredBytes - (macOSBytes ?? 0) - (trashBytes ?? 0))
    }

    func bytes(for group: EverythingElseGroup) -> Int64 {
        switch group {
        case .macOS: return macOSBytes ?? 0
        case .trash: return trashBytes ?? 0
        case .systemData: return systemDataBytes
        case .otherApps, .mediaLibraries, .mailAndMessages, .protectedCaches,
             .developer, .appData, .documents, .otherUsers:
            return groups[group]?.bytes ?? 0
        }
    }

    subscript(group: EverythingElseGroup) -> EverythingElseGroupBreakdown? {
        groups[group]
    }

    func bytes(for bucket: EverythingElseBucket) -> Int64 {
        bucket.groups.reduce(0) { $0 + bytes(for: $1) }
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
    /// `includesRecordedFigures` is true when a category shows a saved total.
    init(
        measurement: EverythingElseMeasurement,
        claimedFirst: [OverviewSizedItem],
        everythingElseBytes: Int64,
        trashBytes: Int64? = nil,
        includesRecordedFigures: Bool = false,
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
            var smallerFolders: [EverythingElseFolder] = []
            var total: Int64 = 0
            for measured in roots {
                // Children before the root, biggest first, so a nested claim is
                // subtracted from its parent once and never twice.
                for folder in measured.folders.sorted(by: { $0.bytes > $1.bytes }) {
                    let added = claims.claim(folder)
                    guard added > 0 else { continue }
                    total += added
                    let item = EverythingElseFolder(path: folder.path, bytes: added, measuredBytes: folder.bytes, group: group)
                    if added >= floorBytes {
                        folders.append(item)
                    } else {
                        smallerCount += 1
                        smallerBytes += added
                        smallerFolders.append(item)
                    }
                }
                if measured.root.kind == .whole {
                    let added = claims.claim(OverviewSizedItem(path: measured.root.path, bytes: measured.totalBytes))
                    guard added > 0 else { continue }
                    total += added
                    let item = EverythingElseFolder(path: measured.root.path, bytes: added, measuredBytes: measured.totalBytes, group: group)
                    if added >= floorBytes {
                        folders.append(item)
                    } else {
                        smallerCount += 1
                        smallerBytes += added
                        smallerFolders.append(item)
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
                smallerFolders: Array(smallerFolders.sorted { $0.bytes > $1.bytes }.prefix(Self.listedSmallerFolderCount)),
                smallerBytes: smallerBytes,
                isLocked: measurement.isLocked(group),
                isFinished: measurement.hasFinished(group)
            )
        }

        // Held to Everything else in claim order, then macOS, then the Trash.
        var available = max(0, everythingElseBytes)
        var wasCapped = false
        for group in EverythingElseGroup.measured {
            guard let figures = groups[group] else { continue }
            if figures.bytes > available {
                wasCapped = true
                groups[group] = figures.capped(at: available)
            }
            available -= groups[group]?.bytes ?? 0
        }
        let macOS = measurement.macOSBytes.map { min(max(0, $0), available) }
        if let macOS, let measured = measurement.macOSBytes, macOS < measured { wasCapped = true }
        available -= macOS ?? 0
        let trash = trashBytes.map { min(max(0, $0), available) }
        if let trash, let given = trashBytes, trash < given { wasCapped = true }

        self.groups = groups
        self.everythingElseBytes = max(0, everythingElseBytes)
        self.macOSBytes = macOS
        self.trashBytes = trash
        self.isComplete = measurement.isComplete
        self.completedAt = measurement.completedAt
        self.isApproximate = wasCapped || includesRecordedFigures
    }
}
