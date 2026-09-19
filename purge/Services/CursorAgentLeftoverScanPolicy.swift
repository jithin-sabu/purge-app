import AppKit
import Darwin
import Foundation

/// Cursor leftover agent folders (issue #60).
///
/// Two layouts, both huge in the wild and both easy to confuse with a live job:
///
/// 1. Parallel-agent Git checkouts under `~/.cursor/worktrees/<project>/<id>`.
/// 2. Junk per-cwd namespaces under `~/.cursor/projects/` left by temp
///    directories (`var-folders-*`, `tmp-*`) and abandoned empty windows
///    (numeric backup ids).
///
/// Age is never a gate. A folder from this morning can already be junk; one
/// from months ago can still be a running agent. Live work is detected from
/// open Cursor windows, process working directories, Git locks, and whether
/// a temp workspace still exists. Settings, login, MCP config, extensions,
/// and real project namespaces are never offered. Chat history for a living
/// workspace is out of scope.
enum CursorAgentLeftoverScanPolicy {

    static let toolLabel = "Cursor Agent Leftovers"
    static let explanationKey = "cursor-agent-leftover"
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    nonisolated enum SnapshotStatus: Equatable {
        case available
        case unavailable
    }

    /// Snapshot of "is this folder still in use" signals. Production fills it
    /// from the running system; tests pass a fixture.
    nonisolated struct LiveContext: Equatable {
        var cursorIsRunning: Bool
        var openWorkspacePaths: Set<String>
        var emptyWindowBackupIDs: Set<String>
        var processWorkingDirectories: Set<String>
        /// Whether Cursor-related process cwd inspection finished. An empty
        /// cwd set is not evidence of success.
        var cursorProcessSnapshot: SnapshotStatus
        /// Whether `storage.json` was present and parsed. Missing or invalid
        /// data is unavailable, not "no windows".
        var windowsSnapshot: SnapshotStatus
        var temporaryDirectory: URL

        nonisolated static func current(
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> LiveContext {
            let cursorSupport = home
                .appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
            let windows = readOpenWindows(from: cursorSupport)
            let processes = CursorProcessWorkingDirectories.snapshot()
            return LiveContext(
                cursorIsRunning: isCursorRunning(),
                openWorkspacePaths: windows.folders,
                emptyWindowBackupIDs: windows.emptyWindowIDs,
                processWorkingDirectories: processes.directories,
                cursorProcessSnapshot: processes.status,
                windowsSnapshot: windows.status,
                temporaryDirectory: FileManager.default.temporaryDirectory.standardizedFileURL
            )
        }
    }

    // MARK: - Deletion gate (path shape only)

    /// Whether Purge may trash this path. Unused-ness is a scan filter, not a
    /// delete-time check — once the user has picked a listed folder, the gate
    /// only proves it is a leftover *kind*, never `~/.cursor` itself.
    nonisolated static func isEligibleForDeletion(_ url: URL, home: URL) -> Bool {
        isWhitelistedPath(url.standardizedFileURL.path, home: home.standardizedFileURL.path)
    }

    nonisolated static func isWhitelistedPath(_ path: String, home: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard !containsSymlinkComponent(url, home: home) else { return false }
        guard staysInsideIntendedCursorRoot(url, home: home) else { return false }

        let worktreesRoot = "\(home)/.cursor/worktrees/"
        if path.hasPrefix(worktreesRoot) {
            return isWhitelistedWorktreePath(path, prefix: worktreesRoot)
        }

        let projectsRoot = "\(home)/.cursor/projects/"
        if path.hasPrefix(projectsRoot) {
            let relative = String(path.dropFirst(projectsRoot.count))
            guard !relative.isEmpty, !relative.contains("/") else { return false }
            guard isJunkProjectSlug(relative) else { return false }
            if isNumericProjectSlug(relative),
               numericNamespacesBlockedByUnavailableWindows(home: home) {
                return false
            }
            return true
        }

        return false
    }

    nonisolated static func isJunkProjectSlug(_ name: String) -> Bool {
        if name.hasPrefix(".") { return false }
        if name.hasPrefix("var-folders-") { return true }
        if name.hasPrefix("tmp-") || name.hasPrefix("private-tmp-") {
            return uuidSuffix(in: name) != nil
        }
        return isNumericProjectSlug(name)
    }

    nonisolated static func isNumericProjectSlug(_ name: String) -> Bool {
        name.count >= 10 && name.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    /// Dev Tools trash leftover folders through `deleteItems`, not the
    /// privileged uninstall helper. Call this immediately before `trashItem`.
    nonisolated static func looksLikeCursorLeftoverPath(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        return path.hasPrefix("\(homePath)/.cursor/worktrees/")
            || path.hasPrefix("\(homePath)/.cursor/projects/")
    }

    nonisolated static func passesImmediateTrashBoundary(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        isWhitelistedPath(url.standardizedFileURL.path, home: home.standardizedFileURL.path)
    }

    // MARK: - Discovery

    /// Directories that exist on disk, match the leftover layouts, and look unused.
    nonisolated static func unusedDirectories(
        home: URL,
        live: LiveContext,
        fileManager: FileManager = .default
    ) -> [URL] {
        unusedWorktrees(home: home, live: live, fileManager: fileManager)
            + unusedJunkProjectNamespaces(home: home, live: live, fileManager: fileManager)
    }

    nonisolated static func unusedWorktrees(
        home: URL,
        live: LiveContext,
        fileManager: FileManager = .default
    ) -> [URL] {
        let root = home.appendingPathComponent(".cursor/worktrees", isDirectory: true)
        let leaves = worktreeLeaves(in: root, fileManager: fileManager)
        if live.cursorIsRunning && live.cursorProcessSnapshot != .available {
            return []
        }
        return leaves.filter { !isLiveWorktree($0, live: live, fileManager: fileManager) }
    }

    nonisolated static func unusedJunkProjectNamespaces(
        home: URL,
        live: LiveContext,
        fileManager: FileManager = .default
    ) -> [URL] {
        let root = home.appendingPathComponent(".cursor/projects", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { entry in
            let url = entry.standardizedFileURL
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let slug = url.lastPathComponent
            guard isJunkProjectSlug(slug) else { return nil }
            if isNumericProjectSlug(slug),
               live.cursorIsRunning && live.windowsSnapshot != .available {
                return nil
            }
            guard !isLiveJunkProject(slug: slug, live: live) else { return nil }
            return url
        }
    }

    // MARK: - Live detection

    nonisolated static func isLiveWorktree(
        _ url: URL,
        live: LiveContext,
        fileManager: FileManager = .default
    ) -> Bool {
        let path = url.standardizedFileURL.path
        if live.openWorkspacePaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
            return true
        }
        if live.processWorkingDirectories.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
            return true
        }
        return hasGitLock(at: url, fileManager: fileManager)
    }

    nonisolated static func isLiveJunkProject(slug: String, live: LiveContext) -> Bool {
        if live.emptyWindowBackupIDs.contains(slug) {
            return true
        }
        if live.openWorkspacePaths.contains(where: { encodedProjectSlug(for: $0) == slug }) {
            return true
        }
        if let temp = resolvedTemporaryWorkspace(slug: slug, live: live),
           FileManager.default.fileExists(atPath: temp.path) {
            return true
        }
        if live.processWorkingDirectories.contains(where: { encodedProjectSlug(for: $0) == slug }) {
            return true
        }
        return false
    }

    /// Cursor encodes a cwd as `~/.cursor/projects/<slug>` by stripping the
    /// leading slash and replacing `/` and `_` with `-`.
    nonisolated static func encodedProjectSlug(for absolutePath: String) -> String {
        var path = absolutePath
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        return path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    /// `var-folders-…-T-<uuid>` maps back onto `$TMPDIR/<uuid>` when the uuid
    /// is still a real temp workspace. Other junk slugs have no source path.
    nonisolated static func resolvedTemporaryWorkspace(slug: String, live: LiveContext) -> URL? {
        let uuid = uuidSuffix(in: slug)
        guard let uuid else { return nil }
        if slug.hasPrefix("var-folders-") || slug.hasPrefix("tmp-") || slug.hasPrefix("private-tmp-") {
            return live.temporaryDirectory.appendingPathComponent(uuid, isDirectory: true)
        }
        return nil
    }

    // MARK: - Worktree layout

    /// Leaves only. `~/.cursor/worktrees` and per-repo grouping folders stay
    /// untouched so a live checkout in the same project cannot be swept.
    nonisolated static func worktreeLeaves(in root: URL, fileManager: FileManager) -> [URL] {
        guard let projects = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var leaves: [URL] = []
        for project in projects {
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let projectURL = project.standardizedFileURL
            let children = directoryChildren(of: projectURL, fileManager: fileManager)
            let gitAtProject = hasGitMarker(at: projectURL, fileManager: fileManager)

            var yieldedChild = false
            for child in children where hasGitMarker(at: child, fileManager: fileManager) {
                leaves.append(child)
                yieldedChild = true
            }

            if !yieldedChild && gitAtProject {
                leaves.append(projectURL)
            }
        }
        return leaves
    }

    // MARK: - Internals

    private nonisolated static func isWhitelistedWorktreePath(_ path: String, prefix: String) -> Bool {
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty else { return false }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return false }
        if parts.count == 2 {
            return hasGitMarker(at: URL(fileURLWithPath: path, isDirectory: true), fileManager: .default)
        }
        if parts.count == 1 {
            return hasGitMarker(at: URL(fileURLWithPath: path, isDirectory: true), fileManager: .default)
        }
        return false
    }

    private nonisolated static func directoryChildren(of url: URL, fileManager: FileManager) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return entry.standardizedFileURL
        }
    }

    nonisolated static func hasGitMarker(at url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    nonisolated static func hasGitLock(at url: URL, fileManager: FileManager) -> Bool {
        let git = url.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: git.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue {
            return fileManager.fileExists(atPath: git.appendingPathComponent("index.lock").path)
                || fileManager.fileExists(atPath: git.appendingPathComponent("HEAD.lock").path)
        }
        guard let text = try? String(contentsOf: git, encoding: .utf8),
              let gitDir = gitDirPath(from: text) else {
            return false
        }
        return fileManager.fileExists(atPath: (gitDir as NSString).appendingPathComponent("index.lock"))
            || fileManager.fileExists(atPath: (gitDir as NSString).appendingPathComponent("HEAD.lock"))
            || fileManager.fileExists(atPath: (gitDir as NSString).appendingPathComponent("locked"))
    }

    private nonisolated static func gitDirPath(from gitFileContents: String) -> String? {
        for rawLine in gitFileContents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let prefix = "gitdir:"
            guard line.lowercased().hasPrefix(prefix) else { continue }
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private nonisolated static func uuidSuffix(in slug: String) -> String? {
        let pattern = #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/#
        guard let match = slug.firstMatch(of: pattern) else { return nil }
        return String(match.output)
    }

    nonisolated static func isCursorRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundleID).isEmpty
    }

    nonisolated static func readOpenWindows(
        from cursorApplicationSupport: URL
    ) -> (status: SnapshotStatus, folders: Set<String>, emptyWindowIDs: Set<String>) {
        let storage = cursorApplicationSupport
            .appendingPathComponent("User/globalStorage/storage.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: storage.path),
              let data = try? Data(contentsOf: storage),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (.unavailable, [], [])
        }

        var folders: Set<String> = []
        var emptyWindowIDs: Set<String> = []

        func ingestFolderURI(_ raw: Any?) {
            guard let uri = raw as? String, let path = path(fromFileURI: uri) else { return }
            folders.insert((path as NSString).standardizingPath)
        }

        if let backup = json["backupWorkspaces"] as? [String: Any] {
            if let list = backup["folders"] as? [[String: Any]] {
                for item in list { ingestFolderURI(item["folderUri"]) }
            }
            if let windows = backup["emptyWindows"] as? [[String: Any]] {
                for item in windows {
                    if let id = item["backupFolder"] as? String, !id.isEmpty {
                        emptyWindowIDs.insert(id)
                    }
                }
            }
        }

        if let windowsState = json["windowsState"] as? [String: Any] {
            if let opened = windowsState["openedWindows"] as? [[String: Any]] {
                for window in opened {
                    ingestFolderURI(window["folderUri"] ?? window["workspaceIdentifier"])
                    if let folder = window["folder"] as? String {
                        folders.insert((folder as NSString).standardizingPath)
                    }
                }
            }
        }

        return (.available, folders, emptyWindowIDs)
    }

    private nonisolated static func numericNamespacesBlockedByUnavailableWindows(home: String) -> Bool {
        guard isCursorRunning() else { return false }
        let support = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
        return readOpenWindows(from: support).status != .available
    }

    nonisolated static func containsSymlinkComponent(_ url: URL, home: String) -> Bool {
        let path = url.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return true }
        var current = URL(fileURLWithPath: home, isDirectory: true)
        let remainder = path.dropFirst(home.count)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        for part in remainder {
            current.appendPathComponent(part)
            if isSymlink(current) { return true }
        }
        return false
    }

    private nonisolated static func staysInsideIntendedCursorRoot(_ url: URL, home: String) -> Bool {
        let path = url.standardizedFileURL.path
        let worktreesRoot = "\(home)/.cursor/worktrees"
        let projectsRoot = "\(home)/.cursor/projects"
        let lexicalRoot: String
        if path == worktreesRoot || path.hasPrefix(worktreesRoot + "/") {
            lexicalRoot = worktreesRoot
        } else if path == projectsRoot || path.hasPrefix(projectsRoot + "/") {
            lexicalRoot = projectsRoot
        } else {
            return false
        }

        let rootURL = URL(fileURLWithPath: lexicalRoot, isDirectory: true)
        if containsSymlinkComponent(rootURL, home: home) { return false }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedRoot == lexicalRoot else { return false }
        return resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/")
    }

    private nonisolated static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private nonisolated static func path(fromFileURI uri: String) -> String? {
        guard let url = URL(string: uri), url.scheme == "file" else { return nil }
        return url.path
    }
}

/// Working directories of processes running from Cursor.app, used to keep a
/// live agent checkout off the list even when the window is still on the
/// main repo. Success is tracked separately from the cwd set: other apps'
/// cwds must not count as a completed Cursor snapshot.
enum CursorProcessWorkingDirectories {
    struct Snapshot {
        var status: CursorAgentLeftoverScanPolicy.SnapshotStatus
        var directories: Set<String>
    }

    nonisolated static func snapshot() -> Snapshot {
        let bytesNeeded = proc_listallpids(nil, 0)
        guard bytesNeeded > 0 else {
            return Snapshot(status: .unavailable, directories: [])
        }
        let capacity = Int(bytesNeeded) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: max(capacity, 1))
        let filledBytes = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard filledBytes > 0 else {
            return Snapshot(status: .unavailable, directories: [])
        }
        let count = Int(filledBytes) / MemoryLayout<pid_t>.size

        var cursorPids: [pid_t] = []
        for pid in pids.prefix(count) where pid > 0 {
            if isCursorExecutable(pid) {
                cursorPids.append(pid)
            }
        }

        if CursorAgentLeftoverScanPolicy.isCursorRunning() && cursorPids.isEmpty {
            return Snapshot(status: .unavailable, directories: [])
        }

        var directories: Set<String> = []
        for pid in cursorPids {
            if let cwd = currentWorkingDirectory(of: pid), !cwd.isEmpty {
                directories.insert((cwd as NSString).standardizingPath)
            }
        }

        if CursorAgentLeftoverScanPolicy.isCursorRunning() && !cursorPids.isEmpty && directories.isEmpty {
            return Snapshot(status: .unavailable, directories: [])
        }

        return Snapshot(status: .available, directories: directories)
    }

    private nonisolated static func isCursorExecutable(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        return path.contains("/Cursor.app/")
    }

    private nonisolated static func currentWorkingDirectory(of pid: pid_t) -> String? {
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
}
