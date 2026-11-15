import Foundation
import Testing
@testable import Purge

/// The App Caches scan publishes its rows in flushes. Flushes during the scan
/// run the safety filter only over the rows they add; the scan's last flush
/// runs it over every row. These pin that a row the policy refuses is never on
/// the list, during the scan or after it.
///
/// Every row is a folder under `~/Library/Caches` that is never made (#171).
@MainActor
@Suite("Cache scan flushes filter every row they publish")
struct CacheScanFlushFilterTests {
    private static func row(folder: String) -> CacheItem {
        CacheItem(
            definitionKey: folder,
            location: CacheLocation(
                path: URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
                    .appendingPathComponent("Library/Caches/\(folder)", isDirectory: true),
                sizeBytes: 0,
                lastModified: .distantPast,
                folderName: folder
            ),
            appName: folder,
            safetyInfo: SafetyInfo(level: .safe, headline: folder, explanation: "", recoverySteps: "", reinstallCommand: nil),
            gitStatus: .clean
        )
    }

    private static func events(for rows: [CacheItem]) -> [CacheScanEvent] {
        rows.map { CacheScanEvent.found($0) } + rows.map {
            .sizeResolved(path: $0.path.standardizedFileURL.path, sizeBytes: 1_000_000, lastModified: .distantPast)
        }
    }

    @Test func aRefusedRowIsNeverPublished() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.hasAccess = true
        let offered = Self.row(folder: "com.purge.test.flush-filter-\(UUID().uuidString)")
        // Account daemon caches are never offered, whatever their row says.
        let refused = Self.row(folder: "com.apple.akd")
        try #require(DeletionSafetyPolicy.isOfferedForCleanup(offered.path))
        try #require(!DeletionSafetyPolicy.isOfferedForCleanup(refused.path))
        scans.generalEvents = Self.events(for: [offered, refused])
        scans.holdsGeneral = true
        let store = scans.makeStore()
        let refusedPath = refused.path.standardizedFileURL.path
        func lists(_ path: String) -> Bool {
            store.cacheItems.contains { item in item.locations.contains { $0.path.standardizedFileURL.path == path } }
        }

        store.requestScan(.cachesAndDevTools)
        // Held open: the rows land through the flushes made during the scan.
        #expect(await eventually { lists(offered.path.standardizedFileURL.path) })
        #expect(!lists(refusedPath))

        scans.finishHeldGeneral()
        #expect(await eventually { !store.isScanningGeneral })
        #expect(lists(offered.path.standardizedFileURL.path))
        #expect(!lists(refusedPath))
    }
}
