import Foundation
import Testing
@testable import Purge

@MainActor
@Suite("Hidden files and developer deep scan")
struct HiddenAndDeepScanTests {
    @Test func hiddenSelectionStaysHiddenAcrossScansAndStores() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        let path = URL(fileURLWithPath: "/tmp/purge-hidden-\(UUID().uuidString).mov")
        let key = HiddenLargeFilesStore.key(path)
        defer { HiddenLargeFilesStore.remove([key]) }
        let file = LargeFile(path: path, sizeBytes: 2_000, lastUsed: .distantPast, category: .video)
        fake.largeFileEvents = [.file(file)]
        let store = fake.makeStore()
        await store.scanLargeFiles()
        store.setLargeFileSelected(id: file.id, isSelected: true)
        store.hideSelectedLargeFiles()
        #expect(store.largeFiles.isEmpty)
        #expect(store.selectedLargeFiles.isEmpty)
        #expect(fake.makeStore().hiddenLargeFiles.contains { $0.path == key })
        store.setLargeFileSelected(id: file.id, isSelected: true)
        #expect(store.selectedLargeFiles.isEmpty)
        await store.scanLargeFiles()
        #expect(store.largeFiles.isEmpty)
        #expect(HiddenLargeFilesStore.contains(file.path))
        HiddenLargeFilesStore.remove([key])
        await store.scanLargeFiles()
        #expect(store.largeFiles.map(\.id) == [file.id])
    }

    @Test func deepWalkReportsDepthLimitsAndDoesNotFollowLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("purge-deep-\(UUID().uuidString)")
        let project = root.appendingPathComponent("one/two/project")
        let outside = fm.temporaryDirectory.appendingPathComponent("purge-outside-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("{}".utf8).write(to: outside.appendingPathComponent("package.json"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let issues = DeepScanIssues()
        let shallow = DevScanner.findProjectRoots(in: [root], home: root, access: .full, maxDepth: 1, onIssue: { issues.add($0) })
        #expect(shallow.roots.isEmpty)
        #expect(!issues.snapshot().isEmpty)
        #expect(issues.snapshot().allSatisfy { $0.reason == .depthLimit(1) })
        let deep = DevScanner.findProjectRoots(in: [root], home: root.deletingLastPathComponent(), access: .full, maxDepth: 12)
        #expect(deep.roots.map { $0.0.standardizedFileURL.path } == [project.standardizedFileURL.path])
    }

    @Test func depthLimitDoesNotWarnAboutArtifactsOrLinksItWouldSkipAnyway() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("purge-depth-skip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/child"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.appendingPathComponent("node_modules"))
        let issues = DeepScanIssues()
        _ = DevScanner.findProjectRoots(in: [root], home: root.deletingLastPathComponent(), access: .full,
                                       maxDepth: 0, onIssue: { issues.add($0) })
        #expect(issues.snapshot().isEmpty)
    }

    @Test func missingScanRootsHaveTheirOwnReason() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let issues = DeepScanIssues()
        _ = DevScanner.findProjectRoots(in: [root], home: root.deletingLastPathComponent(), access: .full,
                                       onIssue: { issues.add($0) })
        #expect(issues.snapshot() == [.init(path: root.path, reason: .missing)])
    }

    @Test func hidingCancelsAStaleRemoveDownloadRequest() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let path = URL(fileURLWithPath: "/tmp/purge-hidden-cloud-\(UUID().uuidString).mov")
        let key = HiddenLargeFilesStore.key(path)
        defer { HiddenLargeFilesStore.remove([key]) }
        let file = LargeFile(path: path, sizeBytes: 2_000, lastUsed: .distantPast, category: .video,
                             syncsWithICloud: true, canMoveToTrash: true, canRemoveDownload: true)
        let store = fake.makeStore()
        store.largeFiles = [file]
        store.setLargeFileSelected(id: file.id, isSelected: true)
        store.requestRemoveDownloads(for: file)
        #expect(store.pendingRemoveDownload != nil)
        store.hideSelectedLargeFiles()
        await store.confirmRemoveDownloads()
        #expect(store.pendingRemoveDownload == nil)
        #expect(store.removeDownloadResult == nil)
        store.requestRemoveDownloads(for: file)
        #expect(store.pendingRemoveDownload == nil)
    }

    @Test func developerCleaningPreferenceAndRootsPersist() {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        store.setDeveloperCleaningEnabled(true)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("purge-test-\(UUID().uuidString)")
        store.addDeveloperCleaningRoots([root])
        let next = fake.makeStore()
        #expect(next.developerCleaningEnabled)
        #expect(next.developerCleaningRoots == [root.resolvingSymlinksInPath().standardizedFileURL.path])
        next.setDeveloperCleaningEnabled(false)
        #expect(next.developerCleaningRoots.count == 1)
    }

    @Test func limitedNormalScansSkipDeveloperDeepScan() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = false
        let store = fake.makeStore()
        store.setDeveloperCleaningEnabled(true)
        await store.scanAll()
        #expect(!store.isDeepScanning)
        #expect(store.deepScanStatus.isEmpty)
        #expect(store.deepScanUnknownCaches.isEmpty)
    }

    @Test func disabledDeveloperCleaningSkipsDeepPassWithFullAccess() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        let store = fake.makeStore()
        await store.scanAll()
        #expect(store.deepScanStatus.isEmpty)
    }

    @Test("Replacing a scan cancels held project discovery", .timeLimit(.minutes(1)))
    func replacingScanCancelsDiscoveryBeforeDeepPass() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.holdsProjects = true
        let store = fake.makeStore()
        store.setDeveloperCleaningEnabled(true)
        store.deepScanCacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = Task { await store.scanAll() }
        #expect(await eventually {
            fake.projectScanCount == 1 && store.isScanningProjects
                && !store.isScanningGeneral && !store.isScanningDeveloper
        })
        fake.holdsProjects = false
        await store.scanAll()
        await first.value
        #expect(!store.isScanningAll)
        #expect(!store.isScanningProjects)
        #expect(!store.isDeepScanning)
        #expect(!store.deepScanStatus.isEmpty)
    }

    @Test(arguments: [false, true])
    func deepResultsAreManualOnlyAndUnknownCachesAreReadOnly(stale: Bool) async throws {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("purge-deep-test-\(UUID().uuidString)")
        let project = root.appendingPathComponent("projects/nested/app")
        let cache = root.appendingPathComponent("cache")
        let mystery = cache.appendingPathComponent("mystery")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: project.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mystery, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("{}".utf8).write(to: project.appendingPathComponent("package-lock.json"))
        try Data("cache".utf8).write(to: mystery.appendingPathComponent("data"))
        if stale {
            let old = Date().addingTimeInterval(-400 * 24 * 60 * 60)
            let contents = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            for case let url as URL in contents {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.path)
        }
        fake.hasAccess = true
        let store = fake.makeStore()
        store.deepScanCacheRoot = cache
        store.setDeveloperCleaningEnabled(true)
        store.addDeveloperCleaningRoots([root.appendingPathComponent("projects")])
        await store.scanAll()
        #expect(!store.isDeepScanning)
        #expect(!store.deepScanStatus.isEmpty)
        let artifacts = store.projectGroups.flatMap(\.artifacts)
        #expect(artifacts.contains { $0.path.lastPathComponent == "node_modules" && $0.safetyInfo.level == .medium })
        #expect(store.scanSelection.artifactIDs.isEmpty)
        #expect(store.manualSafeCleanupCandidates().allSatisfy { $0.path.lastPathComponent != "node_modules" })
        #expect(store.deepScanUnknownCaches.map(\.url.lastPathComponent) == ["mystery"])
        let group = try #require(store.projectGroups.first)
        let artifact = try #require(group.artifacts.first)
        defer { UserOverridesStore.remove(path: artifact.path) }
        #expect(group.reviewTitle == "projects / nested/app")
        #expect(group.latestArtifactModification != nil)
        store.setProjectArtifactCategory(groupID: group.id, artifactID: artifact.id, level: .safe)
        #expect(store.projectGroups.first?.artifacts.first?.safetyInfo.level == .safe)
        #expect(UserOverridesStore.read(path: artifact.path)?.overrideTag == "safe")
        #expect(store.manualSafeCleanupCandidates().allSatisfy { $0.path != artifact.path })
        store.resetProjectArtifactToAutomatic(groupID: group.id, artifactID: artifact.id)
        #expect(UserOverridesStore.read(path: artifact.path) == nil)
        #expect(store.projectGroups.first?.artifacts.first?.safetyInfo.level == .medium)
        if stale { #expect(artifact.checkFirstReason == nil) }
        store.setDeveloperCleaningEnabled(false)
        #expect(store.projectGroups.isEmpty)
        #expect(store.deepScanUnknownCaches.isEmpty)
    }

    @Test func savedProjectRepositoryMetadataSurvivesRoundTrip() throws {
        let group = ProjectGroup(displayName: "api", rootPath: URL(fileURLWithPath: "/test/Monorepo/apps/api"),
                                 inferredTypes: [], artifacts: [], repositoryRoot: URL(fileURLWithPath: "/test/Monorepo"))
        #expect(group.reviewTitle == "Monorepo / apps/api")
        let data = try JSONEncoder().encode(SavedProjectGroup(group))
        #expect(try JSONDecoder().decode(SavedProjectGroup.self, from: data).repositoryRoot == group.repositoryRoot)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "repositoryRoot")
        let olderData = try JSONSerialization.data(withJSONObject: old)
        #expect(try JSONDecoder().decode(SavedProjectGroup.self, from: olderData).repositoryRoot == nil)
    }
    @Test(arguments: [false, true])
    func aDeepConfirmationRejectsRevokedAccessOrANewGitLock(becomesActive: Bool) async throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("purge-deep-revoke-\(UUID().uuidString)")
        let project = root.appendingPathComponent("app")
        let artifactPath = project.appendingPathComponent("node_modules")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: artifactPath, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("{}".utf8).write(to: project.appendingPathComponent("package-lock.json"))
        try Data("build".utf8).write(to: artifactPath.appendingPathComponent("data"))
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        let trash = FakeTrash()
        let store = fake.makeStore(fileDeleter: FileDeleter(trash: trash.trash))
        store.deepScanCacheRoot = root.appendingPathComponent("absent-cache")
        store.setDeveloperCleaningEnabled(true)
        store.addDeveloperCleaningRoots([root])
        await store.scanAll()
        let artifact = try #require(store.projectGroups.flatMap(\.artifacts).first)
        #expect(store.presentKeyboardDeletionSheet(.artifact(id: artifact.id)))
        // Only the permission source changes: confirmation itself must refresh
        // access and reject the already-copied deep candidate.
        if becomesActive {
            try fm.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try Data().write(to: project.appendingPathComponent(".git/index.lock"))
        } else {
            fake.hasAccess = false
        }
        store.userConfirmedDeletionFromPrimarySheet()
        #expect(await eventually { store.errorMessage != nil })
        #expect(store.hasFullDiskAccess == becomesActive)
        #expect(trash.trashedPaths.isEmpty)
        #expect(fm.fileExists(atPath: artifactPath.path))
        if !becomesActive { #expect(store.projectGroups.isEmpty) }
        #expect(!store.showDeletionSheet)
        #expect(await eventually { !store.isDeleting })
        #expect(trash.trashedPaths.isEmpty)
        store.acknowledgeUncommittedGitRisk()
        #expect(await eventually { !store.isDeleting })
        #expect(trash.trashedPaths.isEmpty)
    }

    @Test(arguments: [false, true])
    func hidingProtectsAFileInAnAlreadyOpenReview(duplicates: Bool) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("purge-hide-review-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let downloads = home.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let files = try ["keep.bin", "hide.bin"].map { name -> LargeFile in
            let url = downloads.appendingPathComponent(name)
            try Data(repeating: 0x5a, count: 4096).write(to: url)
            return LargeFile(path: url, sizeBytes: 4096, lastUsed: .distantPast, category: .other)
        }
        let picked = files[1]
        defer { HiddenLargeFilesStore.remove([HiddenLargeFilesStore.key(picked.path)]) }
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        let trash = FakeTrash()
        let store = fake.makeStore(fileDeleter: FileDeleter(home: home, trash: trash.trash))
        store.largeFiles = files
        if duplicates {
            store.largeFileDuplicates.finish(with: DuplicateIndex(groups: [DuplicateGroup(id: "fixture", fileIDs: files.map(\.id), sizeBytes: 4096)]))
            store.requestDuplicateCleanup()
            #expect(store.pendingDuplicateCleanup != nil)
        } else {
            #expect(store.presentLargeFileDeletionSheet(for: picked))
        }
        store.setLargeFileSelected(id: picked.id, isSelected: true)
        store.hideSelectedLargeFiles()
        if duplicates { await store.confirmDuplicateCleanup(keeperByGroupID: ["fixture": files[0].id]) }
        else { await store.confirmLargeFileDeletion() }
        #expect(trash.trashedPaths.isEmpty)
        #expect(fm.fileExists(atPath: picked.path.path))
        #expect(store.lastDeletionReport == nil)
    }

}
