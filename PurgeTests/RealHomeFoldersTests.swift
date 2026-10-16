import Foundation
import Testing

/// The cleanup that keeps worktree tests from deleting a tool's real folders
/// (#171), run against a temporary home.
@Suite("Test folders in the home folder remove only what they made")
struct RealHomeFoldersTests {
    private let fm = FileManager.default

    private func makeHome() throws -> URL {
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test
    func removesItsOwnFolderAndTheParentsItMade() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: false)
        let folders = RealHomeFolders(home: home)

        let group = try folders.make(".cursor/worktrees/purge-test")
        try Data().write(to: group.appendingPathComponent(".git"))
        folders.remove()

        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".cursor/worktrees").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent(".cursor").path))
    }

    @Test
    func keepsAParentItMadeOnceSomethingElseIsInIt() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let folders = RealHomeFolders(home: home)

        try folders.make(".codex/worktrees/purge-test")
        // The tool starts and makes a worktree of its own while the test runs.
        let toolWorktree = home.appendingPathComponent(".codex/worktrees/1f2e/app", isDirectory: true)
        try fm.createDirectory(at: toolWorktree, withIntermediateDirectories: true)
        try Data().write(to: toolWorktree.appendingPathComponent(".git"))
        folders.remove()

        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".codex/worktrees/purge-test").path))
        #expect(fm.fileExists(atPath: toolWorktree.appendingPathComponent(".git").path))
    }

    /// Parallel tests make their folders under the same parents. The first to finish
    /// must not take a parent away from one still running, nor leave it behind.
    @Test
    func sharedParentsGoWithTheLastFixtureThatUsesThem() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let first = RealHomeFolders(home: home)
        let second = RealHomeFolders(home: home)
        defer {
            first.remove()
            second.remove()
        }

        try first.make(".cursor/worktrees/purge-first")
        try second.make(".cursor/worktrees/purge-second")
        first.remove()

        #expect(fm.fileExists(atPath: home.appendingPathComponent(".cursor/worktrees/purge-second").path))
        try second.make(".cursor/worktrees/purge-third")
        second.remove()

        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".cursor").path))
    }

    @Test
    func refusesAFolderThatIsAlreadyThere() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let existing = home.appendingPathComponent(".t3/worktrees/app", isDirectory: true)
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        let folders = RealHomeFolders(home: home)

        #expect(throws: POSIXError.self) { try folders.make(".t3/worktrees/app") }
        folders.remove()

        #expect(fm.fileExists(atPath: existing.path))
    }

    @Test
    func removesALinkButNotWhatItPointsTo() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let target = home.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        try Data().write(to: target.appendingPathComponent("keep"))
        let folders = RealHomeFolders(home: home)

        try folders.make(".cursor/worktrees/purge-real")
        let link = try folders.link(".cursor/worktrees/purge-link", to: target)
        folders.remove()

        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(fm.fileExists(atPath: target.appendingPathComponent("keep").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".cursor").path))
    }
}
