import Darwin
import Foundation
import os

/// Xcode build folders outside `~/Library/Developer/Xcode/DerivedData` (#480).
///
/// `xcodebuild -derivedDataPath <folder>` puts its build files wherever it is
/// told, and Xcode's Locations setting can move them too. Such a folder has any
/// name, so it is known by what is inside it, never by its name: Xcode's
/// `info.plist` naming the project it built (`WorkspacePath`), `Build` and
/// `Logs` folders, and nothing Xcode does not make. A folder that also holds a
/// log, a result bundle or anything else someone put there is never offered.
///
/// Each folder gets its own Check First row in Dev Tools. Xcode's own
/// DerivedData is Safe, but a folder someone placed on purpose can hold an app
/// that runs from it, or one a LaunchAgent starts, so these rows never feed
/// Clean Safe Items or scheduled cleans. A folder a process has open, or a
/// LaunchAgent starts a program from, is left off the list, and `FileDeleter`
/// checks both again right before the move.
nonisolated enum XcodeBuildFolderScanPolicy {
    static let explanationKey = "xcode-build-folder"

    /// One row per folder, labelled with this prefix and the folder's path. The
    /// label is the row's definition key, so the rows stay apart.
    static let labelPrefix = "Xcode Build Folder "

    /// Every name Xcode puts at the top of a build folder, by Xcode version.
    /// Anything else there means someone else put it there.
    static let xcodeEntryNames: Set<String> = [
        "info.plist",
        "Build",
        "Logs",
        "Index.noindex",
        "Index",
        "TextIndex",
        "ModuleCache.noindex",
        "CompilationCache.noindex",
        "SDKStatCaches.noindex",
        "SDKExplicitPrecompiledModules",
        "SourcePackages",
        "TestResults",
        ".DS_Store"
    ]

    /// Xcode's `info.plist` is a few hundred bytes. Anything far larger is not it.
    static let maxInfoPlistBytes: off_t = 64 * 1024

    /// How deep below each project folder the walk looks: `~/Developer/a/b/c`.
    static let walkDepth = 3

    /// A folder with more entries than this is not walked into, like the project walk.
    static let maxEntriesPerFolder = 2000

    /// What Xcode's `info.plist` says about a build folder.
    struct Mark: Equatable, Sendable {
        /// The project or workspace Xcode built, as Xcode wrote it.
        let workspacePath: String
        /// When Xcode last used the folder. Nil when the key is missing.
        let lastAccessed: Date?
    }

    // MARK: - The mark

    /// The mark when `path` is an Xcode build folder, read from disk: a real
    /// folder, not a link, holding Xcode's `info.plist` with an absolute
    /// `WorkspacePath`, real `Build` and `Logs` folders, and no name Xcode does
    /// not make. Nil otherwise.
    static func mark(at path: String) -> Mark? {
        // One `lstat` first: `evaluate` asks this of every path that reaches it.
        guard isRegularFile("\(path)/info.plist"), isRealFolder(path),
              isRealFolder("\(path)/Build"), isRealFolder("\(path)/Logs"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path),
              names.allSatisfy({ xcodeEntryNames.contains($0) }) else { return nil }
        return readInfoPlist(at: "\(path)/info.plist")
    }

    /// `WorkspacePath` and `LastAccessedDate` from Xcode's `info.plist`.
    static func readInfoPlist(at path: String) -> Mark? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maxInfoPlistBytes,
              let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let workspace = plist["WorkspacePath"] as? String,
              workspace.hasPrefix("/"), workspace.count > 1 else { return nil }
        return Mark(workspacePath: workspace, lastAccessed: plist["LastAccessedDate"] as? Date)
    }

    /// The name people know the project by: the folder holding the
    /// `.xcodeproj` or `.xcworkspace`, or a Swift package's own folder.
    static func projectName(of workspacePath: String) -> String {
        var url = URL(fileURLWithPath: workspacePath)
        while ["xcodeproj", "xcworkspace"].contains(url.pathExtension.lowercased()), url.pathComponents.count > 2 {
            url.deleteLastPathComponent()
        }
        return url.lastPathComponent
    }

    // MARK: - Where a build folder may be

    /// `evaluate`'s rule. Shape and mark only: whether a process has the folder
    /// open, or a LaunchAgent starts a program from it, is checked when the
    /// list is built and again right before the move.
    ///
    /// The folder must be below home, outside `~/Library`, where Xcode's own
    /// DerivedData and the caches have rules of their own, and stay there with
    /// every link resolved. The never-delete lists are asked again with that
    /// path: they compare text with case, and `realpath` gives the case on
    /// disk, so `~/pictures/…` can't pass for a folder outside `~/Pictures`.
    static func isWhitelistedPath(_ path: String, home: String) -> Bool {
        guard isAllowedLocation(path, home: home), mark(at: path) != nil else { return false }
        guard let realHome = realPath(home), let real = realPath(path),
              isAllowedLocation(real, home: realHome) else { return false }
        return !DeletionSafetyPolicy.neverDeletePrefixes(home: realHome).contains {
            PathContainment.isSameOrInside(real, $0)
        } && !DeletionSafetyPolicy.neverDeleteExactPaths(home: realHome).contains(real)
    }

    static func isAllowedLocation(_ path: String, home: String) -> Bool {
        PathContainment.isInside(path, home) && !PathContainment.isSameOrInside(path, "\(home)/Library")
    }

    // MARK: - Discovery

    /// The folders the walk starts from: the project folders Dev Projects
    /// walks, and the folders the user added in Settings that sit in home.
    /// Home itself is looked at one level deep.
    static func searchRoots(home: URL) -> [URL] {
        let homePath = home.standardizedFileURL.path
        let added = ScanFolders.snapshot
            .filter { isAllowedLocation($0, home: homePath) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        return DevScanner.projectSearchRoots(home: home) + added
    }

    /// One row per build folder found. Each is remembered as offered, so the
    /// move is refused if it loses Xcode's mark later.
    static func definitions(home: URL, access: ScanAccess) -> [(label: String, paths: [URL])] {
        let folders = buildFolders(in: searchRoots(home: home), home: home, access: access)
        recordOffered(folders)
        return folders.map { (labelPrefix + $0.path, [$0]) }
    }

    // MARK: - Folders offered

    /// Every build folder a scan offered since launch. Only grows: a folder
    /// offered once must keep its mark to move, even after a later scan.
    private static let offered = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func recordOffered(_ folders: [URL]) {
        let paths = folders.map { $0.standardizedFileURL.path }
        offered.withLock { $0.formUnion(paths) }
    }

    static func wasOffered(_ path: String) -> Bool {
        offered.withLock { $0.contains(path) }
    }

    /// Recent answers for the on-screen list, which asks on the main thread
    /// for every row on every scan flush.
    private static let recentReads = OSAllocatedUnfairLock<[String: (Date, Bool)]>(initialState: [:])
    static let recentReadLifetime: TimeInterval = 2

    /// `isOfferedForCleanup`'s uncached refusal: a folder offered as a build
    /// folder that no longer has Xcode's mark, because someone saved a file
    /// at its top or removed `info.plist`. The list may reuse a read from the
    /// last two seconds; a move always reads the folder again.
    static func refusesDeletion(_ url: URL, reuseRecentRead: Bool = false, now: Date = Date()) -> Bool {
        let path = url.standardizedFileURL.path
        guard wasOffered(path) else { return false }
        if reuseRecentRead,
           let (time, refused) = recentReads.withLock({ $0[path] }),
           now.timeIntervalSince(time) < recentReadLifetime {
            return refused
        }
        let refused = mark(at: path) == nil
        recentReads.withLock { $0[path] = (now, refused) }
        return refused
    }

    /// Build folders in `roots`, each once, leaving out any that a process has
    /// open or a LaunchAgent starts a program from. When the open files can't
    /// be listed, none is offered: an empty answer is not proof that nothing
    /// is open.
    static func buildFolders(
        in roots: [URL],
        home: URL,
        access: ScanAccess,
        depth: Int = walkDepth,
        lister: OpenFileCheck.Lister = OpenFileCheck.liveListing
    ) -> [URL] {
        let found = walk(roots, home: home, access: access, depth: depth)
        guard !found.isEmpty, let listing = lister() else { return [] }
        // The listing and the LaunchAgents are read once for every folder:
        // asking per folder read them a hundred times on a Mac with a hundred.
        var folderBySpelling: [String: String] = [:]
        for folder in found {
            for spelling in OpenFileCheck.spellings(of: folder) { folderBySpelling[spelling] = folder.path }
        }
        var excluded = foldersNamed(in: listing, folderBySpelling: folderBySpelling)
        for program in launchAgentPrograms(home: home) {
            excluded.formUnion(foldersHolding(program, folderBySpelling: folderBySpelling))
        }
        return found.filter { !excluded.contains($0.path) }
    }

    /// The folders, by their walked path, that any name in an `lsof -F pcn`
    /// listing is in: a file open there, a working folder or a program.
    static func foldersNamed(in listing: String, folderBySpelling: [String: String]) -> Set<String> {
        var result: Set<String> = []
        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) where line.first == "n" {
            result.formUnion(foldersHolding(String(line.dropFirst()), folderBySpelling: folderBySpelling))
        }
        return result
    }

    /// The folders `path` is, or is inside, found by its own leading parts.
    static func foldersHolding(_ path: String, folderBySpelling: [String: String]) -> Set<String> {
        var result: Set<String> = []
        if let folder = folderBySpelling[path] { result.insert(folder) }
        var prefix = Substring(path)
        while let slash = prefix.lastIndex(of: "/"), slash > prefix.startIndex {
            prefix = prefix[..<slash]
            if let folder = folderBySpelling[String(prefix)] { result.insert(folder) }
        }
        return result
    }

    /// The programs the user's LaunchAgents start, as
    /// `CommandLineToolScanPolicy.launchAgents` reads each job: each as the
    /// job names it and with every link resolved, so a program reached
    /// through a link, or spelled in another case, still counts.
    static func launchAgentPrograms(home: URL) -> [String] {
        let root = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true).path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".plist") }.flatMap { name -> [String] in
            let plist = "\(root)/\(name)"
            guard isRegularFile(plist),
                  let contents = NSDictionary(contentsOfFile: plist) as? [String: Any],
                  let label = contents["Label"] as? String, !label.isEmpty,
                  let program = CommandLineToolScanPolicy.startedProgram(contents),
                  program.hasPrefix("/") else { return [] }
            let named = URL(fileURLWithPath: program).standardizedFileURL.path
            return [named] + (realPath(program).map { [$0] } ?? [])
        }
    }

    /// Whether any LaunchAgent starts a program from `folder`, matched
    /// against every spelling of the folder.
    static func launchAgentStartsProgram(from folder: URL, home: URL) -> Bool {
        var folderBySpelling: [String: String] = [:]
        for spelling in OpenFileCheck.spellings(of: folder) { folderBySpelling[spelling] = folder.path }
        return launchAgentPrograms(home: home).contains {
            !foldersHolding($0, folderBySpelling: folderBySpelling).isEmpty
        }
    }

    /// The walk alone. It never follows a link, never enters a hidden folder,
    /// an app or other bundle, a project's own build output (Dev Projects
    /// offers that), or a folder it found, so a build folder is never inside
    /// another one on the list. Without Full Disk Access it skips the
    /// protected folders, such as Documents, before reading them.
    ///
    /// Like the project walk, it never enters a network share or other
    /// mount that is not a local disk, or a folder excluded from scans, and
    /// below a folder added in Settings it skips a copy of a Mac or a home
    /// folder, a backup, and a folder another sync service keeps
    /// (`ScanFolders.isOffLimits`).
    static func walk(
        _ roots: [URL],
        home: URL,
        access: ScanAccess,
        depth: Int = walkDepth,
        addedRoots: [String]? = nil,
        nonLocalMounts: Set<String>? = nil
    ) -> [URL] {
        let fm = FileManager.default
        let homePath = home.standardizedFileURL.path
        let libraryPath = "\(homePath)/Library"
        let protectedRoots = ProtectedLocations.resolvedRootPaths(home: home)
        let added = addedRoots ?? ScanFolders.snapshot
        // Both spellings, since a listing may spell `/var/…` as `/private/var/…`.
        let foreignMounts = Set((nonLocalMounts ?? AppFolders.nonLocalMountPaths()).flatMap { [$0, "/private" + $0] })
        // The listing hands back each entry's type, so a file costs no `lstat`.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let keySet = Set(keys)

        func mayEnter(_ path: String) -> Bool {
            guard PathContainment.isInside(path, homePath),
                  !PathContainment.isSameOrInside(path, libraryPath),
                  !foreignMounts.contains(path) else { return false }
            guard access == .full || !ProtectedLocations.isPath(path, inAnyOf: protectedRoots) else { return false }
            return !ExcludedPathsStore.isExcluded(URL(fileURLWithPath: path, isDirectory: true))
        }

        // (folder, how many more levels below it may be looked at). Roots are
        // told apart by the folder on disk, not the spelling: on a volume that
        // ignores case, `~/Developer` and `~/developer` are one folder.
        var level: [(String, Int)] = []
        var seenRoots: Set<FolderIdentity> = []
        for root in roots {
            let path = root.standardizedFileURL.path
            let isHome = path == homePath
            guard isHome || mayEnter(path), isRealFolder(path),
                  let identity = FolderIdentity(path), seenRoots.insert(identity).inserted else { continue }
            level.append((path, isHome ? 1 : depth))
        }

        var found: [String] = []
        var foundIdentities: Set<FolderIdentity> = []
        var visited: Set<FolderIdentity> = []
        while !level.isEmpty, !Task.isCancelled {
            let reads = ConcurrentMap.values(level) { item -> (found: [String], next: [(String, Int)]) in
                let (folder, remaining) = item
                guard let entries = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: folder, isDirectory: true),
                        includingPropertiesForKeys: keys
                      ),
                      entries.count <= maxEntriesPerFolder else { return ([], []) }
                // Judged from the listing just read, as the project walk does.
                if added.contains(where: { PathContainment.isInside(folder, $0) }),
                   ScanFolders.isOffLimits(
                    name: URL(fileURLWithPath: folder).lastPathComponent,
                    childNames: Set(entries.map(\.lastPathComponent))
                   ) {
                    return ([], [])
                }
                var hits: [String] = []
                var next: [(String, Int)] = []
                for entry in entries {
                    // Both keys describe the entry itself, so a link is never followed.
                    guard let values = try? entry.resourceValues(forKeys: keySet),
                          values.isSymbolicLink != true, values.isDirectory == true else { continue }
                    // The path is built from the folder's, not the entry's URL,
                    // so it is spelled the way the walk reached it.
                    let name = entry.lastPathComponent
                    guard !name.hasPrefix("."), !skipsName(name) else { continue }
                    let child = "\(folder)/\(name)"
                    guard mayEnter(child), isRealFolder(child) else { continue }
                    if mark(at: child) != nil {
                        hits.append(child)
                    } else if remaining > 1 {
                        next.append((child, remaining - 1))
                    }
                }
                return (hits, next)
            }
            level = []
            for read in reads {
                for hit in read.found {
                    guard let identity = FolderIdentity(hit), foundIdentities.insert(identity).inserted else { continue }
                    found.append(hit)
                }
                level += read.next.filter { FolderIdentity($0.0).map { visited.insert($0).inserted } ?? false }
            }
        }
        return found.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// A folder's device and inode, from `lstat`.
    struct FolderIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init?(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// Names the walk never looks into or offers: bundles, and the build output
    /// Dev Projects offers inside a project. A folder named `DerivedData` is
    /// walked, since Xcode's Locations setting can put one anywhere and each
    /// project's build folder sits inside it.
    static func skipsName(_ name: String) -> Bool {
        if name == "DerivedData" { return false }
        if AppBundleReach.isBundleFolderName(name) { return true }
        if name.lowercased().hasSuffix(".xcarchive") { return true }
        return ProjectArtifactCatalog.artifactFolderNames.contains(name)
    }

    // MARK: - Rows

    /// The folder a row's label names, or nil for any other row.
    static func folderPath(inLabel label: String) -> String? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        let path = String(label.dropFirst(labelPrefix.count))
        return path.hasPrefix("/") ? path : nil
    }

    /// The row's headline and explanation, from the folder's `info.plist`.
    /// `projectExists` is nil when Purge may not look: a project in Documents
    /// without Full Disk Access.
    static func safetyInfo(forFolder path: String, home: URL, access: ScanAccess) -> SafetyInfo {
        let base = SafetyInfo.fromExplanationDatabase(key: explanationKey, friendlyFallback: labelPrefix + path)
        let name = displayName(ofFolder: path, home: home)
        guard let mark = readInfoPlist(at: "\(path)/info.plist") else {
            return SafetyInfo(
                level: base.level,
                headline: String(localized: "Xcode Build Files in \(name)"),
                explanation: base.explanation,
                recoverySteps: base.recoverySteps,
                reinstallCommand: nil
            )
        }
        let workspace = URL(fileURLWithPath: mark.workspacePath)
        let projectExists: Bool? = ProtectedLocations.isReadable(workspace, access: access, home: home)
            ? FileManager.default.fileExists(atPath: mark.workspacePath)
            : nil
        return SafetyInfo(
            level: base.level,
            headline: String(localized: "Xcode Build Files in \(name)"),
            explanation: explanation(
                project: projectName(of: mark.workspacePath),
                lastBuilt: mark.lastAccessed,
                projectExists: projectExists,
                rebuildNote: base.explanation
            ),
            recoverySteps: base.recoverySteps,
            reinstallCommand: nil
        )
    }

    /// The folder's name, with its parent's in front when the parent is not
    /// one of the folders the walk starts from: a build folder inside a
    /// release folder reads `release-1.18.1/dd`, not a bare `dd`.
    static func displayName(ofFolder path: String, home: URL) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        let roots = Set((searchRoots(home: home) + [home]).map { $0.standardizedFileURL.path })
        guard !roots.contains(parent.path) else { return url.lastPathComponent }
        return "\(parent.lastPathComponent)/\(url.lastPathComponent)"
    }

    /// One or two sentences on what was built and when. A project that is gone
    /// says so in place of the note that Xcode builds the files again.
    static func explanation(project: String, lastBuilt: Date?, projectExists: Bool?, rebuildNote: String) -> String {
        let built: String
        if let lastBuilt {
            let date = lastBuilt.formatted(date: .abbreviated, time: .omitted)
            built = String(localized: "Built from \(project) on \(date).")
        } else {
            built = String(localized: "Built from \(project).")
        }
        if projectExists == false {
            return built + " " + String(localized: "That project is no longer on this Mac.")
        }
        return built + " " + rebuildNote
    }

    // MARK: - Right before the move

    /// `FileDeleter`'s last check, run again right before the move. A folder
    /// a scan offered must still have Xcode's mark: a file saved at its top
    /// after the scan, or `info.plist` removed, keeps it where it is. Any
    /// other path without the mark passes untouched. A build folder passes
    /// only while it is on a local disk, not below an off-limits folder in a
    /// folder added in Settings, no process has a file open in it, works in
    /// it or runs from it, and no LaunchAgent starts a program from it. When
    /// the open files can't be listed it stays.
    static func passesImmediateTrashBoundary(
        _ url: URL,
        home: String,
        lister: OpenFileCheck.Lister = OpenFileCheck.liveListing,
        nonLocalMounts: Set<String>? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard mark(at: path) != nil else { return !wasOffered(path) }
        guard isAllowedLocation(path, home: home) else { return !wasOffered(path) }
        let mounts = nonLocalMounts ?? AppFolders.nonLocalMountPaths()
        let spellings = OpenFileCheck.spellings(of: url)
        guard !spellings.contains(where: { spelling in
            mounts.contains { PathContainment.isSameOrInside(spelling, $0) || PathContainment.isSameOrInside(spelling, "/private" + $0) }
        }) else { return false }
        if let root = ScanFolders.snapshot.first(where: { PathContainment.isInside(path, $0) }),
           ScanFolders.crossesOffLimits(from: root, to: url) {
            return false
        }
        guard OpenFileCheck.check(folders: [url], lister: lister) == .free else { return false }
        return !launchAgentStartsProgram(from: url, home: URL(fileURLWithPath: home, isDirectory: true))
    }

    // MARK: - Disk helpers

    static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
