import Foundation
import os
import Testing
@testable import Purge

@Suite("Deeper discovery in added project folders")
struct ProjectScanDepthTests {
    @Test func onlyAddedRootsWalkBeyondTheDefaultDepth() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("Home")
        let added = home.appendingPathComponent("Source")
        let standard = home.appendingPathComponent("Code")
        let branch = "one/two/three/four/five/app"
        let extra = added.appendingPathComponent(branch)
        for project in [extra, standard.appendingPathComponent(branch)] {
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        }
        let path = added.standardizedFileURL.path
        let result = ScanFolders.$snapshotOverride.withValue(.init(walked: [path], saved: [path])) {
            DevScanner.findProjectRoots(in: [added, standard], home: home, access: .full)
        }
        #expect(result.roots.map { $0.0.standardizedFileURL.path } == [extra.standardizedFileURL.path])
    }

    @Test func aSavedHomeFolderReplacedByAnOutsideLinkIsRefused() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("Home", isDirectory: true)
        let outside = fixture.appendingPathComponent("Home-other", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: outside.appendingPathComponent("package.json"))
        let saved = home.appendingPathComponent("Source")
        try fm.createSymbolicLink(at: saved, withDestinationURL: outside)

        let entries = ScanFolders.entries(home: home, isLocalDisk: { _ in true },
            savedFolders: [.init(path: saved.path, dateAdded: Date())])
        #expect(entries.map(\.refusal) == [.throughLink])
        let result = DevScanner.findProjectRoots(in: entries.filter(\.isAvailable).map(\.url), home: home, access: .full)
        #expect(result.roots.isEmpty)
        let savedPath = saved.standardizedFileURL.path
        let artifact = saved.appendingPathComponent("node_modules")
        ScanFolders.$snapshotOverride.withValue(.init(walked: [], saved: [savedPath])) {
            #expect(!ScanFolders.permitsProjectArtifactMove(artifact, home: home.path))
        }
        ScanFolders.$snapshotOverride.withValue(.init(walked: [savedPath], saved: [savedPath])) {
            #expect(!ScanFolders.permitsProjectArtifactMove(artifact, home: home.path))
        }
    }

    @Test func reportsTheFolderAtTheDepthLimit() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let path = folder.standardizedFileURL.path
        let boundary = (1...12).reduce(folder) { $0.appendingPathComponent("level-\($1)", isDirectory: true) }
        try fm.createDirectory(at: boundary.appendingPathComponent("child"), withIntermediateDirectories: true)
        let issues = OSAllocatedUnfairLock(initialState: [ProjectScanIssue]())
        let result = ScanFolders.$snapshotOverride.withValue(.init(walked: [path], saved: [path])) {
            DevScanner.findProjectRoots(in: [folder], home: fm.temporaryDirectory, access: .full, onIssue: { issue in
                issues.withLock { $0.append(issue) }
            })
        }
        #expect(result.directoriesWalked == 13)
        let recorded = issues.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.reason == .depthLimit(12))
        #expect(recorded.first?.path.hasSuffix("/level-12") == true)
    }

    @Test func retryDoesNotMoveAnArtifactAfterItsProjectGetsAGitLock() async throws {
        let fm = FileManager.default
        let home = trashTestHome()
        defer { try? fm.removeItem(at: home) }
        let folder = home.appendingPathComponent("Source")
        let project = folder.appendingPathComponent("one/two/three/four/five/app")
        let artifact = project.appendingPathComponent("node_modules")
        try fm.createDirectory(at: artifact, withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let deleter = FileDeleter(home: home, trash: trash.trash, fullDiskAccessGranted: { true })
        let path = folder.standardizedFileURL.path
        try await ScanFolders.$snapshotOverride.withValue(.init(walked: [path], saved: [path])) {
            let first = try await deleter.deleteItems(at: [artifact])
            try #require(first.failedItems.count == 1)
            try Data().write(to: project.appendingPathComponent(".git/index.lock"))
            let result = await deleter.retryDeleteItem(at: artifact, displayName: nil, expectedSizeBytes: 0, route: .cache)
            if case .failed(.safetySkipped) = result {} else { Issue.record("Expected a safety refusal") }
            #expect(trash.trashedPaths.isEmpty)

            let lock = project.appendingPathComponent(".git/index.lock")
            try fm.removeItem(at: lock)
            let started = OSAllocatedUnfairLock(initialState: false)
            let report = try await deleter.deleteItems(at: [artifact], onProgress: { event in
                guard case .itemStarted = event else { return }
                started.withLock { $0 = fm.createFile(atPath: lock.path, contents: Data()) }
            })
            #expect(started.withLock { $0 })
            #expect(report.skippedItems.map(\.path) == [artifact.path])
            #expect(trash.trashedPaths.isEmpty)
            try fm.removeItem(at: project.appendingPathComponent("package.json"))
            #expect(ProjectActivityPolicy.artifactBelongsToActiveProject(artifact, access: .full))
            try fm.removeItem(at: lock)
            #expect(!ProjectActivityPolicy.artifactBelongsToActiveProject(artifact, access: .full))
        }
    }

    @Test(arguments: [false, true])
    func aReplacedRootCannotReachTrash(artifactIsRoot: Bool) async throws {
        let fm = FileManager.default
        let fixture = trashTestHome()
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("Home")
        let oldProject = home.appendingPathComponent("Source/App")
        let otherProject = fixture.appendingPathComponent("Outside/App")
        let artifact = oldProject.appendingPathComponent("node_modules")
        let outsideArtifact = otherProject.appendingPathComponent("node_modules")
        for project in [oldProject, otherProject] {
            try fm.createDirectory(at: project.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        }
        let saved = artifactIsRoot ? artifact : oldProject
        let outside = artifactIsRoot ? outsideArtifact : otherProject
        // Keep the catalog's project parent inside the admitted root for the
        // control move. Then simulate adding the artifact itself as a root.
        let walked = home.appendingPathComponent("Source").standardizedFileURL.path
        let savedPath = saved.standardizedFileURL.path
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let deleter = FileDeleter(home: home, trash: trash.trash, fullDiskAccessGranted: { true })
        let first = try await ScanFolders.$snapshotOverride.withValue(.init(walked: [walked], saved: [walked])) {
            try await deleter.deleteItems(at: [artifact])
        }
        try #require(first.failedItems.count == 1)

        try fm.removeItem(at: saved)
        try fm.createSymbolicLink(at: saved, withDestinationURL: outside)
        try await ScanFolders.$snapshotOverride.withValue(.init(walked: [savedPath, walked], saved: [savedPath])) {
            let report = try await deleter.deleteItems(at: [artifact])
            #expect(report.skippedItems.map(\.path) == [artifact.path])
            let retry = await deleter.retryDeleteItem(at: artifact, displayName: nil, expectedSizeBytes: 0, route: .cache)
            if case .failed(.safetySkipped) = retry {} else { Issue.record("Expected a safety refusal") }
            #expect(trash.trashedPaths.isEmpty)
        }
    }

    @Test func upstreamMoveCheckCanStillRefuseAfterAnItemStarts() async throws {
        let fm = FileManager.default
        let home = trashTestHome()
        defer { try? fm.removeItem(at: home) }
        let added = home.appendingPathComponent("Source")
        let project = added.appendingPathComponent("App")
        let artifact = project.appendingPathComponent("node_modules")
        try fm.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        let moveAllowed = OSAllocatedUnfairLock(initialState: true)
        let trash = FakeTrash()
        let deleter = FileDeleter(home: home, trash: trash.trash, fullDiskAccessGranted: { true },
            immediateMoveCheck: { _ in moveAllowed.withLock { $0 } })
        let path = added.standardizedFileURL.path
        let report = try await ScanFolders.$snapshotOverride.withValue(.init(walked: [path], saved: [path])) {
            try await deleter.deleteItems(at: [artifact], onProgress: { event in
                guard case .itemStarted = event else { return }
                moveAllowed.withLock { $0 = false }
            })
        }
        #expect(!moveAllowed.withLock { $0 })
        #expect(report.skippedItems.map(\.path) == [artifact.path])
        #expect(trash.trashedPaths.isEmpty)
    }

    /// The early boundary check passes here, since `.itemStarted` only comes
    /// after it. The root is swapped for a link during the clean, so only the
    /// last check before the Trash move can refuse it.
    @Test func aRootReplacedDuringTheCleanIsRefusedByTheLastCheck() async throws {
        let fm = FileManager.default
        let fixture = trashTestHome()
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("Home")
        let saved = home.appendingPathComponent("Source/App")
        let outside = fixture.appendingPathComponent("Outside/App")
        let artifact = saved.appendingPathComponent("node_modules")
        for project in [saved, outside] {
            try fm.createDirectory(at: project.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        }
        let savedPath = saved.standardizedFileURL.path
        let trash = FakeTrash()
        let deleter = FileDeleter(home: home, trash: trash.trash, fullDiskAccessGranted: { true })
        let replaced = OSAllocatedUnfairLock(initialState: false)
        let report = try await ScanFolders.$snapshotOverride.withValue(.init(walked: [savedPath], saved: [savedPath])) {
            try await deleter.deleteItems(at: [artifact], onProgress: { event in
                guard case .itemStarted = event else { return }
                replaced.withLock { done in
                    guard !done else { return }
                    let aside = saved.deletingLastPathComponent().appendingPathComponent("App-old")
                    done = (try? fm.moveItem(at: saved, to: aside)) != nil
                        && (try? fm.createSymbolicLink(at: saved, withDestinationURL: outside)) != nil
                }
            })
        }
        #expect(replaced.withLock { $0 })
        #expect(report.skippedItems.map(\.path) == [artifact.path])
        #expect(trash.trashedPaths.isEmpty)
    }

    /// `vendor/bundle` is the only rule for a folder named `bundle`. A `bundle`
    /// folder anywhere else matches no rule's path, and its parent is checked.
    @Test func anArtifactNoRuleMatchesIsCheckedAgainstItsParent() throws {
        let fm = FileManager.default
        let project = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: project) }
        let artifact = project.appendingPathComponent("bundle")
        try fm.createDirectory(at: artifact, withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let rules = try #require(ProjectArtifactCatalog.rulesByFolderName["bundle"])
        #expect(!rules.contains { artifact.path.hasSuffix("/" + $0.folder) })

        // The git lookup stays inside home or an added folder, so the fixture
        // is added the way the scan would see it.
        let path = project.standardizedFileURL.path
        try ScanFolders.$snapshotOverride.withValue(.init(walked: [path], saved: [path])) {
            #expect(!ProjectActivityPolicy.artifactBelongsToActiveProject(artifact, access: .full))
            try Data().write(to: project.appendingPathComponent(".git/index.lock"))
            #expect(ProjectActivityPolicy.artifactBelongsToActiveProject(artifact, access: .full))
        }
    }

    private func trashTestHome() -> URL {
        // /tmp is scratch space and, unlike /var/folders, is outside the
        // system /var denylist. Inject the walk and intercept Trash.
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("purge-project-scan-\(UUID().uuidString)", isDirectory: true)
    }
}
