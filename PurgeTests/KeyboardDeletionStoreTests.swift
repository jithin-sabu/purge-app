import Foundation
import Testing
@testable import Purge

/// ⌘⌫ on one row (#96). Each tab opens the sheet and route it already has, for
/// that row alone. These check that the one row never leaks into a later
/// Clean Selected, that the user's other ticks survive, and that rows removed
/// permanently, or never offered for the Trash, are refused.
///
/// Everything lives in a temporary home, and cleans go through a fake Trash
/// that moves nothing.
@MainActor
@Suite("Command-Delete on one row")
struct KeyboardDeletionStoreTests {
    private let fm = FileManager.default

    private static let safeInfo = SafetyInfo(
        level: .safe, headline: "Cache", explanation: "", recoverySteps: "", reinstallCommand: nil
    )

    private func makeHome() throws -> URL {
        let home = fm.temporaryDirectory.appendingPathComponent("purge-96-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func cacheFolder(_ home: URL, _ name: String) throws -> URL {
        let folder = home.appendingPathComponent("Library/Caches/\(name)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: folder.appendingPathComponent("data"))
        return folder
    }

    private func cacheRow(_ path: URL) -> CacheItem {
        CacheItem(
            definitionKey: nil,
            location: CacheLocation(path: path, sizeBytes: 1_000, lastModified: .distantPast, folderName: path.lastPathComponent),
            appName: path.lastPathComponent,
            safetyInfo: Self.safeInfo,
            gitStatus: .clean
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - App Caches and Dev Tools

    /// The sheet closed by its binding (Esc) used to keep the override, so the
    /// next Clean Selected could list the one row instead of the ticked ones.
    @Test func cleanSelectedNeverListsTheRowCommandDeleteOpened() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let picked = cacheRow(try cacheFolder(home, "com.purgetest.picked"))
        let ticked = cacheRow(try cacheFolder(home, "com.purgetest.ticked"))
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.cacheItems = [picked, ticked]
        store.setCacheSelected(id: ticked.id, isSelected: true)

        #expect(store.presentKeyboardDeletionSheet(.cache(id: picked.id)))
        #expect(store.showDeletionSheet)
        #expect(store.deletionCandidatesForSheet.map(\.path) == [picked.path])

        // Closed the way Esc closes it: through the binding, not Cancel.
        store.showDeletionSheet = false
        #expect(store.deletionSheetCandidates == nil)

        store.presentSelectedDeletionSheet()
        #expect(store.deletionCandidatesForSheet.map(\.path) == [ticked.path])
    }

    /// Only the one row reaches the Trash, and the user's other ticks stay;
    /// Clean Selected would have cleared them all. The gate reads the real home,
    /// so both rows are folders under `~/Library/Caches` that are never made, as
    /// in `FileDeleterCacheRouteTests`, and the fake Trash moves nothing.
    @Test func aOneRowCleanKeepsTheOtherTicks() async throws {
        let caches = URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
            .appendingPathComponent("Library/Caches", isDirectory: true)
        let picked = cacheRow(caches.appendingPathComponent("com.purge.test.picked-\(UUID().uuidString)", isDirectory: true))
        let ticked = cacheRow(caches.appendingPathComponent("com.purge.test.ticked-\(UUID().uuidString)", isDirectory: true))
        let scans = FakeScans()
        scans.hasAccess = true
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = scans.makeStore(fileDeleter: FileDeleter(trash: trash.trash))
        store.cacheItems = [picked, ticked]
        store.setCacheSelected(id: ticked.id, isSelected: true)

        #expect(store.presentKeyboardDeletionSheet(.cache(id: picked.id)))
        store.userConfirmedDeletionFromPrimarySheet()
        await waitUntil { store.lastDeletionReport != nil && !store.isDeleting }

        #expect(trash.trashedPaths == [picked.path.standardizedFileURL.path])
        #expect(store.cacheItems.map(\.id) == [ticked.id])
        #expect(store.scanSelection.cacheIDs == [ticked.id])
    }

    @Test func rowsThatCantGoToTheTrashAreRefused() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let missingTool = DevTool(
            definitionKey: "npm",
            toolName: "npm",
            paths: [home.appendingPathComponent(".npm/_cacache")],
            sizeBytes: 0,
            isDetected: false,
            safetyInfo: Self.safeInfo
        )
        store.devTools = [missingTool]

        // A tool this Mac doesn't have, and rows no longer listed.
        #expect(!store.presentKeyboardDeletionSheet(.devTool(id: missingTool.id)))
        #expect(!store.presentKeyboardDeletionSheet(.cache(id: "/nowhere")))
        #expect(!store.presentKeyboardDeletionSheet(.artifact(id: "/nowhere")))
        #expect(!store.showDeletionSheet)
    }

    @Test func nothingOpensWhileACleanRuns() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let row = cacheRow(try cacheFolder(home, "com.purgetest.busy"))
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.cacheItems = [row]
        store.isDeleting = true

        #expect(!store.presentKeyboardDeletionSheet(.cache(id: row.id)))
        #expect(!store.showDeletionSheet)
    }

    // MARK: - Large Files

    private func largeFile(_ url: URL, trashable: Bool = true) throws -> LargeFile {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        return LargeFile(
            path: url, sizeBytes: 4096, lastUsed: Date(timeIntervalSince1970: 0), category: .other,
            syncsWithICloud: !trashable, canMoveToTrash: trashable, canRemoveDownload: !trashable
        )
    }

    @Test func aLargeFileGoesAloneAndTheTickedOnesStay() async throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let picked = try largeFile(downloads.appendingPathComponent("picked.bin"))
        let ticked = try largeFile(downloads.appendingPathComponent("ticked.bin"))
        let scans = FakeScans()
        scans.hasAccess = true
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = scans.makeStore(fileDeleter: FileDeleter(home: home, trash: trash.trash))
        store.largeFiles = [picked, ticked]
        store.setLargeFileSelected(id: ticked.id, isSelected: true)

        #expect(store.presentLargeFileDeletionSheet(for: picked))
        #expect(store.largeFileDeletionSheetFiles.map(\.id) == [picked.id])
        await store.confirmLargeFileDeletion()

        #expect(trash.trashedPaths == [picked.path.standardizedFileURL.path])
        #expect(store.largeFiles.map(\.id) == [ticked.id])
        #expect(store.largeFileSelection.ids == [ticked.id])
    }

    @Test func closingTheLargeFilesSheetDropsTheOneFile() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let picked = try largeFile(downloads.appendingPathComponent("picked.bin"))
        let ticked = try largeFile(downloads.appendingPathComponent("ticked.bin"))
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.largeFiles = [picked, ticked]
        store.setLargeFileSelected(id: ticked.id, isSelected: true)

        #expect(store.presentLargeFileDeletionSheet(for: picked))
        store.showLargeFileDeletionSheet = false
        #expect(store.largeFileDeletionOverride == nil)

        store.presentLargeFileDeletionSheet()
        #expect(store.largeFileDeletionSheetFiles.map(\.id) == [ticked.id])
    }

    /// A file in iCloud Drive's own folder is offered for Keep Only in iCloud,
    /// never for the Trash, which would remove it from every device.
    @Test func anICloudDriveFileIsRefused() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let drive = try largeFile(
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/drive.bin"),
            trashable: false
        )
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.largeFiles = [drive]

        #expect(!store.presentLargeFileDeletionSheet(for: drive))
        #expect(!store.showLargeFileDeletionSheet)
    }

    @Test func aFileNoLongerListedIsRefused() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let gone = try largeFile(home.appendingPathComponent("Downloads/gone.bin"))
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        #expect(!store.presentLargeFileDeletionSheet(for: gone))
    }

    // MARK: - Uninstaller

    private func app(_ name: String, cask: Bool = false) -> InstalledApp {
        var app = InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: "/nonexistent-purge-96/\(name).app", isDirectory: true),
            bundleID: "com.purgetest.\(name.lowercased())",
            bundleSizeBytes: 1,
            isRunning: false
        )
        if cask {
            app.homebrewCask = HomebrewCask(token: name.lowercased(), prefix: URL(fileURLWithPath: "/opt/homebrew"))
        }
        return app
    }

    /// Homebrew's uninstall is permanent and is the review's default for a cask
    /// app, so ⌘⌫ never opens it. Nothing is scanned for a refused app.
    @Test func aHomebrewAppIsRefused() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let cask = app("Caskapp", cask: true)
        store.installedApps = [cask]

        #expect(store.requestUninstall(appID: cask.id) == nil)
        #expect(store.requestUninstall(appID: "not-listed") == nil)
        #expect(!store.isBuildingUninstallPlan)
        #expect(store.uninstallPlan == nil)
    }

    @Test func oneLeftoverOpensItsReviewAlone() {
        let folder = fm.temporaryDirectory.appendingPathComponent("purge-96-\(UUID().uuidString)", isDirectory: true)
        func leftover(_ name: String) -> UninstallItem {
            UninstallItem(
                path: folder.appendingPathComponent(name, isDirectory: true),
                sizeBytes: 1,
                category: .caches,
                safetyInfo: Self.safeInfo,
                matchReason: .bundleID,
                isSelected: false
            )
        }
        let picked = leftover("picked")
        let ticked = leftover("ticked")
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.orphanLeftovers = [picked, ticked]
        store.toggleOrphanSelected(id: ticked.id)

        #expect(store.requestOrphanCleanup(forLeftoverID: picked.id))
        #expect(store.orphanCleanupPlan?.items.map(\.id) == [picked.id])
        #expect(store.orphanCleanupPlan?.items.allSatisfy(\.isSelected) == true)
        #expect(store.orphanSelectedIDs == [ticked.id])

        store.cancelOrphanCleanup()
        #expect(!store.requestOrphanCleanup(forLeftoverID: "not-listed"))
    }

    /// A tool a package manager owns is removed permanently by that manager, so
    /// ⌘⌫ refuses it. A tool a script installed opens its review alone.
    @Test func onlyScriptInstalledToolsOpenTheirReview() throws {
        let folder = try makeHome()
        defer { try? fm.removeItem(at: folder) }
        let standalone = StandaloneCommandLineTool(
            install: CommandLineToolInstall(name: "tool", folder: folder, shims: [], launchAgents: [], kept: [], source: .shim),
            sizeBytes: 4_000,
            settingsFiles: []
        )
        let managed = PackageManagerTool(
            manager: .homebrew, name: "jq", locations: [folder], context: nil,
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: ["uninstall", "--formula", "jq"], environment: [:],
            sizeBytes: 1_000
        )
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.commandLineTools = CommandLineToolScanResult(standalone: [standalone], managed: [managed])
        store.toggleCommandLineToolSelected(id: managed.id)

        #expect(!store.requestCommandLineToolRemoval(forToolID: managed.id))
        #expect(store.commandLineToolRemovalPlan == nil)

        #expect(store.requestCommandLineToolRemoval(forToolID: standalone.id))
        #expect(store.commandLineToolRemovalPlan?.tools.map(\.id) == [standalone.id])
        #expect(store.commandLineToolRemovalPlan?.managed.isEmpty == true)
    }
}
