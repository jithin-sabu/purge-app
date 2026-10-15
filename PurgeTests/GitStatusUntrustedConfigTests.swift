import Foundation
import Testing
@testable import Purge

/// Purge runs `git status` by itself in projects it finds, so a repository's own
/// config must never get git to run a program. Each fixture plants a command that
/// writes a marker file, the way the report's proof of concept did.
@Suite("git status never runs a program a repository's config names")
struct GitStatusUntrustedConfigTests {
    private struct Repo {
        let folder: URL
        let marker: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-git-\(UUID().uuidString)", isDirectory: true)
            folder = base.appendingPathComponent("repo", isDirectory: true)
            marker = base.appendingPathComponent("ran", isDirectory: false)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try git("init", "-q")
            try write("hello", to: "a.txt")
            try git("add", "a.txt")
            try git("-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-qm", "init")
        }

        var plantedCommand: String { "touch '\(marker.path)'; false" }
        var ran: Bool { FileManager.default.fileExists(atPath: marker.path) }

        func write(_ text: String, to relative: String) throws {
            try Data(text.utf8).write(to: folder.appendingPathComponent(relative))
        }

        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }

        /// Changes a.txt's date, so git has to re-read it: what a freshly extracted
        /// archive looks like to `git status`.
        func makeStatDirty() throws {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)],
                ofItemAtPath: folder.appendingPathComponent("a.txt").path
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        }
    }

    /// `ProcessRunner` must not run on the main thread.
    private func status(_ repo: Repo) async -> GitWorktreeStatus {
        await Task.detached { GitStatusChecker.invokeGit(repository: repo.folder) }.value
    }

    @Test("core.fsmonitor is not run")
    func fsmonitorIsNotRun() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        try repo.git("config", "core.fsmonitor", repo.plantedCommand)
        try repo.makeStatDirty()
        #expect(await status(repo) == .clean)
        #expect(!repo.ran)
    }

    @Test("the scan's own route does not run core.fsmonitor either")
    func scanRouteDoesNotRunFsmonitor() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        try repo.git("config", "core.fsmonitor", repo.plantedCommand)
        try repo.makeStatDirty()
        let item = repo.folder.appendingPathComponent(".svelte-kit", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        _ = await GitStatusChecker().cleanupStatuses(for: [item])
        #expect(!repo.ran)
    }

    @Test("a filter in the repository's config makes the status unknown, and is not run")
    func repositoryFilterIsUnknown() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        try repo.git("config", "filter.x.clean", repo.plantedCommand)
        try repo.write("*.txt filter=x\n", to: ".gitattributes")
        try repo.makeStatDirty()
        #expect(await status(repo) == .unknown)
        #expect(!repo.ran)
    }

    @Test("a filter pulled in through an include counts as the repository's")
    func includedFilterIsUnknown() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        let included = repo.folder.deletingLastPathComponent().appendingPathComponent("extra.cfg")
        try Data("[filter \"y\"]\n\tclean = \(repo.plantedCommand)\n".utf8).write(to: included)
        try repo.git("config", "include.path", included.path)
        try repo.write("*.txt filter=y\n", to: ".gitattributes")
        try repo.makeStatDirty()
        #expect(await status(repo) == .unknown)
        #expect(!repo.ran)
    }

    @Test("a repository with submodules is unknown, since their config is not checked")
    func submodulesAreUnknown() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        try repo.write("[submodule \"lib\"]\n\tpath = lib\n", to: ".gitmodules")
        #expect(await status(repo) == .unknown)
    }

    @Test("an ordinary repository still reads clean or dirty")
    func ordinaryRepositoryStillWorks() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        #expect(await status(repo) == .clean)
        try repo.write("new", to: "b.txt")
        #expect(await status(repo) == .dirty)
    }
}
