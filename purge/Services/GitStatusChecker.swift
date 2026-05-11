import Foundation

enum GitRepositoryFinder {
    nonisolated static func enclosingRepository(for itemPath: URL) -> URL? {
        var candidate = itemPath.standardizedFileURL
        while true {
            if hasGit(at: candidate) {
                return candidate
            }
            guard candidate.path != "/" else { break }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated private static func hasGit(at directory: URL) -> Bool {
        let fm = FileManager.default
        let dotGit = directory.appendingPathComponent(".git", isDirectory: false)
        return fm.fileExists(atPath: dotGit.path)
    }
}

/// Folder names that are always safe to remove without consulting git.
/// These rebuildable artifacts must never trigger the dirty-repo warning even
/// when they live inside a repository with uncommitted edits.
enum GitWarningPolicy {
    nonisolated static let rebuildableFolderNames: Set<String> = [
        "node_modules",
        "venv",
        ".venv",
        "target",
        "Pods",
        ".gradle",
        "DerivedData",
        "build",
        "dist",
        "out",
        ".next",
        ".nuxt",
        ".cache",
        "__pycache__",
        ".turbo",
        ".parcel-cache"
    ]

    nonisolated static func isRebuildableFolder(_ url: URL) -> Bool {
        rebuildableFolderNames.contains(url.lastPathComponent)
    }
}

/// Runs `git` off the MainActor so scanning never stalls the UI.
actor GitStatusChecker {
    private var cache: [String: GitWorktreeStatus] = [:]

    /// Underlying repo cleanliness check. Prefer `cleanupStatus(for:)` for UI
    /// signals; this is only useful when the caller already vetted the path.
    func worktreeStatus(for itemPath: URL) async -> GitWorktreeStatus {
        guard let repoRoot = GitRepositoryFinder.enclosingRepository(for: itemPath) else {
            return .clean
        }
        let key = repoRoot.path
        if let hit = cache[key] { return hit }

        let status = await GitStatusChecker.runGitStatus(repository: repoRoot)
        cache[key] = status
        return status
    }

    /// Status used to decide whether to show "Unfinished local changes nearby".
    /// Skips the check entirely for known rebuildable folders, and only flags
    /// folders that sit directly inside the enclosing git repository.
    func cleanupStatus(for itemPath: URL) async -> GitWorktreeStatus {
        let standardized = itemPath.standardizedFileURL

        if GitWarningPolicy.isRebuildableFolder(standardized) {
            return .clean
        }

        guard let repoRoot = GitRepositoryFinder.enclosingRepository(for: standardized) else {
            return .clean
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path == repoRoot.path else {
            return .clean
        }

        let key = repoRoot.path
        if let hit = cache[key] { return hit }

        let status = await GitStatusChecker.runGitStatus(repository: repoRoot)
        cache[key] = status
        return status
    }

    func clearSessionCache() {
        cache.removeAll()
    }

    private static func runGitStatus(repository: URL) async -> GitWorktreeStatus {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let result = invokeGit(repository: repository)
                cont.resume(returning: result)
            }
        }
    }

    /// Returns `.unknown` only if Git is unavailable; empty porcelain means `.clean`.
    private static func invokeGit(repository: URL) -> GitWorktreeStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path, "status", "--porcelain"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .unknown
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return .unknown
        }

        let output = String(data: data, encoding: .utf8) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .clean : .dirty
    }
}
