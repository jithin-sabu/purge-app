import Foundation
import Testing
@testable import Purge

/// Pins the 2026-10 allowlist audit. Safe rows are what "Clean Safe Items" and
/// scheduled cleans take without asking, so anything here that is not a pure,
/// self-rebuilding cache must be Check First or not offered at all.
private enum AuditPaths {
    static var home: String {
        DeletionSafetyPolicy.cachedHomePath
    }

    static func url(_ relative: String) -> URL {
        URL(fileURLWithPath: "\(home)/\(relative)")
    }

    static func evaluate(_ relative: String) -> DeletionSafetyDecision {
        DeletionSafetyPolicy.evaluate(url(relative))
    }
}

private func bundledLevel(_ key: String) -> SafetyLevel? {
    ExplanationDatabase.record(forKey: key)?.safetyLevel
}

// MARK: - Part 1: rows that were Safe but hold more than a cache

@Suite("Allowlist audit: no longer Safe")
struct AllowlistNoLongerSafeTests {
    @Test
    func gemsOnlyOfferDownloadsNotInstalledGems() {
        #expect(AuditPaths.evaluate(".gem") != .allow)
        #expect(AuditPaths.evaluate(".gem/ruby/3.3.0/gems/cocoapods-1.16.2") != .allow)
        #expect(AuditPaths.evaluate(".gem/ruby/3.3.0/bin/pod") != .allow)
        #expect(AuditPaths.evaluate(".gem/specs") == .allow)
        #expect(AuditPaths.evaluate(".gem/ruby/3.3.0/cache") == .allow)
        #expect(AuditPaths.evaluate(".gem/ruby/3.3.0/cache/cocoapods-1.16.2.gem") == .allow)
    }

    @Test
    func sbtSettingsAreNeverOffered() {
        #expect(AuditPaths.evaluate(".sbt") != .allow)
        #expect(AuditPaths.evaluate(".sbt/1.0/global.sbt") != .allow)
        #expect(AuditPaths.evaluate(".ivy2/cache") == .allow)
    }

    @Test
    func pubCacheKeepsGloballyActivatedTools() {
        #expect(AuditPaths.evaluate(".pub-cache") != .allow)
        #expect(AuditPaths.evaluate(".pub-cache/bin") != .allow)
        #expect(AuditPaths.evaluate(".pub-cache/global_packages") != .allow)
        #expect(AuditPaths.evaluate(".pub-cache/hosted") == .allow)
        #expect(AuditPaths.evaluate(".pub-cache/git") == .allow)
    }

    @Test
    func cocoaPodsOffersSpecReposOnly() {
        #expect(AuditPaths.evaluate(".cocoapods") != .allow)
        #expect(AuditPaths.evaluate(".cocoapods/repos") == .allow)
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "CocoaPods", primaryPath: nil)
        #expect(info.level == .medium)
    }

    @Test
    func zedWorkspaceDatabaseIsNeverOffered() {
        #expect(AuditPaths.evaluate("Library/Application Support/Zed/db") != .allow)
        #expect(AuditPaths.evaluate("Library/Caches/Zed") == .allow)
    }

    @Test
    func jetBrainsLocalHistoryIsNeverOffered() {
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains") == .blockedNeverDelete)
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2") == .blockedNeverDelete)
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2/LocalHistory") == .blockedNeverDelete)
        #expect(
            AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2/LocalHistory/changes.storageData")
                == .blockedNeverDelete
        )
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2/caches") == .allow)
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2/index") == .allow)
    }

    @Test
    func editorWorkspaceStorageIsOfferedEntryByEntry() {
        for editor in ["Code", "Cursor"] {
            let root = "Library/Application Support/\(editor)/User/workspaceStorage"
            #expect(AuditPaths.evaluate(root) != .allow, "whole folder offered for \(editor)")
            #expect(AuditPaths.evaluate("\(root)/0a1b2c3d") == .allow)
        }
        #expect(bundledLevel("orphaned-editor-workspace-storage") == .medium)
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "Cursor Old Workspace Data", primaryPath: nil)
        #expect(info.level == .medium)
    }

    @Test(arguments: [
        "Maven Cache", "Gradle Cache", "NuGet Packages", "Cabal Packages",
        "SBT Cache", "Playwright Browsers",
    ])
    func bigDownloadStoresAreCheckFirst(label: String) {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: label, primaryPath: nil)
        #expect(info.level == .medium, "\(label) is \(info.level)")
    }

    /// Project `.gradle` folders share the old key and stay Safe; only the global
    /// `~/.gradle/caches` row moved.
    @Test
    func projectGradleFoldersStaySafe() {
        #expect(bundledLevel("gradle-cache") == .safe)
        #expect(bundledLevel("gradle-global-cache") == .medium)
    }
}

@Suite("Editor workspace storage: only provably orphaned entries")
struct EditorWorkspaceStoragePolicyTests {
    private func makeEntry(in root: URL, json: String?) throws -> URL {
        let entry = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        if let json {
            try Data(json.utf8).write(to: entry.appendingPathComponent("workspace.json"))
        }
        return entry
    }

    @Test
    func onlyEntriesWhoseProjectIsGoneAreOrphaned() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("workspaceStorage", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let live = try makeEntry(in: root, json: #"{"folder":"\#(project.absoluteString)"}"#)
        let gone = try makeEntry(
            in: root,
            json: #"{"folder":"\#(base.appendingPathComponent("deleted-project").absoluteString)"}"#
        )
        let remote = try makeEntry(in: root, json: #"{"folder":"vscode-remote://ssh-remote+box/home/me/app"}"#)
        let emptyWindow = try makeEntry(in: root, json: nil)
        let unplugged = try makeEntry(in: root, json: #"{"folder":"file:///Volumes/NotPluggedIn-\#(UUID().uuidString)/app"}"#)

        let orphaned = Set(
            EditorWorkspaceStoragePolicy.orphanedEntries(inRoot: root, access: .full).map(\.lastPathComponent)
        )
        #expect(orphaned == [gone.lastPathComponent])
        for kept in [live, remote, emptyWindow, unplugged] {
            #expect(!orphaned.contains(kept.lastPathComponent))
        }
    }

    @Test
    func projectsInLockedFoldersCountAsPresentWithoutFullDiskAccess() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let inDocuments = URL(fileURLWithPath: "\(AuditPaths.home)/Documents/purge-test-\(UUID().uuidString)")
        let entry = try makeEntry(in: root, json: #"{"folder":"\#(inDocuments.absoluteString)"}"#)
        #expect(!EditorWorkspaceStoragePolicy.isOrphaned(entry: entry, access: .limited))
    }
}
