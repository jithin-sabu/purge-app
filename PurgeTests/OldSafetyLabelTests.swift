import Foundation
import Testing
@testable import Purge

/// Purge 1.0 and 1.1 saved safety levels set by hand in `user_overrides.json`,
/// keyed by exact path. Purge no longer reads that file (#415). An old Safe entry
/// outranked every automatic rule, so a Check First folder could reach Clean Safe
/// Items and scheduled cleans. Each test writes a Safe entry for the paths it
/// checks, as Purge 1.1 did, and expects the automatic level.
///
/// The file is in the test run's own support folder (`AppSupportFolder`), never
/// the user's. Serialized, because the tests share that one file.
@MainActor
@Suite("Old manual safety labels have no effect", .serialized)
struct OldSafetyLabelTests {
    private static var fileURL: URL {
        AppSupportFolder.url().appendingPathComponent("user_overrides.json", isDirectory: false)
    }

    /// Writes a Safe entry for each path, in the shape Purge 1.1 saved. Remove
    /// the file with `removeOldLabels()`.
    private static func writeOldSafeLabels(for paths: [URL]) throws {
        var entries: [String: [String: String]] = [:]
        for path in paths {
            entries[path.standardizedFileURL.path] = [
                "overrideTag": "safe",
                "overrideDate": "2026-06-01T10:00:00Z",
                "originalTag": "medium",
            ]
        }
        try FileManager.default.createDirectory(at: AppSupportFolder.url(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: fileURL, options: [.atomic])
    }

    private static func removeOldLabels() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    @Test("a Unity Library folder labelled Safe stays Check First")
    func unityLibraryStaysCheckFirst() throws {
        let fixture = try HomeScopedFixture(
            files: ["ProjectSettings/ProjectVersion.txt"],
            folders: ["Library", "Assets"]
        )
        defer { fixture.cleanUp() }
        let library = fixture.url("Library")
        try Self.writeOldSafeLabels(for: [library])
        defer { Self.removeOldLabels() }

        let artifacts = DevScanner.collectArtifacts(projectRoot: fixture.root, types: [.unity])
        let row = try #require(artifacts.first { $0.kind == .unityLibrary })
        #expect(row.safetyInfo.level == .medium)
    }

    /// A project folder for the store. The path does not exist, so the clean
    /// can't reach it, but the candidate list still counts it by level.
    private func projectArtifact(reason: ProjectCheckFirstReason?) -> ProjectCacheArtifact {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-\(UUID().uuidString)", isDirectory: true)
        let path = root.appendingPathComponent("node_modules", isDirectory: true)
        return ProjectCacheArtifact(
            kind: .nodeModules,
            path: path,
            projectRoot: root,
            sizeBytes: 1024,
            lastModified: .distantPast,
            isSelected: false,
            safetyInfo: SafetyInfo.forStaleProjectArtifact(kind: .nodeModules, level: .safe, checkFirstReason: reason),
            reinstallSafety: .notApplicable,
            gitStatus: .clean,
            checkFirstReason: reason
        )
    }

    /// Built on fake scans and throwaway defaults, so the store never reads or
    /// writes the real user's records.
    private func store(with artifact: ProjectCacheArtifact, _ scans: FakeScans) -> PurgeStore {
        scans.hasAccess = true
        let store = scans.makeStore()
        store.projectGroups = [ProjectGroup(
            displayName: "project",
            rootPath: artifact.projectRoot,
            inferredTypes: [.node],
            artifacts: [artifact]
        )]
        return store
    }

    @Test(
        "a project held at Check First and labelled Safe stays out of Clean Safe Items",
        arguments: [ProjectCheckFirstReason.usedRecently, .tooBigToCheck]
    )
    func heldProjectStaysOutOfSafeClean(reason: ProjectCheckFirstReason) throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let artifact = projectArtifact(reason: reason)
        try Self.writeOldSafeLabels(for: [artifact.path])
        defer { Self.removeOldLabels() }

        #expect(artifact.safetyInfo.level == .medium)
        #expect(SafetyInfo(
            level: .safe, headline: "node_modules", explanation: "", recoverySteps: "", reinstallCommand: nil
        ).heldAtCheckFirst().level == .medium)
        let store = store(with: artifact, scans)
        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    /// Shows the empty list above comes from the level, not from the folder
    /// being out of reach.
    @Test("the same project not held is a Clean Safe Items candidate")
    func unheldProjectIsACandidate() throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let artifact = projectArtifact(reason: nil)
        #expect(artifact.safetyInfo.level == .safe)
        #expect(store(with: artifact, scans).manualSafeCleanupCandidates().count == 1)
    }

    @Test("an unknown cache folder labelled Safe stays Not Sure")
    func unknownCacheFolderStaysNotSure() throws {
        let name = "com.purge.test.old-label-\(UUID().uuidString)"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try Self.writeOldSafeLabels(for: [path])
        defer { Self.removeOldLabels() }

        let info = ExplanationResolver.initialSafetyForCacheFolder(
            folderName: name, friendlyHeadline: name, path: path
        )
        #expect(info.level == .unknown)
    }

    @Test("merged App Caches rows labelled Safe keep their Check First entry")
    func mergedCacheRowKeepsItsEntry() throws {
        let key = "uv-cache"
        let record = try #require(ExplanationDatabase.record(forKey: key))
        let checkFirst = ExplanationDatabase.safetyInfo(from: record)
        try #require(checkFirst.level == .medium)
        let paths = ["one", "two"].map {
            URL(fileURLWithPath: "/Users/alice/Library/Caches/old-label-\($0)", isDirectory: true)
        }
        try Self.writeOldSafeLabels(for: paths)
        defer { Self.removeOldLabels() }

        let rows = DefinitionCacheGrouper.group(paths.map { path in
            CacheItem(
                definitionKey: key,
                location: CacheLocation(path: path, sizeBytes: 100, lastModified: .distantPast, folderName: "uv"),
                appName: checkFirst.headline,
                safetyInfo: checkFirst
            )
        })
        #expect(rows.count == 1)
        #expect(rows.first?.safetyInfo.level == .medium)
    }

    @Test("a Check First dev tool labelled Safe stays Check First")
    func devToolStaysCheckFirst() throws {
        let path = URL(fileURLWithPath: "/Users/alice/.cache/uv", isDirectory: true)
        try Self.writeOldSafeLabels(for: [path])
        defer { Self.removeOldLabels() }

        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: "uv Package Cache", primaryPath: path).level == .medium)
    }
}
