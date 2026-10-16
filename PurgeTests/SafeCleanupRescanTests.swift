import Foundation
import Testing
@testable import Purge

/// The rescan a scheduled clean, or the menu bar's Clean Now, runs before it picks
/// what to move (#173). Project discovery runs on after the Dev Tools scan returns,
/// so the clean list is only complete once discovery has settled.
@MainActor
@Suite("The safe clean's rescan settles before the clean list is built")
struct SafeCleanupRescanTests {

    /// A cold launch with a clean overdue: no App Caches rows yet, so the rescan
    /// scans App Caches too. Run after Dev Tools, that scan started a new generation
    /// and stopped project discovery, which then never cleared its flag. Dev Tools
    /// showed "scanning" until a manual rescan, and the clean left out every project.
    @Test
    func coldRescanFinishesProjectDiscovery() async throws {
        let folders = RealHomeFolders()
        defer { folders.remove() }
        let artifact = try makeProject(in: folders)

        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.projectEvents = [.projectGroupFound(group(for: artifact))]
        let store = fake.makeStore()

        await store.rescanBeforeSafeCleanup()

        #expect(fake.generalAccesses == [.full])
        #expect(fake.projectScanCount == 1)
        #expect(!store.isScanningProjects)
        #expect(store.manualSafeCleanupCandidates().map(\.path) == [artifact.path])
    }

    /// App Caches rows are already listed, so the rescan reuses them and only
    /// rescans Dev Tools. The clean list must still wait for project discovery,
    /// which is held open here until the rescan has had every chance to return.
    @Test
    func rescanReusingCacheRowsWaitsForProjectDiscovery() async throws {
        let folders = RealHomeFolders()
        defer { folders.remove() }
        let artifact = try makeProject(in: folders)

        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.holdsProjects = true
        fake.projectEvents = [.projectGroupFound(group(for: artifact))]
        let store = fake.makeStore()
        store.cacheItems = [listedCacheRow()]

        let rescan = Task {
            await store.rescanBeforeSafeCleanup()
            fake.log.append("rescan returned")
            return store.manualSafeCleanupCandidates().map(\.path)
        }
        #expect(await eventually { fake.projectScanCount == 1 })
        for _ in 0..<20 { await Task.yield() }
        #expect(!fake.log.contains("rescan returned"))

        fake.finishHeldProjects()
        let candidates = await rescan.value

        #expect(fake.generalAccesses.isEmpty)
        #expect(!store.isScanningProjects)
        #expect(candidates == [artifact.path])
    }

    // MARK: Helpers

    /// A Node project under the home folder, where the safety policy offers its
    /// `node_modules`. It refuses the same folder under the temporary directory.
    private func makeProject(in folders: RealHomeFolders) throws -> ProjectCacheArtifact {
        let root = try folders.make(".purge-test-rescan-\(UUID().uuidString)")
        let project = root.appendingPathComponent("app", isDirectory: true)
        let modules = project.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        return ProjectCacheArtifact(
            kind: .nodeModules,
            path: modules,
            projectRoot: project,
            sizeBytes: 1024,
            lastModified: .distantPast,
            isSelected: false,
            safetyInfo: SafetyInfo(level: .safe, headline: "node_modules", explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
    }

    private func group(for artifact: ProjectCacheArtifact) -> ProjectGroup {
        ProjectGroup(
            displayName: artifact.projectRoot.lastPathComponent,
            rootPath: artifact.projectRoot,
            inferredTypes: [.node],
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
