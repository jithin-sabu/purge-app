import Foundation
import Testing
@testable import Purge

/// The rescan a scheduled clean runs before it picks what to move (#173). Project
/// discovery runs on after the Dev Tools scan returns, so the clean list is only
/// complete once discovery has settled, and must hold nothing a careful run
/// would leave out.
@MainActor
@Suite("The safe clean's rescan settles before the clean list is built")
struct SafeCleanupRescanTests {

    /// A cold launch with a clean overdue: no App Caches rows yet, so the rescan
    /// scans App Caches too. Run after Dev Tools, that scan started a new generation
    /// and stopped project discovery, which then never cleared its flag. Dev Tools
    /// showed "scanning" until a manual rescan, and the clean left out every project.
    @Test
    func coldRescanFinishesProjectDiscovery() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let modules = try fixture.project("app")

        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.projectEvents = [.projectGroupFound(group(artifact(at: modules)))]
        let store = fake.makeStore()

        let settled = await store.rescanBeforeSafeCleanup()

        #expect(settled)
        #expect(fake.generalAccesses == [.full])
        #expect(fake.projectScanCount == 1)
        #expect(!store.isScanningProjects)
        #expect(store.manualSafeCleanupCandidates().map(\.path) == [modules])
    }

    /// App Caches rows are already listed, so the rescan reuses them and only
    /// rescans Dev Tools. The clean list must still wait for project discovery,
    /// which is held open here until the rescan has had every chance to return.
    @Test
    func rescanReusingCacheRowsWaitsForProjectDiscovery() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let modules = try fixture.project("app")

        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.holdsProjects = true
        fake.projectEvents = [.projectGroupFound(group(artifact(at: modules)))]
        let store = fake.makeStore()
        store.cacheItems = [listedCacheRow()]

        let rescan = Task {
            let settled = await store.rescanBeforeSafeCleanup()
            fake.log.append("rescan returned")
            return (settled, store.manualSafeCleanupCandidates().map(\.path))
        }
        #expect(await eventually { fake.projectScanCount == 1 })
        for _ in 0..<20 { await Task.yield() }
        #expect(!fake.log.contains("rescan returned"))

        fake.finishHeldProjects()
        let (settled, candidates) = await rescan.value

        #expect(settled)
        #expect(fake.generalAccesses.isEmpty)
        #expect(!store.isScanningProjects)
        #expect(candidates == [modules])
    }

    /// A scan started outside the queue, like the menu bar's, is still discovering
    /// when the scheduled clean's rescan replaces it. The old discovery's stream
    /// ends with groups it has taken in but not shown yet. Those belong to the old
    /// scan, so they must not land in the new list, where the new discovery's git
    /// check would mark them clean.
    @Test
    func replacedDiscoveryLeavesNoGroupsBehind() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let modules = try fixture.project("app")

        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.holdsProjects = true
        fake.projectEvents = [.projectGroupFound(group(artifact(at: modules)))]
        let store = fake.makeStore()

        await store.scanDeveloper()
        #expect(await eventually { store.isScanningProjects })
        for _ in 0..<5 { await Task.yield() }

        fake.holdsProjects = false
        fake.projectEvents = []
        #expect(await store.rescanBeforeSafeCleanup())
        for _ in 0..<20 { await Task.yield() }

        #expect(store.projectGroups.isEmpty)
        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    /// The queue stays held while the rescan waits, so the wait ends when the
    /// queue's own App Caches and Dev Tools step would. The clean then leaves
    /// projects out, and discovery still finishes for Dev Tools.
    @Test
    func discoveryPastItsPatienceLeavesProjectsOut() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let modules = try fixture.project("app")

        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.holdsProjects = true
        fake.projectEvents = [.projectGroupFound(group(artifact(at: modules)))]
        let store = fake.makeStore()
        store.cacheStepPatience = 0.2

        let settled = await store.rescanBeforeSafeCleanup()

        #expect(!settled)
        #expect(!store.isScanQueueHeld)
        #expect(store.isScanningProjects)

        fake.finishHeldProjects()
        await store.awaitProjectDiscovery()
        #expect(!store.isScanningProjects)
        #expect(store.manualSafeCleanupCandidates().map(\.path) == [modules])
        #expect(store.manualSafeCleanupCandidates(includingProjects: false).isEmpty)
    }

    /// A project worked on recently is Check First (#194). Waiting for discovery
    /// must not bring it into the scheduled clean beside a stale one.
    @Test
    func checkFirstProjectStaysOut() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let stale = try fixture.project("stale")
        let active = try fixture.project("active")
        var activeArtifact = artifact(at: active, level: .medium)
        activeArtifact.checkFirstReason = .usedRecently

        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.projectEvents = [
            .projectGroupFound(group(artifact(at: stale))),
            .projectGroupFound(group(activeArtifact))
        ]
        let store = fake.makeStore()

        #expect(await store.rescanBeforeSafeCleanup())

        #expect(Set(store.projectGroups.flatMap(\.artifacts).map(\.path)) == [stale, active])
        #expect(store.manualSafeCleanupCandidates().map(\.path) == [stale])
    }

    /// The git check marks a PHP project with uncommitted changes dirty. The list
    /// is built after that check, so the project stays out.
    @Test
    func projectWithUncommittedChangesStaysOut() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let stale = try fixture.project("stale")
        let vendor = try fixture.project("php", marker: "composer.json", folder: "vendor")

        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        // The scan's git check goes through the fake (#172): this project has
        // changes that are not committed.
        fake.gitAnswers[vendor.standardizedFileURL.path] = .dirty
        fake.projectEvents = [
            .projectGroupFound(group(artifact(at: stale))),
            .projectGroupFound(group(artifact(at: vendor, kind: .composerVendor), type: .composer))
        ]
        let store = fake.makeStore()

        #expect(await store.rescanBeforeSafeCleanup())

        let vendorStatus = store.projectGroups.flatMap(\.artifacts).first { $0.path == vendor }?.gitStatus
        #expect(vendorStatus == .dirty)
        #expect(store.manualSafeCleanupCandidates().map(\.path) == [stale])
    }

    // MARK: Helpers

    /// Projects under the home folder, where the safety policy offers their
    /// folders. It refuses the same folders under the temporary directory.
    private final class Fixture {
        private let folders = RealHomeFolders()
        private var root: URL?

        /// Makes `<name>/<marker>` and `<name>/<folder>`, and returns the folder.
        func project(_ name: String, marker: String = "package.json", folder: String = "node_modules") throws -> URL {
            let root = try self.root ?? folders.make(".purge-test-rescan-\(UUID().uuidString)")
            self.root = root
            let project = root.appendingPathComponent(name, isDirectory: true)
            let artifact = project.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent(marker))
            return artifact
        }

        func remove() { folders.remove() }
    }

    /// As discovery reports it: the git check has not run yet.
    private func artifact(
        at path: URL,
        kind: DeletableArtifactKind = .nodeModules,
        level: SafetyLevel = .safe
    ) -> ProjectCacheArtifact {
        ProjectCacheArtifact(
            kind: kind,
            path: path,
            projectRoot: path.deletingLastPathComponent(),
            sizeBytes: 1024,
            lastModified: .distantPast,
            isSelected: false,
            safetyInfo: SafetyInfo(level: level, headline: path.lastPathComponent, explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallSafety: .notApplicable,
            gitStatus: .unknown
        )
    }

    private func group(_ artifact: ProjectCacheArtifact, type: ProjectType = .node) -> ProjectGroup {
        ProjectGroup(
            displayName: artifact.projectRoot.lastPathComponent,
            rootPath: artifact.projectRoot,
            inferredTypes: [type],
            artifacts: [artifact]
        )
    }

    /// Check First, so it is never on the clean list itself. The folder does not exist.
    private func listedCacheRow() -> CacheItem {
        let folder = "purge-test-rescan-\(UUID().uuidString)"
        return CacheItem(
            definitionKey: folder,
            location: CacheLocation(
                path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/\(folder)"),
                sizeBytes: 1024,
                lastModified: .distantPast,
                folderName: folder
            ),
            appName: folder,
            safetyInfo: SafetyInfo(level: .medium, headline: folder, explanation: "", recoverySteps: "", reinstallCommand: nil),
            gitStatus: .clean
        )
    }

    private func eventually(
        timeout: TimeInterval = 30,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
