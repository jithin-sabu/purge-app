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

    /// Most entries the activity walk reads in one project. Hitting the limit counts
    /// as "no recent activity found", so a huge project falls back to its git and
    /// artifact dates.
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
        let spellings = pathSpellings(of: projectRoot, access: access, home: home)
        let hasProcessInside = live.workingDirectories.contains { directory in
            spellings.contains { directory == $0 || directory.hasPrefix($0 + "/") }
        }
        if hasProcessInside { return true }

        guard let gitDir = gitDirectory(forProject: projectRoot, access: access, home: home) else {
            return false
        }
        return gitLockFiles.contains { modificationDate(gitDir.appendingPathComponent($0)) != nil }
    }

    /// Whether anything in the project changed after `cutoff`. Cheap signals first,
    /// then a bounded walk that stops at the first recent entry.
    static func hasActivity(
        since cutoff: Date,
        projectRoot: URL,
        artifactPaths: [URL],
        access: ScanAccess,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        entryLimit: Int = walkEntryLimit
    ) -> Bool {
        func isRecent(_ url: URL) -> Bool {
            guard let date = modificationDate(url) else { return false }
            return date > cutoff
        }

        // The artifact folders' own dates are what the scan used before, so the new
        // rule can only hide more than the old one did, never list more.
        if artifactPaths.contains(where: isRecent) { return true }

        if let gitDir = gitDirectory(forProject: projectRoot, access: access, home: home),
           gitActivityFiles.contains(where: { isRecent(gitDir.appendingPathComponent($0)) }) {
            return true
        }

        if isRecent(projectRoot) { return true }
        // A project rooted at home would walk Documents, Desktop, and Library.
        guard projectRoot.path != home.path else { return false }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return false }

        var entriesRead = 0
        for case let url as URL in enumerator {
            entriesRead += 1
            if entriesRead > entryLimit { return false }

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            if let date = values.contentModificationDate, date > cutoff { return true }

            guard values.isDirectory == true else { continue }
            // Dependency and build trees change on install or build, can hold
            // hundreds of thousands of files, and are what is being offered.
            if url.lastPathComponent == ".git"
                || ProjectArtifactCatalog.artifactFolderNames.contains(url.lastPathComponent)
                || !ProtectedLocations.isReadable(url, access: access, home: home) {
                enumerator.skipDescendants()
            }
        }
        return false
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
    static func allProcessIDs() -> [pid_t]? {
        let bytesNeeded = proc_listallpids(nil, 0)
        guard bytesNeeded > 0 else { return nil }
        let capacity = Int(bytesNeeded) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: max(capacity, 1))
        let filledBytes = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard filledBytes > 0 else { return nil }
        let count = Int(filledBytes) / MemoryLayout<pid_t>.size
        return pids.prefix(count).filter { $0 > 0 }
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
        var directories: Set<String> = []
        for pid in allProcessIDs() ?? [] {
            guard let cwd = currentWorkingDirectory(of: pid), !cwd.isEmpty, cwd != "/" else { continue }
            directories.insert((cwd as NSString).standardizingPath)
        }
        return directories
    }
}
