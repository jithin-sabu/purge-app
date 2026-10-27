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
        #expect(!store.lastScanRows.simulatorDevices.isEmpty)
        #expect(!store.lastScanRows.installedApps.isEmpty)
        #expect(!store.lastScanRows.orphanLeftovers.isEmpty)

        // Nothing landed in the live lists, so nothing can be selected or moved.
        #expect(store.cacheItems.isEmpty)
        #expect(store.devTools.isEmpty)
        #expect(store.projectGroups.isEmpty)
        #expect(store.simulatorRuntimes.isEmpty)
        #expect(store.simulatorDevices.isEmpty)
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

    /// No setter ticks a saved row's id, single row or Select All, or the live row
    /// would land already ticked. Simulators and runtimes are removed permanently.
    @Test
    func savedIDsNeverEnterTheSelection() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        await store.loadLastScan()
        let savedCache = try #require(store.lastScanRows.cacheItems.first)
        let savedTool = try #require(store.lastScanRows.devTools.first)
        let savedDevice = try #require(store.lastScanRows.simulatorDevices.first)
        let savedRuntime = try #require(store.lastScanRows.simulatorRuntimes.first)
        let savedLeftover = try #require(store.lastScanRows.orphanLeftovers.first)
        let savedApp = try #require(store.lastScanRows.installedApps.first)

        store.setAllCachesSelected(true, ids: [savedCache.id])
        store.setCacheSelected(id: savedCache.id, isSelected: true)
        store.setDevToolSelected(id: savedTool.id, isSelected: true)
        store.setSimulatorDeviceSelected(id: savedDevice.id, isSelected: true)
        store.setSimulatorRuntimeSelected(id: savedRuntime.id, isSelected: true)
        store.setAllOrphansSelected(true, ids: [savedLeftover.id])
        store.toggleOrphanSelected(id: savedLeftover.id)
        store.toggleAppSelected(id: savedApp.id)
        store.setAllAppsSelected(true, ids: [savedApp.id])

        #expect(store.scanSelection.cacheIDs.isEmpty)
        #expect(store.scanSelection.devToolIDs.isEmpty)
        #expect(store.scanSelection.simulatorIDs.isEmpty)
        #expect(store.scanSelection.simulatorRuntimeIDs.isEmpty)
        #expect(store.orphanSelectedIDs.isEmpty)
        #expect(store.selectedAppIDs.isEmpty)

        // Nothing reaches the uninstaller either.
        #expect(store.selectedApps.isEmpty)
        await store.requestUninstallSelectedApps()
        #expect(store.uninstallPlan == nil)

        // The live twins land unticked.
        store.cacheItems = [savedCache]
        store.simulatorRuntimes = [savedRuntime]
        #expect(store.selectedGeneralDeletionCandidates.isEmpty)
        #expect(store.selectedDeveloperDeletionCandidates.isEmpty)
    }

    /// An app deleted outside Purge while the file is still being read stays gone:
    /// the read leaves out what was forgotten, and so does the file (#283 review).
    @Test
    func anAppRemovedBeforeTheLaunchReadFinishesStaysGone() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let lastScanStore = LastScanStore(fileURL: file, appBuild: build)
        let savedApp = try #require(lastScanStore.load()?.apps?.rows.first?.bundleURL)
        let store = fake.makeStore(lastScanStore: lastScanStore)

        // The deleted-apps watcher drains its queue before the read lands.
        store.forgetRemovedApp(at: savedApp)
        await store.loadLastScan()

        #expect(store.lastScanRows.installedApps.isEmpty)
        #expect(!store.lastScanRows.orphanLeftovers.isEmpty)
        lastScanStore.flush()
        #expect(lastScanStore.load()?.apps?.rows.isEmpty == true)
    }

    /// Quitting within the half-second wait still writes the change.
    @Test
    func quittingWritesWhatTheWaitStillHolds() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        store.startLaunchScans()
        #expect(await eventually { isIdle(store) && store.hasFinishedLists(for: .devTools) })
        #expect(await eventually { store.lastScanWriteCount > 0 && store.lastScanWriteTask == nil })

        let found = home.appendingPathComponent("Library/Caches/com.example.just-before-quit")
        store.cacheItems = [cacheItem(found)]
        #expect(store.lastScanWriteTask != nil)
        store.flushLastScanWrites()

        #expect(LastScanStore(fileURL: file, appBuild: build).load()?.appCaches?.rows.flatMap(\.urls) == [found])
    }

    // MARK: Following the scan

    @Test
    func aLandingRowTakesItsSavedTwinsPlace() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        await store.loadLastScan()
        let savedRuntime = try #require(store.lastScanRows.simulatorRuntimes.first)
        let savedDevice = try #require(store.lastScanRows.simulatorDevices.first)
        let savedCache = try #require(store.lastScanRows.cacheItems.first)

        store.simulatorRuntimes = [savedRuntime]
        store.simulatorDevices = [savedDevice]
        // Same folder, grouped under another id this time: still the same row.
        store.cacheItems = [CacheItem(
            definitionKey: "com.example.grouped",
            locations: savedCache.locations,
            appName: "Grouped",
            safetyInfo: savedCache.safetyInfo
        )]

        #expect(store.lastScanRows.simulatorRuntimes.isEmpty)
        #expect(store.lastScanRows.simulatorDevices.isEmpty)
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
        #expect(await eventually { store.lastScanWriteCount > 0 && store.lastScanWriteTask == nil })

        store.lastScanStore?.flush()
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
        #expect(await eventually { store.lastScanWriteCount > 0 && store.lastScanWriteTask == nil })
        store.lastScanStore?.flush()

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

        #expect(store.lastScanWriteCount == 0)
        #expect(try Data(contentsOf: file) == before)
        fake.cleanUp()
        #expect(await eventually { isIdle(store) })
        #expect(await eventually { store.lastScanWriteCount > 0 && store.lastScanWriteTask == nil })
        store.lastScanStore?.flush()
    }

    @Test
    func aFinishedScanWritesItsListsAndLaterChanges() async throws {
        let (fake, file) = try setUp()
        defer { tearDown(fake, file) }
        let store = fake.makeStore(lastScanStore: LastScanStore(fileURL: file, appBuild: build))
        store.startLaunchScans()
        #expect(await eventually { isIdle(store) && store.hasFinishedLists(for: .devTools) })
        #expect(await eventually { store.lastScanWriteCount > 0 && store.lastScanWriteTask == nil })
        store.lastScanStore?.flush()
        let reader = LastScanStore(fileURL: file, appBuild: build)
        #expect(reader.load()?.appCaches?.rows.isEmpty == true)

        // A clean or an exclusion later in the session changes a finished list.
        let written = store.lastScanWriteCount
        let found = home.appendingPathComponent("Library/Caches/com.example.found")
        store.cacheItems = [cacheItem(found)]
        #expect(await eventually { store.lastScanWriteCount > written && store.lastScanWriteTask == nil })
        store.lastScanStore?.flush()
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
        snapshot.simulators = .init(savedAt: savedAt, rows: [SavedSimulatorDevice(SimulatorDevice(
            id: UUID(),
            deviceName: "iPhone 17",
            runtimeVersion: "iOS 26.0",
            isAvailable: true,
            lastBootedAt: nil,
            sizeOnDisk: 2_000_000_000,
            folderURL: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(marker)"),
            isSelected: false,
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
        let saver = LastScanStore(fileURL: file, appBuild: build)
        saver.save(Set(LastScanSection.allCases), from: snapshot)
        saver.flush()
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
