import Foundation
import Testing
@testable import Purge

@Suite("Cursor agent leftover path shape never includes settings or live project folders")
struct CursorAgentLeftoverWhitelistTests {
    @Test
    func twoComponentWorktreeWithoutGitIsRefused() {
        let url = TestPaths.homeURL(".cursor", "worktrees", "purge", "abc")
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
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
    func genericTmpSlugWithoutUUIDIsRefused() {
        let url = TestPaths.homeURL(".cursor", "projects", "tmp-scratch")
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
        #expect(!CursorAgentLeftoverScanPolicy.isJunkProjectSlug("tmp-scratch"))
        #expect(!CursorAgentLeftoverScanPolicy.isJunkProjectSlug("private-tmp-notes"))
        #expect(CursorAgentLeftoverScanPolicy.isJunkProjectSlug(
            "tmp-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        ))
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
            cursorProcessSnapshot: .available,
            windowsSnapshot: .available,
            temporaryDirectory: tmp
        )
    }

    @Test
    func numericNamespaceHiddenWhenWindowsSnapshotUnavailableAndCursorRunning() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let slug = "1789734813690"
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cursor/projects/\(slug)", isDirectory: true),
            withIntermediateDirectories: true
        )

        var live = idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        live.cursorIsRunning = true
        live.windowsSnapshot = .unavailable
        #expect(CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live).isEmpty)

        live.windowsSnapshot = .available
        #expect(CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live).count == 1)
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

    /// `/tmp/<uuid>` becomes `tmp-<uuid>` or `private-tmp-<uuid>`. Their
    /// workspace was looked for in `$TMPDIR`, so a live one was listed (#183).
    @Test(arguments: ["tmp-", "private-tmp-"])
    func systemTempNamespaceIsListedOnlyWhenItsWorkspaceIsGone(prefix: String) throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let userTemp = home.appendingPathComponent("user-tmp", isDirectory: true)
        let systemTemp = home.appendingPathComponent("system-tmp", isDirectory: true)
        let uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let slug = "\(prefix)\(uuid)"
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cursor/projects/\(slug)", isDirectory: true),
            withIntermediateDirectories: true
        )

        var live = idleLive(tmp: userTemp)
        live.systemTemporaryDirectory = systemTemp
        #expect(CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live).map(\.lastPathComponent) == [slug])

        try FileManager.default.createDirectory(
            at: systemTemp.appendingPathComponent(uuid, isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live).isEmpty)
    }

    /// Without Cursor's working directories Purge cannot tell a namespace an
    /// agent is using from an unused one, so it lists none (#183).
    @Test
    func nothingIsListedWithoutTheProcessSnapshot() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let slug = "var-folders-h2-y5tm6qr53cn71z-gdvdns9lm0000gn-T-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cursor/projects/\(slug)", isDirectory: true),
            withIntermediateDirectories: true
        )

        var live = idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        live.cursorProcessSnapshot = .unavailable
        #expect(CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live).isEmpty)

        live.cursorProcessSnapshot = .available
        #expect(CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(home: home, live: live).count == 1)
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

        let found = CursorAgentLeftoverScanPolicy.unusedJunkProjectNamespaces(
            home: home,
            live: idleLive(tmp: home.appendingPathComponent("tmp", isDirectory: true))
        )
        #expect(found.isEmpty)
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
