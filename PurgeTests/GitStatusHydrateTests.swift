import Foundation
import Testing
@testable import Purge

/// After a scan, Purge asks `git` about every App Caches and project row in the
/// background, which can take seconds. Rows can leave while it waits: an
/// exclusion, a clean, a new scan. Each answer must land on the row it was asked
/// for, or nowhere (#172).
@MainActor
@Suite("Git status after a scan")
struct GitStatusHydrateTests {
    /// Never created. The fake answers for `git`, so nothing here reads the disk.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PurgeGitStatusHydrateTests-\(UUID().uuidString)", isDirectory: true)

    // MARK: Project rows

    @Test
    func excludingAProjectWhileGitRunsKeepsEachStatusOnItsOwnRow() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let excluded = group("excluded", artifacts: ["node_modules", "target"])
        let kept = group("kept", artifacts: ["node_modules"])
        defer { ExcludedPathsStore.remove(path: excluded.rootPath) }

        await startProjectGitCheck(store, fake, groups: [excluded, kept])
        store.excludeProjectGroupFromScans(groupID: excluded.id)
        fake.gitAnswers = [
            key(excluded.artifacts[0].path): .clean,
            key(excluded.artifacts[1].path): .clean,
            key(kept.artifacts[0].path): .dirty,
        ]
        fake.finishHeldGitStatus()

        #expect(await eventually { !store.isScanningProjects })
        #expect(store.projectGroups.map(\.id) == [kept.id])
        #expect(store.projectGroups.flatMap(\.artifacts).map(\.gitStatus) == [.dirty])
    }

    @Test
    func aRowTheCheckWasNotAskedAboutStaysUnknown() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let asked = group("asked", artifacts: ["node_modules"])
        let arrived = group("arrived", artifacts: ["node_modules"])

        await startProjectGitCheck(store, fake, groups: [asked])
        // Same place in the list, different folder.
        store.projectGroups = [arrived]
        fake.gitAnswers = [key(asked.artifacts[0].path): .clean]
        fake.finishHeldGitStatus()

        #expect(await eventually { !store.isScanningProjects })
        #expect(store.projectGroups.flatMap(\.artifacts).map(\.gitStatus) == [.unknown])
        // Another row's "clean" must not make this Safe row part of Clean Safe Items.
        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    @Test
    func projectAnswersFromAReplacedScanAreDropped() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let old = group("old", artifacts: ["node_modules"])
        let new = group("new", artifacts: ["node_modules"])

        await startProjectGitCheck(store, fake, groups: [old])
        // A second Dev Tools scan clears the rows. Its own discovery is held.
        await store.scanDeveloper()
        #expect(await eventually { fake.projectScanCount == 2 })
        store.projectGroups = [new]
        fake.gitAnswers = [key(old.artifacts[0].path): .clean]
        fake.finishHeldGitStatus()

        #expect(await eventually { fake.gitStatusAnswerCount == 1 })
        #expect(store.projectGroups.flatMap(\.artifacts).map(\.gitStatus) == [.unknown])

        // The new scan's own check still fills the row in.
        fake.gitAnswers[key(new.artifacts[0].path)] = .dirty
        fake.finishHeldProjects()
        #expect(await eventually { fake.gitStatusRequests.count == 2 })
        fake.finishHeldGitStatus()
        #expect(await eventually { !store.isScanningProjects })
        #expect(store.projectGroups.flatMap(\.artifacts).map(\.gitStatus) == [.dirty])
    }

    // MARK: App Caches rows

    @Test
    func excludingACacheRowWhileGitRunsDoesNotBringItBack() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let excluded = cacheItem("com.example.excluded")
        let kept = cacheItem("com.example.kept")
        defer { ExcludedPathsStore.remove(path: excluded.path) }

        let scan = await startCacheGitCheck(store, fake, items: [excluded, kept])
        store.excludeFromScans(excluded)
        fake.gitAnswers = [key(excluded.path): .clean, key(kept.path): .dirty]
        fake.finishHeldGitStatus()
        await scan.value

        #expect(store.cacheItems.map(\.id) == [kept.id])
        #expect(store.cacheItems.map(\.gitStatus) == [.dirty])
    }

    @Test
    func cacheAnswersFromAReplacedScanAreDropped() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        let old = cacheItem("com.example.old")

        let first = await startCacheGitCheck(store, fake, items: [old])
        // A second App Caches scan clears the rows and is held before it finds any.
        let second = Task { await store.scanGeneral() }
        #expect(await eventually { fake.generalAccesses.count == 2 })
        fake.finishHeldGitStatus()
        await first.value

        #expect(store.cacheItems.isEmpty)
        // A stale row left behind would start another check, which must not hang.
        fake.holdsGitStatus = false
        fake.finishHeldGeneral()
        await second.value
    }

    // MARK: Helpers

    /// Runs a Dev Tools scan whose project discovery finds `groups`, and returns
    /// once the git check for them has started. The check stays open until the
    /// test calls `finishHeldGitStatus`.
    private func startProjectGitCheck(_ store: PurgeStore, _ fake: FakeScans, groups: [ProjectGroup]) async {
        fake.holdsProjects = true
        fake.holdsGitStatus = true
        let discoveries = fake.projectScanCount
        let checks = fake.gitStatusRequests.count
        await store.scanDeveloper()
        #expect(await eventually { fake.projectScanCount > discoveries })
        store.projectGroups = groups
        fake.finishHeldProjects()
        #expect(await eventually { fake.gitStatusRequests.count > checks })
    }

    /// Runs an App Caches scan that finds `items`, and returns it once the git check
    /// for them has started. The check stays open until the test calls
    /// `finishHeldGitStatus`.
    private func startCacheGitCheck(_ store: PurgeStore, _ fake: FakeScans, items: [CacheItem]) async -> Task<Void, Never> {
        fake.holdsGeneral = true
        fake.holdsGitStatus = true
        let scans = fake.generalAccesses.count
        let checks = fake.gitStatusRequests.count
        let scan = Task { await store.scanGeneral() }
        #expect(await eventually { fake.generalAccesses.count > scans })
        store.cacheItems = items
        fake.finishHeldGeneral()
        #expect(await eventually { fake.gitStatusRequests.count > checks })
        return scan
    }

    private func group(_ name: String, artifacts folders: [String]) -> ProjectGroup {
        let projectRoot = root.appendingPathComponent(name, isDirectory: true)
        return ProjectGroup(
            displayName: name,
            rootPath: projectRoot,
            inferredTypes: [],
            artifacts: folders.map { folder in
                ProjectCacheArtifact(
                    kind: DeletableArtifactKind(rawValue: folder) ?? .nodeModules,
                    path: projectRoot.appendingPathComponent(folder, isDirectory: true),
                    projectRoot: projectRoot,
                    sizeBytes: 1_000_000,
                    lastModified: .distantPast,
                    isSelected: false,
                    safetyInfo: safetyInfo(folder),
                    reinstallSafety: .notApplicable,
                    gitStatus: .unknown,
                    checkFirstReason: nil
                )
            }
        )
    }

    private func cacheItem(_ folder: String) -> CacheItem {
        CacheItem(
            definitionKey: folder,
            location: CacheLocation(
                path: root.appendingPathComponent(folder, isDirectory: true),
                sizeBytes: 1_000_000,
                lastModified: .distantPast,
                folderName: folder
            ),
            appName: folder,
            safetyInfo: safetyInfo(folder)
        )
    }

    private func safetyInfo(_ headline: String) -> SafetyInfo {
        SafetyInfo(level: .safe, headline: headline, explanation: "", recoverySteps: "", reinstallCommand: nil)
    }

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Waits for the store to settle. The deadline only stops a hang: other suites
    /// fill the cooperative thread pool on purpose for seconds at a time.
    private func eventually(
        timeout: TimeInterval = 30,
        _ condition: () -> Bool
    ) async -> Bool {
        // Counts only the time this loop was running: on CI the test host can
        // stall for tens of seconds with every suite waiting, and a wall-clock
        // deadline expires during the stall through no fault of the condition.
        var waited: TimeInterval = 0
        var last = Date()
        while !condition() {
            guard waited < timeout else { return false }
            try? await Task.sleep(for: .milliseconds(10))
            let now = Date()
            waited += min(now.timeIntervalSince(last), 0.25)
            last = now
        }
        return true
    }
}
