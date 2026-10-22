import Darwin
import Foundation

/// Whether a project's rebuildable folders are offered at all (issue #67).
///
/// Both checks look at the project, never at the artifact folder alone:
///
/// 1. In use right now: a process is working inside the project, or git holds a
///    lock on it. Hidden whatever the age setting says, the same rule as Cursor
///    leftovers (#60).
/// 2. Used lately: the "Consider stale after" age is measured from the newest sign
///    of use anywhere in the project. A `node_modules` folder only changes date
///    when packages are added or removed, so on its own it says when `npm install`
///    last ran, not whether anyone still works on the project.
///
/// When a signal can't be read, the project is judged on the signals that can,
/// which at worst is how the scan behaved before this existed.
nonisolated enum ProjectActivityPolicy {
    struct LiveContext: Sendable {
        /// Working directories of the user's running processes, as the kernel
        /// reports them (symlinks resolved).
        var workingDirectories: Set<String>

        static let none = LiveContext(workingDirectories: [])

        static func current() -> LiveContext {
            LiveContext(workingDirectories: ProcessWorkingDirectories.allDirectories())
        }
    }

    /// Most entries the activity walk reads in one project. Hitting the limit gives
    /// `.tooBigToCheck`: the project is offered, but only as Check First.
    static let walkEntryLimit = 20_000

    /// Files git rewrites on commit, checkout, fetch, and index refresh.
    static let gitActivityFiles = ["index", "HEAD", "logs/HEAD", "FETCH_HEAD", "ORIG_HEAD"]

    static let gitLockFiles = ["index.lock", "HEAD.lock"]

    static func isInUse(
        projectRoot: URL,
        live: LiveContext,
        access: ScanAccess,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        // Ignores case, like the default APFS volume: a shell in `~/developer/app`
        // is working in `~/Developer/app` (#175). On a case-sensitive volume this
        // only errs toward hiding a project.
        let spellings = pathSpellings(of: projectRoot, access: access, home: home).map { $0.lowercased() }
        let hasProcessInside = live.workingDirectories.contains { directory in
            let directory = directory.lowercased()
            return spellings.contains { directory == $0 || directory.hasPrefix($0 + "/") }
        }
        if hasProcessInside { return true }

        guard let gitDir = gitDirectory(forProject: projectRoot, access: access, home: home) else {
            return false
        }
        return gitLockFiles.contains { modificationDate(gitDir.appendingPathComponent($0)) != nil }
    }

    /// What the activity check found. A walk that stopped at its limit has proved
    /// nothing either way, so it is neither recent nor unused.
    enum Activity: Equatable {
        case recent
        case none
        case tooBigToCheck
    }

    /// Folders nobody edits by hand, skipped wherever they sit in the project:
    /// dependency trees and tool caches that can hold hundreds of thousands of
    /// files. Generic names such as build, bin or vendor are not here, because a
    /// project can keep its own scripts in them. Those are skipped only when they
    /// are the folder being offered.
    static let neverEditedFolderNames: Set<String> = [
        ".git", "node_modules", "venv", "Pods", "DerivedDataCache", "dist-newstyle", "zig-cache",
    ]

    static func isNeverEdited(folderName name: String) -> Bool {
        neverEditedFolderNames.contains(name)
            || (name.hasPrefix(".") && ProjectArtifactCatalog.artifactFolderNames.contains(name))
    }

    /// Whether a folder with an artifact's name sits in a project of the kind that
    /// produces it, such as `app/build` next to `app/build.gradle` in a multi-module
    /// Gradle project. That module is offered as its own project, so its output is
    /// not in the root's `artifactPaths`, but it is still build output. A Node
    /// project's own `build/` scripts match no rule and are read.
    static func isBuildOutput(_ url: URL, named name: String) -> Bool {
        ProjectArtifactCatalog.rules.contains { rule in
            let parts = rule.folder.split(separator: "/").map(String.init)
            guard parts.last == name else { return false }
            var root = url
            for part in parts.reversed() {
                guard root.lastPathComponent == part else { return false }
                root.deleteLastPathComponent()
            }
            return rule.matchesRoot(root)
        }
    }

    /// Whether anything in the project changed after `cutoff`. Cheap signals first,
    /// then a bounded walk that stops at the first recent entry.
    static func activity(
        since cutoff: Date,
        projectRoot: URL,
        artifactPaths: [URL],
        access: ScanAccess,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        entryLimit: Int = walkEntryLimit
    ) -> Activity {
        func isRecent(_ url: URL) -> Bool {
            guard let date = modificationDate(url) else { return false }
            return date > cutoff
        }

        // The artifact folders' own dates are what the scan used before, so the new
        // rule can only hide more than the old one did, never list more.
        if artifactPaths.contains(where: isRecent) { return .recent }

        if let gitDir = gitDirectory(forProject: projectRoot, access: access, home: home),
           gitActivityFiles.contains(where: { isRecent(gitDir.appendingPathComponent($0)) }) {
            return .recent
        }

        if isRecent(projectRoot) { return .recent }
        // A project rooted at home would walk Documents, Desktop, and Library.
        guard projectRoot.path != home.path else { return .none }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return .none }

        // Compared in resolved form: the enumerator can spell a path differently from
        // the URL the artifact was built from.
        let offeredPaths = Set(artifactPaths.map { $0.resolvingSymlinksInPath().path })

        var entriesRead = 0
        for case let url as URL in enumerator {
            entriesRead += 1
            if entriesRead > entryLimit { return .tooBigToCheck }

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            if let date = values.contentModificationDate, date > cutoff { return .recent }

            guard values.isDirectory == true else { continue }
            let name = url.lastPathComponent
            if isNeverEdited(folderName: name)
                || (ProjectArtifactCatalog.artifactFolderNames.contains(name)
                    && (offeredPaths.contains(url.resolvingSymlinksInPath().path)
                        || isBuildOutput(url, named: name)))
                || !ProtectedLocations.isReadable(url, access: access, home: home) {
                enumerator.skipDescendants()
            }
        }
        return .none
    }

    /// The git dir of the repository holding the project, which may sit above it in
    /// a monorepo. Stops below home: a dotfiles repo at `~` would make every project
    /// look busy.
    static func gitDirectory(forProject projectRoot: URL, access: ScanAccess, home: URL) -> URL? {
        let homePath = home.path
        var candidate = projectRoot
        while candidate.path.hasPrefix(homePath + "/") {
            let dotGit = candidate.appendingPathComponent(".git", isDirectory: false)
            if modificationDate(dotGit) != nil {
                guard ProtectedLocations.isReadable(dotGit, access: access, home: home),
                      let gitDir = GitRepositoryFinder.gitDirectory(forRepository: candidate),
                      ProtectedLocations.isReadable(gitDir, access: access, home: home) else {
                    return nil
                }
                return gitDir
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    /// `lstat` date: a link is not followed, so it never reaches into a protected
    /// folder on a limited scan.
    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The root as discovered plus its real path, since process working directories
    /// come back with symlinks resolved.
    private static func pathSpellings(of root: URL, access: ScanAccess, home: URL) -> [String] {
        var spellings = [root.path]
        let resolved: String?
        switch access {
        case .limited:
            resolved = ProtectedLocations.readablePath(of: root, home: home)
        case .full:
            resolved = root.resolvingSymlinksInPath().path
        }
        if let resolved, resolved != root.path { spellings.append(resolved) }
        return spellings
    }
}

/// Working directories of running processes, read with `proc_pidinfo`. Only the
/// user's own processes can be inspected; the rest are skipped.
nonisolated enum ProcessWorkingDirectories {
    /// `proc_listallpids` returns a number of pids from both calls, not bytes.
    /// Reading it as bytes divided by 4 twice and saw about 1 process in 16.
    static func allProcessIDs() -> [pid_t]? {
        let countNeeded = proc_listallpids(nil, 0)
        guard countNeeded > 0 else { return nil }
        // Headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(countNeeded) + 64)
        let filled = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard filled > 0 else { return nil }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func currentWorkingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
        guard result == Int32(size) else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { chars in
                String(cString: chars)
            }
        }
    }

    /// Every inspectable process's working directory, minus `/`, where most apps sit.
    static func allDirectories() -> Set<String> {
        allDirectoriesIfReadable() ?? []
    }

    /// Nil when the process list itself could not be read, so a caller can tell
    /// "nothing is in use" from "could not look".
    static func allDirectoriesIfReadable() -> Set<String>? {
        guard let pids = allProcessIDs() else { return nil }
        var directories: Set<String> = []
        for pid in pids {
            guard let cwd = currentWorkingDirectory(of: pid), !cwd.isEmpty, cwd != "/" else { continue }
            directories.insert((cwd as NSString).standardizingPath)
        }
        return directories
    }
}
