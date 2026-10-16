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

    /// `lstat`, not `fileExists`: a `.git` that is a link into Documents must not
    /// be followed before a limited scan has checked it.
    nonisolated private static func hasGit(at directory: URL) -> Bool {
        let dotGit = directory.appendingPathComponent(".git", isDirectory: false)
        return (try? FileManager.default.attributesOfItem(atPath: dotGit.path)) != nil
    }

    /// Where `git` reads this repository's metadata. Usually `<repo>/.git`, but in a
    /// linked worktree `.git` is a file naming a git dir inside the main checkout,
    /// which can be anywhere on disk. Nil when `.git` is a file with no `gitdir:` line.
    ///
    /// The `gitdir:` path comes back as written, joined to the repository when it
    /// is relative, with `..` left in. `standardizedFileURL` would stat it, and
    /// that stat lands in the folder a limited scan is deciding whether to touch.
    /// `ProtectedLocations.isReadable` resolves it with `readlink` alone.
    nonisolated static func gitDirectory(forRepository repository: URL) -> URL? {
        let dotGit = repository.appendingPathComponent(".git", isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return repository.appendingPathComponent(".git", isDirectory: true) }

        guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("gitdir:") else { continue }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            let absolute = path.hasPrefix("/") ? path : repository.path + "/" + path
            return URL(fileURLWithPath: absolute, isDirectory: true)
        }
        return nil
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
    private var access: ScanAccess = .full
    /// Moves on with every `clearSessionCache()`. A `git status` that started
    /// before a clear answers for the old session, so it stays out of the new
    /// cache, where the next scan and the clean-time check would trust it (#172).
    private var session = 0
    /// Reads one repository's status. Tests hand in a fake they can hold open.
    private let readStatus: @Sendable (URL) async -> GitWorktreeStatus

    init(readStatus: @escaping @Sendable (URL) async -> GitWorktreeStatus = { repository in
        await GitStatusChecker.runGitStatus(repository: repository)
    }) {
        self.readStatus = readStatus
    }

    /// Set at the start of each scan. In a limited scan, a worktree whose git dir
    /// sits in a protected folder is reported `.unknown` instead: running `git`
    /// there would make macOS prompt on Purge's behalf.
    func setAccess(_ access: ScanAccess) {
        self.access = access
    }

    /// Status used to decide whether to show "Unfinished local changes nearby".
    /// Skips the check entirely for known rebuildable folders, and only flags
    /// folders that sit directly inside the enclosing git repository.
    func cleanupStatus(for itemPath: URL) async -> GitWorktreeStatus {
        let statuses = await cleanupStatuses(for: [itemPath])
        return statuses[itemPath.standardizedFileURL.path] ?? .clean
    }

    /// Resolves cleanup status for many paths with one `git status` per unique repository.
    func cleanupStatuses(for itemPaths: [URL]) async -> [String: GitWorktreeStatus] {
        var result: [String: GitWorktreeStatus] = [:]
        var repoRootsToResolve: Set<String> = []
        var pathToRepoRoot: [String: String] = [:]

        for itemPath in itemPaths {
            let standardized = itemPath.standardizedFileURL
            let pathKey = standardized.path

            if GitWarningPolicy.isRebuildableFolder(standardized) {
                result[pathKey] = .clean
                continue
            }

            guard let repoRoot = GitRepositoryFinder.enclosingRepository(for: standardized) else {
                result[pathKey] = .clean
                continue
            }

            let parent = standardized.deletingLastPathComponent().standardizedFileURL
            guard parent.path == repoRoot.path else {
                result[pathKey] = .clean
                continue
            }

            // A dotfiles repo at home would make `git status` walk the whole home
            // folder. Unknown keeps these items out of one-click cleaning, as the
            // dirty status such a repo almost always reports did.
            guard repoRoot.path != Self.homePath else {
                result[pathKey] = .unknown
                continue
            }

            if access == .limited {
                // `.git` can itself be a link, so it is checked before it is read
                // for a `gitdir:` line, and the git dir it names after that.
                let dotGit = repoRoot.appendingPathComponent(".git", isDirectory: false)
                guard ProtectedLocations.isReadable(dotGit, access: .limited),
                      let gitDir = GitRepositoryFinder.gitDirectory(forRepository: repoRoot),
                      ProtectedLocations.isReadable(gitDir, access: .limited) else {
                    result[pathKey] = .unknown
                    continue
                }
            }

            pathToRepoRoot[pathKey] = repoRoot.path
            repoRootsToResolve.insert(repoRoot.path)
        }

        await fetchMissingRepoStatuses(repoRootsToResolve)

        // A cache cleared while the fetch was awaited has no answer, which is not
        // the same as clean.
        for (pathKey, repoPath) in pathToRepoRoot {
            result[pathKey] = cache[repoPath] ?? .unknown
        }

        return result
    }

    func clearSessionCache() {
        cache.removeAll()
        session += 1
    }

    /// Unique-repo fetches only. Several cache rows often share one git root, so the
    /// previous sequential loop paid once per distinct repo; this keeps that, and
    /// overlaps a handful of unrelated repos instead of waiting for each `git status`
    /// in turn. Porcelain results are identical.
    private static let maxConcurrentGitStatus = 4

    private func fetchMissingRepoStatuses(_ repoRoots: Set<String>) async {
        let missing = repoRoots.filter { cache[$0] == nil }
        guard !missing.isEmpty else { return }
        let startedIn = session
        let readStatus = self.readStatus

        await withTaskGroup(of: (String, GitWorktreeStatus).self) { group in
            var remaining = Array(missing)
            func spawn() {
                guard let repoPath = remaining.popLast() else { return }
                group.addTask {
                    let status = await readStatus(URL(fileURLWithPath: repoPath))
                    return (repoPath, status)
                }
            }
            for _ in 0..<min(Self.maxConcurrentGitStatus, remaining.count) {
                spawn()
            }
            for await (repoPath, status) in group {
                // Cleared while this ran: the answers belong to the old session,
                // and the repositories still waiting are the new session's to read.
                guard session == startedIn else { continue }
                cache[repoPath] = status
                spawn()
            }
        }
    }

    static func runGitStatus(repository: URL) async -> GitWorktreeStatus {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let result = invokeGit(repository: repository)
                cont.resume(returning: result)
            }
        }
    }

    /// `git status` on a huge or network-mounted worktree can crawl; past this, "unknown" beats
    /// holding the scan open.
    private static let gitStatusTimeout: TimeInterval = 60

    nonisolated private static let homePath =
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    /// Purge runs `git status` by itself, in projects it finds in Downloads, Desktop
    /// and Documents, so the repository's own config is untrusted. These turn off
    /// what it can use to run a program: an fsmonitor command, hooks (a status that
    /// rewrites the index runs post-index-change), and submodules, which carry
    /// config of their own.
    nonisolated static let untrustedRepositoryArguments = [
        "--no-optional-locks",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
    ]

    /// Whether the repository's own config names a filter driver. A clean or
    /// process filter runs on any file `git status` has to re-read, and every file
    /// of a freshly extracted archive needs that. Filters from the user's global
    /// or system config, such as Git LFS, are the user's own and allowed. `git
    /// config` only reads files, includes too, and runs nothing. Nil when the
    /// answer is unclear.
    nonisolated static func repositoryDefinesFilters(_ repository: URL) -> Bool? {
        guard let result = ProcessRunner.run(
            executablePath: "/usr/bin/git",
            arguments: ["-C", repository.path] + untrustedRepositoryArguments
                + ["config", "--show-scope", "--includes", "--get-regexp", "^filter\\."],
            timeout: 10
        ), !result.timedOut else {
            return nil
        }
        switch result.status {
        case 0:
            let trusted: Set<String> = ["global", "system"]
            return result.stdoutText.split(whereSeparator: \.isNewline).contains { line in
                let scope = line.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
                return !trusted.contains(scope)
            }
        case 1:
            // `git config --get-regexp` exits 1 when nothing matches.
            return result.stdout.isEmpty ? false : nil
        default:
            return nil
        }
    }

    /// Returns `.unknown` if Git is unavailable or the repository could make it run
    /// a program; empty porcelain means `.clean`.
    nonisolated static func invokeGit(repository: URL) -> GitWorktreeStatus {
        // Submodule config is not covered by the filter check, so a repository
        // with submodules is not run at all.
        if FileManager.default.fileExists(atPath: repository.appendingPathComponent(".gitmodules").path) {
            return .unknown
        }
        guard repositoryDefinesFilters(repository) == false else {
            return .unknown
        }
        guard let result = ProcessRunner.run(
            executablePath: "/usr/bin/git",
            arguments: ["-C", repository.path] + untrustedRepositoryArguments
                + ["status", "--porcelain", "--ignore-submodules=all"],
            timeout: gitStatusTimeout
        ), result.succeeded else {
            return .unknown
        }

        let trimmed = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .clean : .dirty
    }
}
