import Foundation
import Testing
@testable import Purge

/// Large Files used to keep the picked category chip across launches and scans.
/// When that category had no rows its chip was not drawn, yet the list still
/// filtered on it: an empty list with no chip lit, which read as "no large
/// files on this Mac" (#277). Now every launch and every scan starts on All,
/// and a chip with no rows falls back to All.
@MainActor
@Suite("Large Files starts on All and never filters on a hidden chip")
struct LargeFileChipFallbackTests {
    private let suite = ThrowawayDefaults()

    private func row(_ path: String, _ category: LargeFileCategory, bytes: Int64 = 500_000_000) -> LargeFile {
        LargeFile(path: URL(fileURLWithPath: path), sizeBytes: bytes, lastUsed: Date(), category: category)
    }

    private var rows: [LargeFile] {
        [
            row("/Users/someone/Documents/taxes.pdf", .pdf),
            row("/Users/someone/Movies/wedding.mov", .video),
        ]
    }

    // MARK: - The shared filter

    /// The reported case: Images picked, then a rescan finds no images.
    @Test
    func aChipWithNoRowsShowsEverything() {
        let image = LargeFileCategory.image.rawValue
        #expect(LargeFileCategoryFilter.activeRawValue(rawValue: image, files: rows, duplicates: .empty)
            == LargeFileCategoryFilter.all)
        #expect(LargeFileCategoryFilter.visibleIndices(
            in: rows, rawValue: image, query: "", duplicates: .empty
        ) == [0, 1])
    }

    @Test
    func aChipWithRowsStillFilters() {
        let video = LargeFileCategory.video.rawValue
        #expect(LargeFileCategoryFilter.activeRawValue(rawValue: video, files: rows, duplicates: .empty) == video)
        #expect(LargeFileCategoryFilter.visibleIndices(
            in: rows, rawValue: video, query: "", duplicates: .empty
        ) == [1])
    }

    /// A query that hides every row under a drawn chip is not a fallback case:
    /// the chip is still there, and the empty list names the query.
    @Test
    func aQueryDoesNotMoveTheChip() {
        let video = LargeFileCategoryFilter.visibleIndices(
            in: rows, rawValue: LargeFileCategory.video.rawValue, query: "taxes", duplicates: .empty
        )
        #expect(video.isEmpty)
    }

    /// A value no chip uses, such as one an older or newer version wrote.
    @Test
    func anUnknownValueShowsEverything() {
        #expect(LargeFileCategoryFilter.activeRawValue(rawValue: "spreadsheets", files: rows, duplicates: .empty)
            == LargeFileCategoryFilter.all)
        #expect(LargeFileCategoryFilter.visibleIndices(
            in: rows, rawValue: "spreadsheets", query: "", duplicates: .empty
        ) == [0, 1])
    }

    @Test
    func theDuplicatesAndICloudChipsFallBackWhenEmpty() {
        #expect(LargeFileCategoryFilter.activeRawValue(
            rawValue: LargeFileCategoryFilter.duplicates, files: rows, duplicates: .empty
        ) == LargeFileCategoryFilter.all)
        #expect(LargeFileCategoryFilter.activeRawValue(
            rawValue: LargeFileCategoryFilter.iCloud, files: rows, duplicates: .empty
        ) == LargeFileCategoryFilter.all)

        let copies = [
            row("/Users/someone/Movies/a.mov", .video),
            row("/Users/someone/Movies/b.mov", .video),
        ]
        let index = DuplicateIndex(groups: [
            DuplicateGroup(id: "digest", fileIDs: copies.map(\.id), sizeBytes: 500_000_000),
        ])
        #expect(LargeFileCategoryFilter.activeRawValue(
            rawValue: LargeFileCategoryFilter.duplicates, files: copies, duplicates: index
        ) == LargeFileCategoryFilter.duplicates)
    }

    // MARK: - Launch

    /// `register()` runs at every launch, the test host's too, so it must leave
    /// the old value alone; the app removes it only outside the test host.
    @Test
    func launchDropsTheChipAnOlderVersionSaved() {
        suite.defaults.set(LargeFileCategory.image.rawValue, forKey: LargeFileFilterDefaults.legacyCategoryKey)
        LargeFileFilterDefaults.register(userDefaults: suite.defaults)
        #expect(suite.defaults.string(forKey: LargeFileFilterDefaults.legacyCategoryKey)
            == LargeFileCategory.image.rawValue)

        LargeFileFilterDefaults.removeLegacyCategory(userDefaults: suite.defaults)
        #expect(suite.defaults.object(forKey: LargeFileFilterDefaults.legacyCategoryKey) == nil)
    }

    @Test
    func aNewStoreStartsOnAll() {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.defaults.set(LargeFileCategory.image.rawValue, forKey: LargeFileFilterDefaults.legacyCategoryKey)
        let store = fake.makeStore()
        #expect(store.largeFileCategoryFilter == LargeFileCategoryFilter.all)
    }

    // MARK: - Scans

    /// Every scan opens on All, including the ones the size and last-used menus
    /// start. The reset happens as the old rows are cleared, before any new row
    /// arrives.
    @Test
    func aScanStartsOnAll() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.largeFileEvents = rows.map { .file($0) }
        let store = fake.makeStore()

        await store.scanLargeFiles()
        store.largeFileCategoryFilter = LargeFileCategory.image.rawValue

        fake.holdsLargeFiles = true
        let rescan = Task { await store.scanLargeFiles() }
        #expect(await eventually { fake.largeFileScanCount == 2 })
        #expect(store.largeFileCategoryFilter == LargeFileCategoryFilter.all)

        fake.finishHeldLargeFiles()
        await rescan.value
        #expect(store.largeFileCategoryFilter == LargeFileCategoryFilter.all)
        #expect(store.largeFiles.count == 2)
    }

    /// Trashing the last row under the picked chip takes the chip away; the
    /// list shows everything left instead of nothing.
    @Test
    func trashingTheLastRowUnderTheChipShowsEverythingLeft() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.largeFileEvents = rows.map { .file($0) }
        let store = fake.makeStore()
        await store.scanLargeFiles()

        let pdf = LargeFileCategory.pdf.rawValue
        store.largeFileCategoryFilter = pdf
        #expect(LargeFileCategoryFilter.visibleIndices(
            in: store.largeFiles, rawValue: pdf, query: "", duplicates: .empty
        ).map { store.largeFiles[$0].category } == [.pdf])

        store.removeClearedLargeFileRows(store.largeFiles.filter { $0.category == .pdf })

        #expect(LargeFileCategoryFilter.activeRawValue(
            rawValue: store.largeFileCategoryFilter, files: store.largeFiles, duplicates: .empty
        ) == LargeFileCategoryFilter.all)
        #expect(LargeFileCategoryFilter.visibleIndices(
            in: store.largeFiles, rawValue: store.largeFileCategoryFilter, query: "", duplicates: .empty
        ).map { store.largeFiles[$0].category } == [.video])
    }

    /// Waits for the store to settle. The deadline only stops a hang; it counts
    /// only the time this loop was running, as `ScanQueueStoreTests` does.
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
