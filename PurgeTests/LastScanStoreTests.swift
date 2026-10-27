import Foundation
import Testing
@testable import Purge

/// The store with a saved last scan (#283), driven by `FakeScans`. The saved rows
/// must stay out of every list a clean, a count or a selection reads, give way to
/// live rows as the scan finds them, and reach the file only from a finished scan.
@MainActor
@Suite("Saved last scan in the store")
struct LastScanStoreTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Kept apart

    @Test
    func savedRowsNeverReachACleanOrCountAsResults() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        await store.loadLastScan()

        #expect(!store.lastScanRows.cacheItems.isEmpty)
        #expect(!store.lastScanRows.devTools.isEmpty)
        #expect(!store.lastScanRows.projectGroups.isEmpty)
        #expect(!store.lastScanRows.simulatorRuntimes.isEmpty)
        #expect(!store.lastScanRows.installedApps.isEmpty)
        #expect(!store.lastScanRows.orphanLeftovers.isEmpty)

        // Nothing landed in the live lists, so nothing can be selected or moved.
        #expect(store.cacheItems.isEmpty)
        #expect(store.devTools.isEmpty)
        #expect(store.projectGroups.isEmpty)
        #expect(store.simulatorRuntimes.isEmpty)
        #expect(store.installedApps.isEmpty)
        #expect(store.orphanLeftovers.isEmpty)
        #expect(store.manualSafeCleanupCandidates().isEmpty)
        #expect(store.selectedGeneralDeletionCandidates.isEmpty)
        #expect(store.selectedDeveloperDeletionCandidates.isEmpty)
        #expect(store.selectedCount == 0)

        // No step counts as scanned, so the launch still scans all of them, and the
        // menu bar and Shortcuts, which ask the same question, still wait for a scan.
        for step in ScanStep.allCases {
            #expect(!store.hasSessionResults(for: step))
        }
        #expect(LaunchScanPlan.steps(
            hasFullDiskAccess: true,
            loadedThisSession: Set(ScanStep.allCases.filter { store.hasSessionResults(for: $0) })
        ) == LaunchScanPlan.steps(hasFullDiskAccess: true, loadedThisSession: []))
        #expect(store.overviewPhase(for: .appCaches) == .notScanned)
    }

    // MARK: Following the scan

    @Test
    func aLandingRowTakesItsSavedTwinsPlace() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        await store.loadLastScan()
        let savedRuntime = try #require(store.lastScanRows.simulatorRuntimes.first)
        let savedCache = try #require(store.lastScanRows.cacheItems.first)

        store.simulatorRuntimes = [savedRuntime]
        // Same folder, grouped under another id this time: still the same row.
        store.cacheItems = [CacheItem(
            definitionKey: "com.example.grouped",
            locations: savedCache.locations,
            appName: "Grouped",
            safetyInfo: savedCache.safetyInfo
        )]

        #expect(store.lastScanRows.simulatorRuntimes.isEmpty)
        #expect(store.lastScanRows.cacheItems.isEmpty)
        #expect(!store.lastScanRows.devTools.isEmpty)
    }

    @Test
    func aFinishedScanDropsSavedRowsItDidNotFind() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        await store.loadLastScan()

        store.startLaunchScans()
        #expect(await eventually { isIdle(store) && store.lastScanRows.isEmpty(.projects) })
        #expect(await eventually { store.lastScanWritesFinished > 0 && store.lastScanWriteTask == nil })

        // The fake scans find nothing, so everything saved is gone from the Mac.
        for section in LastScanSection.allCases where section != .apps && section != .leftovers {
            #expect(store.lastScanRows.isEmpty(section), "\(section)")
        }
        #expect(store.lastScanRows.savedAt[.appCaches] == nil)
    }

    @Test
    func aSnapshotThatLoadsAfterTheScanShowsNothing() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let original = try Data(contentsOf: file)
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        store.startLaunchScans()
        #expect(await eventually { isIdle(store) && store.hasFinishedLists(for: .devTools) })
        #expect(await eventually { store.lastScanWritesFinished > 0 && store.lastScanWriteTask == nil })

        // The scan beat the read. Put the old rows back in the file to be sure the
        // store, not an emptied file, keeps them off the screen.
        try original.write(to: file)
        await store.loadLastScan()

        #expect(store.lastScanRows.isEmpty(.appCaches))
        #expect(store.lastScanRows.isEmpty(.devTools))
        #expect(store.lastScanRows.isEmpty(.projects))
        #expect(store.lastScanRows.isEmpty(.runtimes))
        // Apps and leftovers need Full Disk Access, which the fake doesn't have, so
        // those lists were never scanned and their saved rows still show.
        #expect(!store.lastScanRows.isEmpty(.apps))
    }

    // MARK: Writing the file

    @Test
    func aStoreWithNoFinishedScanNeverWrites() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let before = try Data(contentsOf: file)
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        fake.holdsGeneral = true
        store.startLaunchScans()
        #expect(await eventually { fake.generalAccesses.count == 1 })

        // Rows from a scan still running are partial.
        store.cacheItems = [cacheItem(home.appendingPathComponent("Library/Caches/com.example.partial"))]
        try await Task.sleep(for: .milliseconds(900))

        #expect(store.lastScanWritesFinished == 0)
        #expect(try Data(contentsOf: file) == before)
        fake.cleanUp()
        #expect(await eventually { isIdle(store) })
        #expect(await eventually { store.lastScanWritesFinished > 0 && store.lastScanWriteTask == nil })
    }

    @Test
    func aFinishedScanWritesItsListsAndLaterChanges() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        store.startLaunchScans()
        #expect(await eventually { isIdle(store) && store.hasFinishedLists(for: .devTools) })
        #expect(await eventually { store.lastScanWritesFinished > 0 && store.lastScanWriteTask == nil })
        let reader = LastScanStore(fileURL: file, appBuild: build)
        #expect(reader.load()?.appCaches?.rows.isEmpty == true)

        // A clean or an exclusion later in the session changes a finished list.
        let written = store.lastScanWritesFinished
        let found = home.appendingPathComponent("Library/Caches/com.example.found")
        store.cacheItems = [cacheItem(found)]
        #expect(await eventually { store.lastScanWritesFinished > written && store.lastScanWriteTask == nil })
        #expect(reader.load()?.appCaches?.rows.flatMap(\.urls) == [found])
    }

    /// Excluding a folder takes its saved row off the screen at once, as it does a
    /// live one; the reader skips it at the next launch.
    @Test
    func excludingAFolderTakesItsSavedRowOffTheScreen() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        await store.loadLastScan()
        let saved = try #require(store.lastScanRows.devTools.first?.paths.first)
        defer { ExcludedPathsStore.remove(path: saved) }

        store.excludeFoldersFromScans([saved])

        #expect(store.lastScanRows.devTools.isEmpty)
    }

    /// `hasSessionCacheScan` stays true through a rescan that never finishes, so the
    /// partial list must not rewrite the total a reopen shows.
    @Test
    func aRescanThatHasNotFinishedLeavesTheSavedTotalAlone() async throws {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        store.startLaunchScans()
        #expect(await eventually { isIdle(store) && store.hasFinishedLists(for: .appCaches) })

        store.cacheItems = [cacheItem(home.appendingPathComponent("Library/Caches/com.example.big"), bytes: 5_000_000_000)]
        #expect(await eventually { store.scanRecords[.appCaches]?.bytes == 5_000_000_000 })

        store.lastScanListsStarted([.appCaches])
        store.cacheItems = []
        try await Task.sleep(for: .milliseconds(900))
        #expect(store.scanRecords[.appCaches]?.bytes == 5_000_000_000)
    }

    // MARK: Helpers

    private let build = "test-build"

    /// A fake scan and a saved file with one row in every list.
    private func setUp() throws -> (FakeScans, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LastScanStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(LastScanStore.fileName)
        let marker = UUID().uuidString
        let savedAt = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        var snapshot = LastScanSnapshot(appBuild: build)
        snapshot.appCaches = .init(savedAt: savedAt, rows: [
            SavedCacheItem(cacheItem(home.appendingPathComponent("Library/Caches/com.example.saved-\(marker)")))
        ])
        snapshot.devTools = .init(savedAt: savedAt, rows: [SavedDevTool(DevTool(
            definitionKey: "npm",
            toolName: "npm cache",
            paths: [home.appendingPathComponent(".npm-lastscan-\(marker)")],
            sizeBytes: 9_000,
            isDetected: true,
            safetyInfo: safety(.safe)
        ))])
        snapshot.runtimes = .init(savedAt: savedAt, rows: [SavedSimulatorRuntime(SimulatorRuntime(
            id: "runtime-\(marker)",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
            platformName: "iOS",
            version: "26.0",
            build: "23A",
            kind: "Patchable Disk Image",
            state: "Ready",
            sizeBytes: 8_000_000_000,
            lastUsedAt: nil,
            deviceCount: nil,
            locationURL: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes/iOS_\(marker)"),
            safetyInfo: safety(.medium)
        ))])
        let root = home.appendingPathComponent("Developer/lastscan-\(marker)")
        snapshot.projects = .init(savedAt: savedAt, rows: [SavedProjectGroup(ProjectGroup(
            displayName: "site",
            rootPath: root,
            inferredTypes: [.node],
            artifacts: [ProjectCacheArtifact(
                kind: .nodeModules,
                path: root.appendingPathComponent("node_modules"),
                projectRoot: root,
                sizeBytes: 300,
                lastModified: .distantPast,
                isSelected: false,
                safetyInfo: safety(.safe),
                reinstallSafety: .reinstallable,
                gitStatus: .clean,
                checkFirstReason: nil
            )]
        ))])
        snapshot.apps = .init(savedAt: savedAt, rows: [SavedInstalledApp(InstalledApp(
            name: "Example",
            bundleURL: URL(fileURLWithPath: "/Applications/LastScan-\(marker).app"),
            bundleID: "com.example.\(marker)",
            bundleSizeBytes: 50_000,
            isRunning: false
        ), removableBytes: 60_000)])
        snapshot.leftovers = .init(savedAt: savedAt, rows: [SavedLeftover(UninstallItem(
            path: home.appendingPathComponent("Library/Application Support/com.gone.\(marker)"),
            sizeBytes: 700,
            category: .applicationSupport,
            safetyInfo: safety(.medium),
            matchReason: .bundleID,
            isSelected: false
        ))])
        LastScanStore(fileURL: file, appBuild: build).save(Set(LastScanSection.allCases), from: snapshot)
        return (FakeScans(), file)
    }

    private func tearDown(_ fake: FakeScans, _ file: URL) {
        fake.cleanUp()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func safety(_ level: SafetyLevel) -> SafetyInfo {
        SafetyInfo(level: level, headline: "h", explanation: "e", recoverySteps: "", reinstallCommand: nil)
    }

    private func cacheItem(_ url: URL, bytes: Int64 = 1_000) -> CacheItem {
        CacheItem(
            definitionKey: nil,
            location: CacheLocation(path: url, sizeBytes: bytes, lastModified: .distantPast, folderName: url.lastPathComponent),
            appName: url.lastPathComponent,
            safetyInfo: safety(.safe)
        )
    }

    private func isIdle(_ store: PurgeStore) -> Bool {
        store.scanQueueTask == nil
            && !store.scanQueue.isRunning
            && !store.isScanningAll
            && !store.isScanningProjects
    }

    /// Counts only the time this loop ran, as in `ScanQueueStoreTests`.
    private func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
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
