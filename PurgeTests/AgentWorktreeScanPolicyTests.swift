import Foundation
import Testing
@testable import Purge

/// Where each tool keeps its worktrees, what counts as in use, and what the
/// deletion gate lets through. Registration itself is `GitWorktreeRegistrationTests`.
@Suite("Orphaned worktrees are found for every agent tool, and only when idle")
struct AgentWorktreeScanPolicyTests {
    private let idle = AgentWorktreeScanPolicy.LiveContext(processWorkingDirectories: [], openWorkspacePaths: [])

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// A linked-worktree `.git` whose repository is gone, so it reads as orphaned.
    @discardableResult
    private func orphan(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "gitdir: /nonexistent-\(UUID().uuidString)/.git/worktrees/x\n"
            .write(to: url.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return url
    }

    private func found(_ home: URL, projects: [URL] = [], live: AgentWorktreeScanPolicy.LiveContext? = nil) -> [String] {
        AgentWorktreeScanPolicy.orphanedWorktrees(home: home, claudeProjects: projects, live: live ?? idle)
            .map { String($0.path.dropFirst(home.path.count + 1)) }
    }

    // MARK: - Each tool's layout

    @Test
    func orphansAreFoundInEveryToolsFolder() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try orphan(at: home.appendingPathComponent(".cursor/worktrees/app/abc"))
        try orphan(at: home.appendingPathComponent(".codex/worktrees/1f2e/app"))
        try orphan(at: home.appendingPathComponent("conductor/workspaces/app/lisbon"))
        try orphan(at: home.appendingPathComponent(".t3/worktrees/app/feature"))
        let project = home.appendingPathComponent("Documents/app", isDirectory: true)
        try orphan(at: project.appendingPathComponent(".claude/worktrees/brave-turing"))

        #expect(found(home, projects: [project]).sorted() == [
            ".codex/worktrees/1f2e/app",
            ".cursor/worktrees/app/abc",
            ".t3/worktrees/app/feature",
            "Documents/app/.claude/worktrees/brave-turing",
            "conductor/workspaces/app/lisbon"
        ])
    }

    /// On a real Mac `.claude` and everything in it carry the hidden flag, and a
    /// listing that skips hidden files found no Claude Code worktrees at all.
    @Test
    func hiddenFlagDoesNotHideClaudeCodeWorktrees() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Documents/app", isDirectory: true)
        var leaf = try orphan(at: project.appendingPathComponent(".claude/worktrees/brave-turing"))
        var worktrees = leaf.deletingLastPathComponent()
        var hidden = URLResourceValues()
        hidden.isHidden = true
        try worktrees.setResourceValues(hidden)
        try leaf.setResourceValues(hidden)
        #expect(try leaf.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)

        #expect(found(home, projects: [project]) == ["Documents/app/.claude/worktrees/brave-turing"])
    }

    @Test
    func claudeCodeWorktreesNeedTheProjectToBeKnown() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Documents/app", isDirectory: true)
        try orphan(at: project.appendingPathComponent(".claude/worktrees/brave-turing"))

        #expect(found(home).isEmpty)
    }

    @Test
    func groupingFoldersAreNeverLeaves() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try orphan(at: home.appendingPathComponent(".codex/worktrees/1f2e/app"))

        #expect(found(home) == [".codex/worktrees/1f2e/app"])
    }

    @Test
    func ageIsNotAGate() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = try orphan(at: home.appendingPathComponent(".t3/worktrees/app/new"))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: leaf.path)

        #expect(found(home) == [".t3/worktrees/app/new"])
    }

    // MARK: - In use

    @Test
    func aProcessWorkingInsideKeepsItHidden() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = try orphan(at: home.appendingPathComponent(".codex/worktrees/1f2e/app"))
        var live = idle
        live.processWorkingDirectories = [leaf.appendingPathComponent("src").path]

        #expect(found(home, live: live).isEmpty)
    }

    @Test
    func anUnreadableProcessListHidesEverything() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try orphan(at: home.appendingPathComponent(".cursor/worktrees/app/abc"))
        var live = idle
        live.processWorkingDirectories = nil

        #expect(found(home, live: live).isEmpty)
    }

    @Test
    func anOpenCursorWindowKeepsItHidden() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = try orphan(at: home.appendingPathComponent(".cursor/worktrees/app/abc"))
        var live = idle
        live.openWorkspacePaths = [leaf.standardizedFileURL.path]

        #expect(found(home, live: live).isEmpty)
    }

    @Test
    func aGitLockKeepsItHidden() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = home.appendingPathComponent(".cursor/worktrees/app/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        // Registered to another checkout, so the leaf is an orphan and only the lock keeps it off.
        let adminDir = home.appendingPathComponent("repo/.git/worktrees/abc", isDirectory: true)
        let other = home.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: adminDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: other.appendingPathComponent(".git"))
        try "\(other.path)/.git\n".write(to: adminDir.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        try "gitdir: \(adminDir.path)\n".write(to: leaf.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(found(home) == [".cursor/worktrees/app/abc"])

        try Data().write(to: adminDir.appendingPathComponent("index.lock"))
        #expect(found(home).isEmpty)
    }

    // MARK: - Claude Code project list

    @Test
    func claudeCodeProjectsComeFromItsConfigInsideHomeOnly() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config: [String: Any] = [
            "projects": [
                "\(home.path)/Documents/app": [:],
                "/": [:],
                "/opt/elsewhere": [:]
            ],
            "githubRepoPaths": [
                "me/app": ["\(home.path)/Documents/app", "\(home.path)/Developer/app-copy"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: home.appendingPathComponent(".claude.json"))

        #expect(AgentWorktreeScanPolicy.claudeCodeProjects(home: home).map(\.path) == [
            "\(home.path)/Developer/app-copy",
            "\(home.path)/Documents/app"
        ])
    }

    @Test
    func missingClaudeCodeConfigMeansNoProjects() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AgentWorktreeScanPolicy.claudeCodeProjects(home: home).isEmpty)
    }

    // MARK: - Deletion gate

    @Test
    func toolFolderLeavesPassTheGateButTheirSettingsDoNot() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let token = "purge-test-\(UUID().uuidString.prefix(8))"
        let roots = [".cursor/worktrees", ".codex/worktrees", ".t3/worktrees"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
        // Tool folders this test had to make are removed again; real ones stay.
        let missingBefore = roots.filter { !fm.fileExists(atPath: $0.path) }
        let created = roots.map { $0.appendingPathComponent(token, isDirectory: true) }
        defer {
            created.forEach { try? fm.removeItem(at: $0) }
            missingBefore.forEach { try? fm.removeItem(at: $0) }
        }
        for group in created {
            let leaf = group.appendingPathComponent("leaf", isDirectory: true)
            try fm.createDirectory(at: leaf, withIntermediateDirectories: true)
            try Data().write(to: leaf.appendingPathComponent(".git"))
            #expect(DeletionSafetyPolicy.evaluate(leaf) == .allow)
            #expect(DeletionSafetyPolicy.evaluate(leaf.appendingPathComponent("src")) != .allow)
        }

        #expect(DeletionSafetyPolicy.evaluate(home.appendingPathComponent(".codex/worktrees")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(home.appendingPathComponent(".codex/auth.json")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(home.appendingPathComponent(".codex")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(home.appendingPathComponent(".t3")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(home.appendingPathComponent("conductor")) != .allow)
    }

    @Test
    func claudeCodeWorktreePassesTheGateOnlyAsALinkedWorktree() throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".purge-test-fixtures/\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let worktrees = root.appendingPathComponent("app/.claude/worktrees", isDirectory: true)
        let linked = worktrees.appendingPathComponent("brave-turing", isDirectory: true)
        let clone = worktrees.appendingPathComponent("full-clone", isDirectory: true)
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try fm.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "gitdir: /nowhere\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(DeletionSafetyPolicy.evaluate(linked) == .allow)
        #expect(DeletionSafetyPolicy.evaluate(clone) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(worktrees) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(root.appendingPathComponent("app/.claude")) != .allow)
    }

    @Test
    func buildFoldersInsideAWorktreeKeepTheirOwnRules() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inside = home.appendingPathComponent("Documents/app/.claude/worktrees/x/node_modules")
        #expect(!AgentWorktreeScanPolicy.looksLikeAgentWorktreePath(inside, home: home))
        #expect(AgentWorktreeScanPolicy.looksLikeAgentWorktreePath(inside.deletingLastPathComponent(), home: home))
        #expect(!AgentWorktreeScanPolicy.looksLikeAgentWorktreePath(
            home.appendingPathComponent(".codex/worktrees/1f2e/app/node_modules"), home: home
        ))
    }

    @Test
    func worktreeReachedThroughSymlinkIsRefused() throws {
        let fm = FileManager.default
        let token = UUID().uuidString.prefix(8)
        let home = fm.homeDirectoryForCurrentUser
        let real = home.appendingPathComponent(".cursor/worktrees/purge-real-\(token)/abc", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Data().write(to: real.appendingPathComponent(".git"))
        let link = home.appendingPathComponent(".cursor/worktrees/purge-link-\(token)", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
        defer {
            try? fm.removeItem(at: link)
            try? fm.removeItem(at: real.deletingLastPathComponent())
        }

        let viaLink = link.appendingPathComponent("abc")
        #expect(DeletionSafetyPolicy.evaluate(viaLink) != .allow)
        #expect(!AgentWorktreeScanPolicy.passesImmediateTrashBoundary(viaLink))
    }

    // MARK: - Row

    @Test
    func oneCheckFirstRowCoversEveryTool() {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: AgentWorktreeScanPolicy.toolLabel, primaryPath: nil)
        #expect(info.level == .medium)
        #expect(info.headline == "Orphaned Git Worktrees")
    }
}
