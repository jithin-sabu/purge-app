import Foundation
import Testing
@testable import Purge

/// Real repositories and real `git worktree add`, so the files the check reads
/// are the ones Git writes, not a hand-made imitation.
@Suite("Git worktrees show only once their repository no longer lists them")
struct GitWorktreeRegistrationTests {
    private struct Fixture {
        let root: URL
        let repo: URL
        let home: URL
        let worktree: URL

        /// The admin folder Git made for `worktree` inside the main repository.
        var adminDir: URL {
            repo.appendingPathComponent(".git/worktrees/\(worktree.lastPathComponent)", isDirectory: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let worktree = home.appendingPathComponent(".cursor/worktrees/repo/abc", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)

        try git(in: repo, "init", "-q")
        try git(in: repo, "commit", "-q", "--allow-empty", "-m", "first")
        try git(in: repo, "worktree", "add", "-q", "--detach", worktree.path)
        return Fixture(root: root, repo: repo, home: home, worktree: worktree)
    }

    private func git(in directory: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", directory.path,
            "-c", "user.name=Purge Tests",
            "-c", "user.email=tests@purge.invalid",
            "-c", "commit.gpgsign=false",
            "-c", "init.defaultBranch=main"
        ] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    private let idle = AgentWorktreeScanPolicy.LiveContext(processWorkingDirectories: [], openWorkspacePaths: [])

    private func listed(_ fixture: Fixture) -> [String] {
        AgentWorktreeScanPolicy.orphanedWorktrees(home: fixture.home, claudeProjects: [], live: idle)
            .map(\.lastPathComponent)
    }

    @Test
    func registeredWorktreeIsHiddenHoweverOld() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let longAgo = Date(timeIntervalSinceNow: -400 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: fixture.worktree.path)

        #expect(GitWorktreeRegistration.state(of: fixture.worktree) == .registered)
        #expect(listed(fixture).isEmpty)
    }

    @Test
    func deletedRepositoryLeavesAnOrphanThatIsListedEvenWhenNew() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.repo)

        #expect(GitWorktreeRegistration.state(of: fixture.worktree) == .orphaned)
        #expect(listed(fixture) == ["abc"])
    }

    @Test
    func droppedRegistrationIsAnOrphan() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.adminDir)

        #expect(GitWorktreeRegistration.state(of: fixture.worktree) == .orphaned)
        #expect(listed(fixture) == ["abc"])
    }

    @Test
    func copiedCheckoutIsAnOrphanWhileTheOriginalStaysRegistered() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let copy = fixture.worktree.deletingLastPathComponent().appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.worktree, to: copy)

        #expect(GitWorktreeRegistration.state(of: copy) == .orphaned)
        #expect(GitWorktreeRegistration.state(of: fixture.worktree) == .registered)
        #expect(listed(fixture) == ["copy"])
    }

    @Test
    func checkoutMovedByHandIsKeptBecauseGitCanRepairIt() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let moved = fixture.worktree.deletingLastPathComponent().appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.worktree, to: moved)

        #expect(GitWorktreeRegistration.state(of: moved) == .unknown)
        #expect(listed(fixture).isEmpty)
    }

    @Test
    func relativePathsOnBothEndsStillMatch() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let repoGit = fixture.repo.resolvingSymlinksInPath().appendingPathComponent(".git").path
        let worktreePath = fixture.worktree.resolvingSymlinksInPath().path
        // What `worktree.useRelativePaths` writes: each end relative to its own folder.
        try "gitdir: \(relativePath(from: worktreePath, to: repoGit + "/worktrees/abc"))\n"
            .write(to: fixture.worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "\(relativePath(from: repoGit + "/worktrees/abc", to: worktreePath + "/.git"))\n"
            .write(to: fixture.adminDir.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)

        #expect(GitWorktreeRegistration.state(of: fixture.worktree) == .registered)
    }

    @Test
    func standaloneCloneIsNeverTreatedAsAnOrphan() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let clone = fixture.worktree.deletingLastPathComponent().appendingPathComponent("clone", isDirectory: true)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try git(in: clone, "init", "-q")

        #expect(GitWorktreeRegistration.state(of: clone) == .unknown)
        #expect(!listed(fixture).contains("clone"))
    }

    @Test
    func repositoryOnAnUnpluggedDriveIsKept() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let volume = "Purge-Not-Mounted-\(UUID().uuidString)"
        try "gitdir: /Volumes/\(volume)/repo/.git/worktrees/abc\n"
            .write(to: fixture.worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(GitWorktreeRegistration.state(of: fixture.worktree) == .unknown)
        #expect(listed(fixture).isEmpty)
    }

    @Test
    func orphanStillOpenInCursorIsHidden() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.repo)
        var live = idle
        live.openWorkspacePaths = [fixture.worktree.standardizedFileURL.path]

        #expect(AgentWorktreeScanPolicy.orphanedWorktrees(home: fixture.home, claudeProjects: [], live: live).isEmpty)
    }

    /// The last check before Trash, on the real home folder because that is the only
    /// place the deletion gate allows.
    @Test
    func trashStepRefusesARegisteredWorktreeAndAllowsAnOrphan() throws {
        let fm = FileManager.default
        let fixture = try makeFixture()
        let group = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/worktrees/purge-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let leaf = group.appendingPathComponent("abc", isDirectory: true)
        defer {
            fixture.remove()
            try? fm.removeItem(at: group)
        }
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        try git(in: fixture.repo, "worktree", "add", "-q", "--detach", leaf.path)

        #expect(!AgentWorktreeScanPolicy.passesImmediateTrashBoundary(leaf))

        try fm.removeItem(at: fixture.repo)
        #expect(AgentWorktreeScanPolicy.passesImmediateTrashBoundary(leaf))
    }

    private func relativePath(from directory: String, to target: String) -> String {
        let from = directory.split(separator: "/")
        let to = target.split(separator: "/")
        var shared = 0
        while shared < min(from.count, to.count) && from[shared] == to[shared] {
            shared += 1
        }
        let ups = Array(repeating: "..", count: from.count - shared)
        return (ups + to[shared...].map(String.init)).joined(separator: "/")
    }
}
