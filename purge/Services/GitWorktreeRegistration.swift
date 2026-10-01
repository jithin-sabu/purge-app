import Darwin
import Foundation

/// Whether Git still lists a linked worktree (issue #61).
///
/// Age says nothing here. A checkout nobody has opened in months can still be
/// registered on its repository and in use, and one made this morning can
/// already be cut loose. So a worktree row only appears once the repository
/// itself says the folder is no longer one of its worktrees.
///
/// A linked worktree's `.git` is a file, `gitdir: <repo>/.git/worktrees/<id>`.
/// That admin folder holds a `gitdir` file pointing back at the worktree's
/// `.git`. Git counts the worktree as registered while both ends agree.
///
/// Anything short of proof reads as `.unknown`, and unknown is hidden like
/// registered: a full clone, a `.git` that is a link, an admin folder on a
/// drive that is not mounted, or files Purge cannot read.
nonisolated enum GitWorktreeRegistration {
    enum State: Equatable {
        /// The repository still lists this folder as one of its worktrees.
        case registered
        /// The repository is gone, or it no longer lists this folder.
        case orphaned
        /// Not a linked worktree, or the answer could not be proven.
        case unknown
    }

    static func state(of worktree: URL, fileManager: FileManager = .default) -> State {
        let dotGit = worktree.appendingPathComponent(".git", isDirectory: false)
        // `lstat`: a `.git` directory is a standalone clone with its own history,
        // not something a repository can drop, and a link is never followed.
        guard case .regularFile = entryKind(at: dotGit.path, followingLinks: false),
              let adminDir = GitRepositoryFinder.gitDirectory(forRepository: worktree) else {
            return .unknown
        }

        switch entryKind(at: adminDir.path, followingLinks: true) {
        case .missing:
            // Deleted, re-cloned, or `git worktree remove` dropped the entry. A repo
            // on a drive that is not plugged in looks the same, so that stays unknown.
            return isOnUnmountedVolume(adminDir.path) ? .unknown : .orphaned
        case .directory:
            break
        case .regularFile, .other, .unreadable:
            return .unknown
        }

        let backPointer = adminDir.appendingPathComponent("gitdir", isDirectory: false)
        guard let text = try? String(contentsOf: backPointer, encoding: .utf8) else { return .unknown }
        let recorded = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recorded.isEmpty else { return .unknown }
        // Relative since Git 2.48 (`worktree.useRelativePaths`), relative to the admin folder.
        let recordedPath = recorded.hasPrefix("/") ? recorded : adminDir.path + "/" + recorded

        // Compared by file identity, so `/var` vs `/private/var` or a linked home
        // cannot make the same `.git` look like two.
        guard let ours = fileIdentity(at: dotGit.path) else { return .unknown }
        switch entryKind(at: recordedPath, followingLinks: true) {
        case .missing:
            // The entry names a path that no longer exists: this folder was most likely
            // moved by hand, and `git worktree repair` would take it back.
            return .unknown
        case .unreadable:
            return .unknown
        case .regularFile, .directory, .other:
            guard let theirs = fileIdentity(at: recordedPath) else { return .unknown }
            // The entry belongs to another live checkout; this folder is a stray copy.
            return theirs == ours ? .registered : .orphaned
        }
    }

    // MARK: - Internals

    private enum EntryKind {
        case missing
        case regularFile
        case directory
        case other
        /// Permission denied, I/O error, and anything else that is not "not there".
        case unreadable
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func entryKind(at path: String, followingLinks: Bool) -> EntryKind {
        var info = stat()
        let result = followingLinks ? stat(path, &info) : lstat(path, &info)
        guard result == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        default: return .other
        }
    }

    private static func fileIdentity(at path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// `/Volumes/<name>/…` whose volume is not there right now.
    static func isOnUnmountedVolume(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        var info = stat()
        return stat("/Volumes/\(parts[1])", &info) != 0
    }
}
