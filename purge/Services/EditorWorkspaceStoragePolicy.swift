import Foundation

/// Which entries in VS Code's and Cursor's `User/workspaceStorage` belong to a
/// project that no longer exists.
///
/// Each entry is one folder per project the editor has opened. It is not a cache:
/// it holds that project's editor state, and for AI editors the chat history
/// (Cursor keeps its chats in `state.vscdb`, Copilot Chat in `chatSessions`). So
/// the folder as a whole is never offered. An entry is offered only when its
/// `workspace.json` names a project folder that is gone, and even then as Check
/// First: a project that was moved or renamed also looks gone, and its chats would
/// go with it.
nonisolated enum EditorWorkspaceStoragePolicy {
    /// Home-relative `workspaceStorage` roots, one per editor.
    static let relativeRoots: [(editor: String, relative: String)] = [
        ("VS Code", "Library/Application Support/Code/User/workspaceStorage"),
        ("Cursor", "Library/Application Support/Cursor/User/workspaceStorage")
    ]

    static func roots(home: String) -> [String] {
        relativeRoots.map { "\(home)/\($0.relative)" }
    }

    /// A folder directly inside one of the roots. Pure string check.
    static func isEntryPath(_ path: String, home: String) -> Bool {
        for root in roots(home: home) {
            guard path.hasPrefix(root + "/") else { continue }
            let rest = path.dropFirst(root.count + 1)
            return !rest.isEmpty && !rest.contains("/")
        }
        return false
    }

    /// The project folder an entry was created for, read from its
    /// `workspace.json`. Nil when the entry has no such file (an empty window),
    /// or the project is not a local `file:` URL (a remote or WSL workspace), since
    /// Purge cannot tell whether those still exist.
    static func projectURL(forEntry entry: URL, fileManager: FileManager = .default) -> URL? {
        let manifest = entry.appendingPathComponent("workspace.json", isDirectory: false)
        guard let data = fileManager.contents(atPath: manifest.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let raw = (json["folder"] as? String) ?? (json["workspace"] as? String)
        guard let raw, let url = URL(string: raw), url.isFileURL else { return nil }
        return url
    }

    /// True only when Purge can prove the project is gone. Anything it cannot
    /// check counts as still there: a project on a drive that is not plugged in,
    /// or one inside a folder a limited scan must not touch.
    static func isOrphaned(
        entry: URL,
        access: ScanAccess,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let project = projectURL(forEntry: entry, fileManager: fileManager) else { return false }
        let projectPath = project.path
        if projectPath.hasPrefix("/Volumes/") {
            let parts = projectPath.split(separator: "/")
            guard parts.count >= 2 else { return false }
            let volume = "/Volumes/\(parts[1])"
            guard fileManager.fileExists(atPath: volume) else { return false }
        }
        // Checked before the lookup below, which is the access that prompts.
        guard ProtectedLocations.isReadable(project, access: access, home: home, fileManager: fileManager) else {
            return false
        }
        return isConfirmedMissing(projectPath)
    }

    /// True only when the lookup itself says the path does not exist. `fileExists`
    /// also returns false when a parent folder cannot be searched, which would
    /// count a project Purge merely cannot reach as deleted. `lstat` does not
    /// follow a final symlink, so a project that is a link counts as present.
    static func isConfirmedMissing(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    /// The orphaned entries under one editor's root.
    static func orphanedEntries(
        inRoot root: URL,
        access: ScanAccess,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard ProtectedLocations.isReadable(root, access: access, home: home, fileManager: fileManager),
              let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries.filter { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }
            return isOrphaned(entry: entry, access: access, home: home, fileManager: fileManager)
        }
        .map(\.standardizedFileURL)
    }
}
