import Foundation
import Testing
@testable import Purge

/// The App Caches scan publishes its rows in flushes. Flushes during the scan
/// run the safety filter over the rows they add; the scan's last flush, which
/// a stopped scan runs too, runs it over every row. These pin that a row the
/// policy refuses when it arrives is never on the list, and that the list a
/// scan leaves behind has passed the filter.
///
/// Every row is a folder under `~/Library/Caches` that is never made (#171).
@MainActor
@Suite("Cache scan flushes filter every row they publish")
struct CacheScanFlushFilterTests {
    private static func row(folder: String, key: String? = nil, level: SafetyLevel = .safe) -> CacheItem {
        CacheItem(
            definitionKey: key ?? folder,
            location: CacheLocation(
                path: URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
                    .appendingPathComponent("Library/Caches/\(folder)", isDirectory: true),
                sizeBytes: 0,
                lastModified: .distantPast,
                folderName: folder
            ),
            appName: folder,
            safetyInfo: SafetyInfo(level: level, headline: folder, explanation: "", recoverySteps: "", reinstallCommand: nil),
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

    /// A row keeps the level it was published with while the scan runs, so it
    /// doesn't jump between sections. A folder that joins it later at Check
    /// First still makes it Check First, or Clean Safe Items and scheduled
    /// cleans would move that folder with the Safe ones (#378).
    @Test func aLaterCheckFirstFolderMakesAPublishedSafeRowCheckFirst() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.hasAccess = true
        let key = "com.purge.test.flush-pin-\(UUID().uuidString)"
        let safe = Self.row(folder: "\(key).safe", key: key, level: .safe)
        let checkFirst = Self.row(folder: "\(key).check-first", key: key, level: .medium)
        try #require(DeletionSafetyPolicy.isOfferedForCleanup(safe.path))
        try #require(DeletionSafetyPolicy.isOfferedForCleanup(checkFirst.path))
        scans.generalEvents = Self.events(for: [safe])
        scans.holdsGeneral = true
        let store = scans.makeStore()
        func row() -> CacheItem? { store.cacheItems.first { $0.definitionKey == key } }
        func offeredForSafeClean(_ item: CacheItem) -> Set<String> {
            let paths = Set(item.locations.map { $0.path.standardizedFileURL.path })
            return Set(store.manualSafeCleanupCandidates().map { $0.path.standardizedFileURL.path }).intersection(paths)
        }

        store.requestScan(.cachesAndDevTools)
        #expect(await eventually { row()?.safetyInfo.level == .safe })
        let published = try #require(row())
        #expect(!offeredForSafeClean(published).isEmpty)

        // The Check First folder arrives after the Safe row went out.
        scans.yieldGeneral(Self.events(for: [checkFirst]))
        #expect(await eventually { row()?.locations.count == 2 })
        let joined = try #require(row())
        #expect(joined.safetyInfo.level == .medium)
        #expect(offeredForSafeClean(joined).isEmpty)

        scans.finishHeldGeneral()
        #expect(await eventually { !store.isScanningGeneral })
        let finished = try #require(row())
        #expect(finished.safetyInfo.level == .medium)
        #expect(offeredForSafeClean(finished).isEmpty)
    }

    /// The other way round the pin holds: a row published as Check First
    /// stays Check First when a Safe folder joins it.
    @Test func aLaterSafeFolderLeavesAPublishedCheckFirstRowCheckFirst() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.hasAccess = true
        let key = "com.purge.test.flush-pin-\(UUID().uuidString)"
        let checkFirst = Self.row(folder: "\(key).check-first", key: key, level: .medium)
        let safe = Self.row(folder: "\(key).safe", key: key, level: .safe)
        scans.generalEvents = Self.events(for: [checkFirst])
        scans.holdsGeneral = true
        let store = scans.makeStore()
        func row() -> CacheItem? { store.cacheItems.first { $0.definitionKey == key } }

        store.requestScan(.cachesAndDevTools)
        #expect(await eventually { row()?.safetyInfo.level == .medium })

        scans.yieldGeneral(Self.events(for: [safe]))
        #expect(await eventually { row()?.locations.count == 2 })
        #expect(row()?.safetyInfo.level == .medium)

        scans.finishHeldGeneral()
        #expect(await eventually { !store.isScanningGeneral })
        #expect(row()?.safetyInfo.level == .medium)
    }
}
