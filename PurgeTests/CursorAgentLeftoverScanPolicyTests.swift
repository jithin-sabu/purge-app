import Foundation
import Testing
@testable import Purge

@Suite("Cursor agent leftover path shape never includes settings or live project folders")
struct CursorAgentLeftoverWhitelistTests {
    @Test
    func leafWorktreeIsAllowed() {
        let url = TestPaths.homeURL(".cursor", "worktrees", "purge", "abc")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
        #expect(CursorAgentLeftoverScanPolicy.isEligibleForDeletion(
            url,
            home: FileManager.default.homeDirectoryForCurrentUser
        ))
    }

    @Test
    func worktreesRootIsRefused() {
        let url = TestPaths.homeURL(".cursor", "worktrees")
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
    }

    @Test
    func worktreeProjectGroupWithoutGitIsRefused() {
        let url = TestPaths.homeURL(".cursor", "worktrees", "purge")
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
    }

    @Test
    func cursorRootAndSettingsAreRefused() {
        #expect(DeletionSafetyPolicy.evaluate(TestPaths.homeURL(".cursor")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(TestPaths.homeURL(".cursor", "mcp.json")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(TestPaths.homeURL(".cursor", "ide_state.json")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(TestPaths.homeURL(".cursor", "argv.json")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(TestPaths.homeURL(".cursor", "extensions")) != .allow)
    }

    @Test
    func applicationSupportCursorIsNotSwept() {
        let url = TestPaths.homeURL("Library", "Application Support", "Cursor")
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
    }

    @Test
    func realProjectNamespaceIsRefused() {
        let url = TestPaths.homeURL(
            ".cursor", "projects", "Users-jithinsabu-Documents-purge-purge"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
    }

    @Test
    func junkTempNamespaceIsAllowed() {
        let url = TestPaths.homeURL(
            ".cursor", "projects", "var-folders-h2-tmp-T-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func numericEmptyWindowNamespaceIsAllowed() {
        let url = TestPaths.homeURL(".cursor", "projects", "1775773462384")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func emptyWindowNamespaceIsNeverWhitelisted() {
        let url = TestPaths.homeURL(".cursor", "projects", "empty-window")
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
    }

    @Test
    func nestedFileInsideWorktreeIsNotARow() {
        let url = TestPaths.homeURL(".cursor", "worktrees", "purge", "abc", "src", "main.swift")
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
    }
}

private enum TestPaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func homeURL(_ components: String...) -> URL {
        components.reduce(home) { $0.appendingPathComponent($1) }
    }
}

@Suite("Cursor agent leftovers are listed only when they look unused")
struct CursorAgentLeftoverScanPolicyTests {
    private func makeHome() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func idleLive(tmp: URL) -> CursorAgentLeftoverScanPolicy.LiveContext {
        CursorAgentLeftoverScanPolicy.LiveContext(
            cursorIsRunning: false,
            openWorkspacePaths: [],
            emptyWindowBackupIDs: [],
            processWorkingDirectories: [],
            temporaryDirectory: tmp
        )
    }

    private func gitWorktree(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try "gitdir: /tmp/fake.git/worktrees/abc\n".write(
            to: url.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test
    func finishedWorktreeIsListedWhenCursorIsClosed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = home.appendingPathComponent(".cursor/worktrees/purge/abc", isDirectory: true)
        try gitWorktree(at: leaf)

        let found = CursorAgentLeftoverScanPolicy.unusedDirectories(
            home: home,
            live: idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        )
        #expect(found.map(\.standardizedFileURL.path) == [leaf.standardizedFileURL.path])
    }

    @Test
    func openWorktreeWindowIsNotListed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = home.appendingPathComponent(".cursor/worktrees/purge/abc", isDirectory: true)
        try gitWorktree(at: leaf)

        var live = idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        live.openWorkspacePaths = [leaf.standardizedFileURL.path]

        let found = CursorAgentLeftoverScanPolicy.unusedDirectories(home: home, live: live)
        #expect(found.isEmpty)
    }

    @Test
    func processCwdInsideWorktreeIsNotListed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = home.appendingPathComponent(".cursor/worktrees/purge/abc", isDirectory: true)
        try gitWorktree(at: leaf)

        var live = idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        live.cursorIsRunning = true
        live.processWorkingDirectories = [leaf.appendingPathComponent("src").path]

        let found = CursorAgentLeftoverScanPolicy.unusedDirectories(home: home, live: live)
        #expect(found.isEmpty)
    }

    @Test
    func gitLockMarksAWorktreeLive() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = home.appendingPathComponent(".cursor/worktrees/purge/abc", isDirectory: true)
        try gitWorktree(at: leaf)
        let gitDir = home.appendingPathComponent("fake.git/worktrees/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data().write(to: gitDir.appendingPathComponent("index.lock"))
        try "gitdir: \(gitDir.path)\n".write(
            to: leaf.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let found = CursorAgentLeftoverScanPolicy.unusedDirectories(
            home: home,
            live: idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        )
        #expect(found.isEmpty)
    }

    @Test
    func groupingFolderIsNotListedEvenIfChildrenAre() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let group = home.appendingPathComponent(".cursor/worktrees/purge", isDirectory: true)
        try gitWorktree(at: group.appendingPathComponent("abc", isDirectory: true))

        let found = CursorAgentLeftoverScanPolicy.unusedDirectories(
            home: home,
            live: idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        )
        #expect(found.count == 1)
        #expect(found.first?.lastPathComponent == "abc")
        #expect(found.first?.deletingLastPathComponent().lastPathComponent == "purge")
    }

    @Test
    func runningCursorWithoutProcessCwdsHidesAllWorktrees() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try gitWorktree(at: home.appendingPathComponent(".cursor/worktrees/purge/abc", isDirectory: true))

        var live = idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        live.cursorIsRunning = true
        live.processWorkingDirectories = []

        let found = CursorAgentLeftoverScanPolicy.unusedWorktrees(home: home, live: live)
        #expect(found.isEmpty)
    }

    @Test
    func varFoldersNamespaceIsListedOnlyWhenTempWorkspaceIsGone() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let tmp = home.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let slug = "var-folders-h2-y5tm6qr53cn71z-gdvdns9lm0000gn-T-\(uuid)"
        let leftover = home.appendingPathComponent(".cursor/projects/\(slug)", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        var live = idleLive(tmp: tmp)
        live.temporaryDirectory = tmp

        let gone = CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live)
        #expect(gone.map(\.lastPathComponent) == [slug])

        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(uuid, isDirectory: true),
            withIntermediateDirectories: true
        )
        let stillThere = CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live)
        #expect(stillThere.isEmpty)
    }

    @Test
    func numericNamespaceStillBackedUpIsNotListed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let slug = "1789734813690"
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cursor/projects/\(slug)", isDirectory: true),
            withIntermediateDirectories: true
        )

        var live = idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        live.emptyWindowBackupIDs = [slug]
        #expect(CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live).isEmpty)

        live.emptyWindowBackupIDs = []
        #expect(CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live).count == 1)
    }

    @Test
    func realProjectSlugIsNeverDiscovered() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(
                ".cursor/projects/Users-someone-Documents-app",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let found = CursorAgentLeftoverScanPolicy.unusedDirectories(
            home: home,
            live: idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        )
        #expect(found.isEmpty)
    }

    @Test
    func ageIsNotAGate() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let leaf = home.appendingPathComponent(".cursor/worktrees/purge/new", isDirectory: true)
        try gitWorktree(at: leaf)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: leaf.path
        )

        let found = CursorAgentLeftoverScanPolicy.unusedDirectories(
            home: home,
            live: idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        )
        #expect(found.count == 1)
    }

    @Test
    func encodedSlugMatchesForwardEncoding() {
        let path = "/var/folders/h2/y5tm6qr53cn71z_gdvdns9lm0000gn/T/uuid"
        #expect(
            CursorAgentLeftoverScanPolicy.encodedProjectSlug(for: path)
                == "var-folders-h2-y5tm6qr53cn71z-gdvdns9lm0000gn-T-uuid"
        )
    }

    @Test
    func explanationIsCheckFirst() {
        let info = SafetyInfo.fromExplanationDatabase(
            key: CursorAgentLeftoverScanPolicy.explanationKey,
            friendlyFallback: CursorAgentLeftoverScanPolicy.toolLabel
        )
        #expect(info.level == .medium)
        #expect(info.headline == "Cursor Agent Leftovers")
    }
}
