import Foundation

/// Git worktrees that AI coding tools make for parallel agents (issue #61).
///
/// Each tool keeps its checkouts in a folder of its own. A checkout is listed
/// only once its repository no longer has it registered
/// (`GitWorktreeRegistration`): one that is still attached never shows however
/// long it sat idle, and an orphan shows even if it is new. A checkout a running
/// process is working inside, that Cursor has open, or that holds a Git lock
/// stays off the list too. Age is never a gate.
nonisolated enum AgentWorktreeScanPolicy {
    static let toolLabel = "Orphaned Git Worktrees"
    static let explanationKey = "orphaned-git-worktree"

    /// Home-relative folders the tools keep worktrees in, two levels deep:
    /// `<root>/<repo>/<name>`, or `<root>/<id>/<repo>` for Codex.
    static let homeRoots: [String] = [
        ".cursor/worktrees",    // Cursor
        ".codex/worktrees",     // Codex app
        "conductor/workspaces", // Conductor
        ".t3/worktrees"         // T3 Code
    ]

    /// Claude Code puts them inside the project: `<project>/.claude/worktrees/<name>`.
    static let projectRelativeRoot = ".claude/worktrees"

    struct LiveContext: Equatable {
        /// Working directories of every running process. Nil when the process list
        /// could not be read; then nothing is listed, because a worktree in use
        /// cannot be told apart from one that is not.
        var processWorkingDirectories: Set<String>?
        /// Folders open in Cursor windows.
        var openWorkspacePaths: Set<String>

        static func current(home: URL) -> LiveContext {
            let cursorSupport = home
                .appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
            return LiveContext(
                processWorkingDirectories: ProcessWorkingDirectories.allDirectoriesIfReadable(),
                openWorkspacePaths: CursorAgentLeftoverScanPolicy.readOpenWindows(from: cursorSupport).folders
            )
        }
    }

    // MARK: - Discovery

    /// Orphaned, idle worktrees from every tool, in a stable order.
    static func orphanedWorktrees(
        home: URL,
        claudeProjects: [URL],
        live: LiveContext,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard live.processWorkingDirectories != nil else { return [] }
        var seen: Set<String> = []
        return candidates(home: home, claudeProjects: claudeProjects, fileManager: fileManager).filter {
            seen.insert($0.path).inserted
                && GitWorktreeRegistration.state(of: $0, fileManager: fileManager) == .orphaned
                && !isLive($0, live: live, fileManager: fileManager)
        }
    }

    static func candidates(home: URL, claudeProjects: [URL], fileManager: FileManager = .default) -> [URL] {
        let fromHomeRoots = homeRoots.flatMap {
            twoLevelLeaves(in: home.appendingPathComponent($0, isDirectory: true), fileManager: fileManager)
        }
        let fromProjects = claudeProjects.flatMap {
            directChildrenWithGit(
                in: $0.appendingPathComponent(projectRelativeRoot, isDirectory: true),
                fileManager: fileManager
            )
        }
        return fromHomeRoots + fromProjects
    }

    /// Project folders Claude Code has been used in, from `~/.claude.json`. Only
    /// folders inside home: the deletion gate never reaches outside it.
    static func claudeCodeProjects(home: URL) -> [URL] {
        let config = home.appendingPathComponent(".claude.json", isDirectory: false)
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var paths: [String] = []
        if let projects = json["projects"] as? [String: Any] {
            paths += projects.keys
        }
        if let repos = json["githubRepoPaths"] as? [String: Any] {
            for case let list as [String] in repos.values {
                paths += list
            }
        }
        let homePath = home.standardizedFileURL.path
        var seen: Set<String> = []
        return paths
            .map { ($0 as NSString).standardizingPath }
            .filter { $0.hasPrefix(homePath + "/") && seen.insert($0).inserted }
            .sorted()
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func isLive(_ url: URL, live: LiveContext, fileManager: FileManager = .default) -> Bool {
        let path = url.standardizedFileURL.path
        let isInside: (String) -> Bool = { $0 == path || $0.hasPrefix(path + "/") }
        if live.openWorkspacePaths.contains(where: isInside) { return true }
        if live.processWorkingDirectories?.contains(where: isInside) ?? true { return true }
        return hasGitLock(at: url, fileManager: fileManager)
    }

    // MARK: - Deletion gate (path shape)

    /// A leaf under one of the tools' home folders. Checked ahead of the
    /// never-delete rules, like Cursor's other leftovers.
    static func isWhitelistedHomeRootPath(_ path: String, home: String) -> Bool {
        for root in homeRoots.map({ "\(home)/\($0)" }) where path.hasPrefix(root + "/") {
            let parts = path.dropFirst(root.count + 1)
                .split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
                return false
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return !containsSymlinkComponent(url, home: home)
                && staysInside(root: root, url: url, home: home)
                && hasGitMarker(at: url, fileManager: .default)
        }
        return false
    }

    /// `<project>/.claude/worktrees/<name>` whose `.git` is a linked-worktree
    /// file. Checked after the never-delete rules, like project build folders,
    /// since the project can be anywhere in home.
    static func isWhitelistedProjectWorktreePath(_ path: String, home: String) -> Bool {
        let marker = "/" + projectRelativeRoot + "/"
        guard path.hasPrefix(home + "/"),
              let range = path.range(of: marker, options: .backwards) else {
            return false
        }
        let name = path[range.upperBound...]
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return false }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard !containsSymlinkComponent(url, home: home) else { return false }
        var info = stat()
        guard lstat(url.appendingPathComponent(".git").path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG
    }

    /// The worktree folder itself, by position alone. Never what is inside one, so
    /// a project's build folders in a worktree keep their own rules.
    static func looksLikeAgentWorktreePath(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        for root in homeRoots.map({ "\(homePath)/\($0)/" }) where path.hasPrefix(root) {
            return (1...2).contains(path.dropFirst(root.count).split(separator: "/").count)
        }
        guard let range = path.range(of: "/" + projectRelativeRoot + "/", options: .backwards) else {
            return false
        }
        let name = path[range.upperBound...]
        return !name.isEmpty && !name.contains("/")
    }

    /// The last check before Trash: the path shape, and the repository still not
    /// listing the folder. Purge never trashes a checkout its repository lists,
    /// even if the repository took it back after the scan.
    static func passesImmediateTrashBoundary(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard isWhitelistedHomeRootPath(path, home: homePath)
                || isWhitelistedProjectWorktreePath(path, home: homePath) else {
            return false
        }
        return GitWorktreeRegistration.state(of: URL(fileURLWithPath: path, isDirectory: true)) == .orphaned
    }

    // MARK: - Layout

    /// `<root>/<a>/<b>` leaves with a `.git`; `<root>/<a>` itself when it has one
    /// and no child does. The root and grouping folders are never leaves, so a
    /// live checkout next to an orphan cannot be swept with it.
    static func twoLevelLeaves(in root: URL, fileManager: FileManager) -> [URL] {
        var leaves: [URL] = []
        for group in subdirectories(of: root, fileManager: fileManager) {
            let children = directChildrenWithGit(in: group, fileManager: fileManager)
            if !children.isEmpty {
                leaves += children
            } else if hasGitMarker(at: group, fileManager: fileManager) {
                leaves.append(group)
            }
        }
        return leaves
    }

    static func directChildrenWithGit(in folder: URL, fileManager: FileManager) -> [URL] {
        subdirectories(of: folder, fileManager: fileManager).filter {
            hasGitMarker(at: $0, fileManager: fileManager)
        }
    }

    /// Dot-names are skipped by hand: `.skipsHiddenFiles` also drops entries with the
    /// hidden flag, and Claude Code's `.claude` folder and everything in it carry it.
    private static func subdirectories(of url: URL, fileManager: FileManager) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return [] }
        return entries.compactMap { entry in
            guard !entry.lastPathComponent.hasPrefix(".") else { return nil }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
            return URL(fileURLWithPath: url.path, isDirectory: true)
                .appendingPathComponent(entry.lastPathComponent, isDirectory: true)
        }
        .sorted { $0.path < $1.path }
    }

    // MARK: - Internals

    static func hasGitMarker(at url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    static func hasGitLock(at url: URL, fileManager: FileManager) -> Bool {
        let git = url.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: git.path, isDirectory: &isDir) else { return false }
        let gitDir: URL
        if isDir.boolValue {
            gitDir = git
        } else if let linked = GitRepositoryFinder.gitDirectory(forRepository: url) {
            gitDir = linked
        } else {
            return false
        }
        return ["index.lock", "HEAD.lock", "locked"].contains {
            fileManager.fileExists(atPath: gitDir.appendingPathComponent($0).path)
        }
    }

    static func containsSymlinkComponent(_ url: URL, home: String) -> Bool {
        let path = url.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return true }
        var current = URL(fileURLWithPath: home, isDirectory: true)
        for part in path.dropFirst(home.count).split(separator: "/") {
            current.appendPathComponent(String(part))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return true
            }
        }
        return false
    }

    /// The root itself must not be reached through a link, and the path must
    /// resolve to somewhere under it.
    private static func staysInside(root: String, url: URL, home: String) -> Bool {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard !containsSymlinkComponent(rootURL, home: home) else { return false }
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedRoot == root else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(resolvedRoot + "/")
    }
}
