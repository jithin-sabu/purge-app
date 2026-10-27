import Foundation
import Testing
@testable import Purge

/// The last scan's saved file (#283): what goes in, what never does, and when a
/// launch refuses to show it.
@Suite("The saved last scan")
struct LastScanSnapshotTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Rows

    @Test
    func eachRowTypeRoundTripsWithItsIDAndFigures() throws {
        let cache = CacheItem(
            definitionKey: "com.example.lastscan",
            location: CacheLocation(
                path: home.appendingPathComponent("Library/Caches/com.example.lastscan"),
                sizeBytes: 4_000,
                lastModified: Date(timeIntervalSince1970: 1_000),
                folderName: "com.example.lastscan"
            ),
            appName: "Example",
            safetyInfo: safety(.safe),
            reinstallSafety: .reinstallable,
            gitStatus: .clean
        )
        let tool = DevTool(
            definitionKey: "npm",
            toolName: "npm cache",
            paths: [home.appendingPathComponent(".npm/_cacache")],
            sizeBytes: 9_000,
            lastModified: Date(timeIntervalSince1970: 2_000),
            isDetected: true,
            safetyInfo: safety(.safe)
        )
        let device = SimulatorDevice(
            id: UUID(),
            deviceName: "iPhone 17",
            runtimeVersion: "iOS 26.0",
            isAvailable: true,
            lastBootedAt: nil,
            sizeOnDisk: 1_500,
            folderURL: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/X"),
            isSelected: false,
            safetyInfo: safety(.medium)
        )
        let runtime = runtime(id: "R1")
        let group = ProjectGroup(
            displayName: "site",
            rootPath: home.appendingPathComponent("Developer/site"),
            inferredTypes: [.node],
            artifacts: [ProjectCacheArtifact(
                kind: .nodeModules,
                path: home.appendingPathComponent("Developer/site/node_modules"),
                projectRoot: home.appendingPathComponent("Developer/site"),
                sizeBytes: 300,
                lastModified: Date(timeIntervalSince1970: 3_000),
                isSelected: true,
                safetyInfo: safety(.medium),
                reinstallSafety: .reinstallable,
                gitStatus: .dirty,
                checkFirstReason: .usedRecently
            )]
        )
        let app = InstalledApp(
            name: "Example",
            bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleID: "com.example.app",
            bundleSizeBytes: 50_000,
            isRunning: true,
            lastOpened: Date(timeIntervalSince1970: 4_000)
        )
        let leftover = UninstallItem(
            path: home.appendingPathComponent("Library/Application Support/com.gone.app"),
            sizeBytes: 700,
            category: .applicationSupport,
            safetyInfo: safety(.medium),
            matchReason: .ownerLedger,
            isSelected: true,
            ownerBundleIDs: ["com.gone.app"]
        )

        var snapshot = LastScanSnapshot(appBuild: "7")
        let now = Date(timeIntervalSince1970: 5_000)
        snapshot.appCaches = .init(savedAt: now, rows: [SavedCacheItem(cache)])
        snapshot.devTools = .init(savedAt: now, rows: [SavedDevTool(tool)])
        snapshot.simulators = .init(savedAt: now, rows: [SavedSimulatorDevice(device)])
        snapshot.runtimes = .init(savedAt: now, rows: [SavedSimulatorRuntime(runtime)])
        snapshot.projects = .init(savedAt: now, rows: [SavedProjectGroup(group)])
        snapshot.apps = .init(savedAt: now, rows: [SavedInstalledApp(app, removableBytes: 80_000)])
        snapshot.leftovers = .init(savedAt: now, rows: [SavedLeftover(leftover)])

        let decoded = try JSONDecoder().decode(LastScanSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        let rows = LastScanRows(decoded, sections: Set(LastScanSection.allCases))

        #expect(rows.cacheItems.map(\.id) == [cache.id])
        #expect(rows.cacheItems.first?.sizeBytes == 4_000)
        #expect(rows.cacheItems.first?.safetyInfo.level == .safe)
        #expect(rows.cacheItems.first?.isSelected == false)
        #expect(rows.devTools.map(\.id) == [tool.id])
        #expect(rows.devTools.first?.sizeBytes == 9_000)
        #expect(rows.simulatorDevices.map(\.id) == [device.id])
        #expect(rows.simulatorRuntimes.map(\.id) == ["R1"])
        #expect(rows.projectGroups.map(\.id) == [group.id])
        #expect(rows.projectGroups.first?.artifacts.first?.isSelected == false)
        #expect(rows.projectGroups.first?.artifacts.first?.checkFirstReason == .usedRecently)
        #expect(rows.projectGroups.first?.artifacts.first?.gitStatus == .dirty)
        #expect(rows.installedApps.map(\.bundleURL.path) == ["/Applications/Example.app"])
        // Whether it runs is this session's question, never the file's.
        #expect(rows.installedApps.first?.isRunning == false)
        #expect(rows.removableBytesByAppPath["/Applications/Example.app"] == 80_000)
        #expect(rows.orphanLeftovers.map(\.path) == [leftover.path])
        #expect(rows.orphanLeftovers.first?.isSelected == false)
        #expect(rows.orphanLeftovers.first?.matchReason == .ownerLedger)
        #expect(rows.savedAt[.apps] == now)
    }

    // MARK: Privacy

    /// The file sits where any app can read it, so nothing from a folder macOS
    /// protects goes into it: no Documents project, no container cache, and nothing
    /// reached through a link into one (`~/Developer` linked to `~/Documents/dev`).
    /// Checked on the bytes the store writes, by markers with no slash in them, so
    /// the way JSON spells "/" can't hide a row.
    @MainActor
    @Test
    func aRowUnderAProtectedFolderIsNeverWritten() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("LastScanLinkedHome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixtureHome = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureHome.appendingPathComponent("Documents/dev"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixtureHome.appendingPathComponent("Developer"),
            withDestinationURL: fixtureHome.appendingPathComponent("Documents/dev")
        )
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        store.cacheItems = [
            cacheItem(at: fixtureHome.appendingPathComponent("Library/Caches/com.example.open")),
            cacheItem(at: fixtureHome.appendingPathComponent("Library/Containers/com.example.boxed/Data/Library/Caches"))
        ]
        store.projectGroups = [
            projectGroup(root: fixtureHome.appendingPathComponent("Documents/secret-client")),
            projectGroup(root: fixtureHome.appendingPathComponent("Developer/linked-client")),
            projectGroup(root: fixtureHome.appendingPathComponent("Projects/open-project"))
        ]
        store.orphanLeftovers = [UninstallItem(
            path: fixtureHome.appendingPathComponent("Library/Group Containers/group.com.example.gone"),
            sizeBytes: 10,
            category: .groupContainers,
            safetyInfo: safety(.medium),
            matchReason: .groupID,
            isSelected: false
        )]

        let file = base.appendingPathComponent(LastScanStore.fileName)
        let writer = LastScanStore(fileURL: file, appBuild: "36", home: fixtureHome)
        writer.save(Set(LastScanSection.allCases), from: store.makeLastScanSnapshot(Set(LastScanSection.allCases)))
        writer.flush()

        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(!written.contains("com.example.boxed"))
        #expect(!written.contains("group.com.example.gone"))
        #expect(!written.contains("secret-client"))
        #expect(!written.contains("linked-client"))
        #expect(written.contains("com.example.open"))
        #expect(written.contains("open-project"))
    }

    /// A clean's forget queued after a save wins, even when that save was built
    /// before the clean: the file sees them in the order they were called.
    @Test
    func aForgetQueuedAfterASaveIsNotUndoneByIt() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LastScanStore(fileURL: file, appBuild: "36")
        let cleaned = home.appendingPathComponent("Library/Caches/com.example.cleaned-\(UUID().uuidString)")
        var older = LastScanSnapshot(appBuild: "36")
        older.appCaches = .init(savedAt: Date(), rows: [SavedCacheItem(cacheItem(at: cleaned))])

        for _ in 0..<20 {
            store.save([.appCaches], from: older)
            store.forget(paths: [cleaned.path])
            #expect(store.load()?.appCaches?.rows.isEmpty == true)
        }
    }

    // MARK: When a launch refuses the file

    @Test
    func aNewBuildDropsTheRowsAndTheFile() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var update = LastScanSnapshot(appBuild: "36")
        update.runtimes = .init(savedAt: Date(), rows: [SavedSimulatorRuntime(runtime(id: "R1"))])
        let writer = LastScanStore(fileURL: file, appBuild: "36")
        writer.save([.runtimes], from: update)
        writer.flush()
        #expect(LastScanStore(fileURL: file, appBuild: "36").load()?.runtimes?.rows.count == 1)

        #expect(LastScanStore(fileURL: file, appBuild: "37").load() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func anotherVersionOfTheFileReadsAsEmpty() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var snapshot = LastScanSnapshot(appBuild: "36")
        snapshot.version = LastScanSnapshot.currentVersion + 1
        try JSONEncoder().encode(snapshot).write(to: file)
        #expect(LastScanStore(fileURL: file, appBuild: "36").load() == nil)

        try Data("not json".utf8).write(to: file)
        #expect(LastScanStore(fileURL: file, appBuild: "36").load() == nil)
    }

    @Test
    func savingOneSectionKeepsTheOthers() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LastScanStore(fileURL: file, appBuild: "36")
        var first = LastScanSnapshot(appBuild: "36")
        first.runtimes = .init(savedAt: Date(), rows: [SavedSimulatorRuntime(runtime(id: "R1"))])
        store.save([.runtimes], from: first)

        var second = LastScanSnapshot(appBuild: "36")
        second.leftovers = .init(savedAt: Date(), rows: [])
        store.save([.leftovers], from: second)

        let loaded = try #require(store.load())
        #expect(loaded.runtimes?.rows.map(\.id) == ["R1"])
        #expect(loaded.leftovers?.rows.isEmpty == true)
    }

    /// A clean takes what it removed out of the file, so a list this session never
    /// finished scanning can't bring it back at the next launch.
    @Test
    func forgettingAPathDropsOnlyItsRows() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LastScanStore(fileURL: file, appBuild: "36")
        let kept = home.appendingPathComponent("Library/Caches/com.example.kept")
        let cleaned = home.appendingPathComponent("Library/Caches/com.example.cleaned")
        var update = LastScanSnapshot(appBuild: "36")
        update.appCaches = .init(savedAt: Date(), rows: [SavedCacheItem(cacheItem(at: kept)), SavedCacheItem(cacheItem(at: cleaned))])
        store.save([.appCaches], from: update)

        store.forget(paths: [cleaned.path])

        #expect(store.load()?.appCaches?.rows.flatMap(\.urls) == [kept])
    }

    /// A launch without Full Disk Access drops anything excluded since it was saved.
    @Test
    func anExcludedFolderIsLeftOutWhenTheFileIsRead() {
        let excluded = home.appendingPathComponent("Library/Caches/com.example.lastscan-excluded-\(UUID().uuidString)")
        let other = home.appendingPathComponent("Library/Caches/com.example.lastscan-other")
        ExcludedPathsStore.write(path: excluded, displayName: "excluded")
        defer { ExcludedPathsStore.remove(path: excluded) }
        var snapshot = LastScanSnapshot(appBuild: "36")
        snapshot.appCaches = .init(savedAt: Date(), rows: [SavedCacheItem(cacheItem(at: excluded)), SavedCacheItem(cacheItem(at: other))])

        let readable = PurgeStore.readableLastScan(snapshot, access: .limited)

        #expect(readable?.appCaches?.rows.flatMap(\.urls) == [other])
    }

    // MARK: Helpers

    private func safety(_ level: SafetyLevel) -> SafetyInfo {
        SafetyInfo(level: level, headline: "h", explanation: "e", recoverySteps: "", reinstallCommand: nil)
    }

    private func cacheItem(at url: URL) -> CacheItem {
        CacheItem(
            definitionKey: nil,
            location: CacheLocation(path: url, sizeBytes: 1_000, lastModified: .distantPast, folderName: url.lastPathComponent),
            appName: url.lastPathComponent,
            safetyInfo: safety(.safe)
        )
    }

    private func projectGroup(root: URL) -> ProjectGroup {
        ProjectGroup(
            displayName: root.lastPathComponent,
            rootPath: root,
            inferredTypes: [.node],
            artifacts: [ProjectCacheArtifact(
                kind: .nodeModules,
                path: root.appendingPathComponent("node_modules"),
                projectRoot: root,
                sizeBytes: 100,
                lastModified: .distantPast,
                isSelected: false,
                safetyInfo: safety(.safe),
                reinstallSafety: .reinstallable,
                gitStatus: .clean,
                checkFirstReason: nil
            )]
        )
    }

    private func runtime(id: String) -> SimulatorRuntime {
        SimulatorRuntime(
            id: id,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
            platformName: "iOS",
            version: "26.0",
            build: "23A",
            kind: "Patchable Disk Image",
            state: "Ready",
            sizeBytes: 8_000_000_000,
            lastUsedAt: nil,
            deviceCount: 2,
            locationURL: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes/iOS_23A"),
            safetyInfo: safety(.medium)
        )
    }

    private func scratchFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LastScanSnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(LastScanStore.fileName)
    }
}
