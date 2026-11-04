import Combine
import Foundation
import Testing
@testable import Purge

/// What the menu shows after its clean, and what the notification's Clean action
/// does (#183). The menu said "You're all clear" after every clean, even one that
/// failed or left safe rows behind, and the action could do nothing at all.
///
/// Every row is a folder under `~/Library/Caches` that is never made, and the
/// store cleans through a fake Trash that moves nothing (#171).
@MainActor
@Suite("The menu's clean outcome")
struct MenuCleanOutcomeTests {
    private static func row() -> CacheItem {
        let folder = "com.purge.test.menu-clean-\(UUID().uuidString)"
        return CacheItem(
            definitionKey: folder,
            location: CacheLocation(
                path: URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
                    .appendingPathComponent("Library/Caches/\(folder)", isDirectory: true),
                sizeBytes: 1_000_000,
                lastModified: .distantPast,
                folderName: folder
            ),
            appName: folder,
            safetyInfo: SafetyInfo(level: .safe, headline: folder, explanation: "", recoverySteps: "", reinstallCommand: nil),
            gitStatus: .clean
        )
    }

    /// A menu whose launch scan has settled, showing `rows` as ready to clean.
    private func readyMenu(_ scans: FakeScans, trash: FakeTrash, rows: [CacheItem]) async throws -> (PurgeStore, MenuViewModel) {
        scans.hasAccess = true
        let store = scans.makeStore(fileDeleter: FileDeleter(trash: trash.trash))
        let model = MenuViewModel()
        model.attach(store: store)
        // Every part of the launch scan has settled, its enrichment and the
        // menu's debounced look at it included, so nothing rewrites the rows
        // set below.
        try #require(await eventually {
            model.state != .checking && !store.isScanningAll && !store.scanQueue.isRunning
                && !store.isScanningProjects && !store.isEnrichingGeneral && !store.isEnrichingDeveloper
        })
        try? await Task.sleep(for: .milliseconds(400))
        store.cacheItems = rows
        model.menuDidOpen()
        try #require(isReady(model.state, bytes: Int64(rows.count) * 1_000_000))
        return (store, model)
    }

    private func isReady(_ state: MenuState, bytes: Int64) -> Bool {
        if case .ready(bytes, _) = state { return true }
        return false
    }

    @Test func aCleanThatMovedNothingGoesBackToReady() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let (store, model) = try await readyMenu(scans, trash: trash, rows: [Self.row()])
        // The model holds the store weakly, as the app does.
        defer { withExtendedLifetime(store) {} }
        var states: [MenuState] = []
        let watch = model.$state.sink { states.append($0) }
        defer { watch.cancel() }

        #expect(model.clean())

        #expect(await eventually { !store.isDeleting && isReady(model.state, bytes: 1_000_000) })
        #expect(!states.contains { if case .cleaned = $0 { return true }; return false })
        #expect(!states.contains { if case .clear = $0 { return true }; return false })
    }

    @Test func safeBytesLeftAfterACleanShowAsReady() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let (store, model) = try await readyMenu(scans, trash: trash, rows: [Self.row(), Self.row()])
        // The model holds the store weakly, as the app does.
        defer { withExtendedLifetime(store) {} }
        var states: [MenuState] = []
        let watch = model.$state.sink { states.append($0) }
        defer { watch.cancel() }
        #expect(model.clean())

        #expect(await eventually { states.contains(.cleaned(bytes: 1_000_000)) })
        #expect(await eventually { isReady(model.state, bytes: 1_000_000) })
        #expect(!states.contains { if case .clear = $0 { return true }; return false })
    }

    @Test func aCleanThatTookEverythingIsAllClear() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let (store, model) = try await readyMenu(scans, trash: trash, rows: [Self.row()])
        // The model holds the store weakly, as the app does.
        defer { withExtendedLifetime(store) {} }

        #expect(model.clean())

        #expect(await eventually { model.state == .cleaned(bytes: 1_000_000) })
        #expect(await eventually { if case .clear = model.state { return true }; return false })
    }

    /// The action can wake Purge mid-scan. It used to return with nothing done.
    @Test func theNotificationCleanWaitsForARunningScan() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.hasAccess = true
        scans.holdsGeneral = true
        let row = Self.row()
        scans.generalEvents = [.found(row)]
        let trash = FakeTrash()
        let store = scans.makeStore(fileDeleter: FileDeleter(trash: trash.trash))
        let model = MenuViewModel()
        model.attach(store: store)
        try #require(await eventually { scans.generalAccesses.count == 1 })
        #expect(model.state == .checking)

        model.performCleanFromNotification()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(trash.trashedPaths.isEmpty)

        scans.finishHeldGeneral()

        #expect(await eventually { trash.trashedPaths == [row.path.standardizedFileURL.path] })
        #expect(await eventually { !model.cleanFromNotification })
    }

    /// A windowless launch runs no scan. A tap then must not wait for whichever
    /// scan comes next and start a clean long after it.
    @Test func aNotificationCleanWithNoScanRunningDoesNotWaitForTheNextOne() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.hasAccess = true
        let row = Self.row()
        scans.generalEvents = [
            .found(row),
            .sizeResolved(path: row.path.standardizedFileURL.path, sizeBytes: 1_000_000, lastModified: .distantPast),
        ]
        let trash = FakeTrash()
        let store = scans.makeStore(fileDeleter: FileDeleter(trash: trash.trash))
        let model = MenuViewModel()
        model.attach(store: store, scansAtLaunch: false)
        try? await Task.sleep(for: .milliseconds(300))
        try #require(model.state == .checking)

        model.performCleanFromNotification()
        // Held past the menu's 200 ms debounce, so it sees the scan run.
        scans.holdsGeneral = true
        store.requestScan(.cachesAndDevTools)
        #expect(await eventually { scans.generalAccesses.count == 1 })
        try? await Task.sleep(for: .milliseconds(400))
        scans.finishHeldGeneral()

        #expect(await eventually { isReady(model.state, bytes: 1_000_000) })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(trash.trashedPaths.isEmpty)
    }

    /// Two banners can be up at once. A tap on the second while the first one's
    /// clean runs used to clear the flag, and the clean then posted no banner.
    @Test func aSecondTapDuringACleanKeepsTheFirstTapsBanner() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let (store, model) = try await readyMenu(scans, trash: trash, rows: [Self.row()])
        // The model holds the store weakly, as the app does.
        defer { withExtendedLifetime(store) {} }

        model.performCleanFromNotification()
        try #require(model.cleanFromNotification)
        model.performCleanFromNotification()

        #expect(model.cleanFromNotification)
    }

    /// A row the clean refuses on the spot is still in the sidebar total. The
    /// menu used to stay on Ready beside a Clean that did nothing.
    @Test func aRowTheCleanRefusesDoesNotKeepTheMenuOnReady() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        // Account daemon caches are never offered, whatever their row says.
        let refused = CacheItem(
            definitionKey: "com.apple.akd",
            location: CacheLocation(
                path: URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
                    .appendingPathComponent("Library/Caches/com.apple.akd", isDirectory: true),
                sizeBytes: 1_000_000,
                lastModified: .distantPast,
                folderName: "com.apple.akd"
            ),
            appName: "akd",
            safetyInfo: SafetyInfo(level: .safe, headline: "akd", explanation: "", recoverySteps: "", reinstallCommand: nil),
            gitStatus: .clean
        )
        let (store, model) = try await readyMenu(scans, trash: trash, rows: [refused])
        // The model holds the store weakly, as the app does.
        defer { withExtendedLifetime(store) {} }

        #expect(!model.clean())

        #expect({ if case .clear = model.state { return true }; return false }())
        #expect(trash.trashedPaths.isEmpty)
    }

    /// With nothing to clean, the action used to leave its flag set, so a later
    /// clean from the panel posted a notification nobody asked for.
    @Test func aNotificationCleanWithNothingToCleanLeavesNoFlag() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.hasAccess = true
        let trash = FakeTrash()
        let store = scans.makeStore(fileDeleter: FileDeleter(trash: trash.trash))
        let model = MenuViewModel()
        model.attach(store: store)
        try #require(await eventually { if case .clear = model.state { return true }; return false })

        model.performCleanFromNotification()

        #expect(!model.cleanFromNotification)
        #expect(trash.trashedPaths.isEmpty)
    }
}
