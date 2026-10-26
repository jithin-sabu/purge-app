import Foundation
import Testing
@testable import Purge

/// The Overview's Large Files row follows the tab's size and last-used filters,
/// so its line names both, and a saved figure counts only while the filters it
/// was taken under still match (#279).
@MainActor
@Suite("The Overview Large Files row names its filters")
struct OverviewLargeFilesRowTests {

    // MARK: The line

    @Test
    func theLineNamesOnlyTheSizeWhenLastUsedIsAnyTime() {
        let filter = LargeFileFilterSnapshot(size: .mb100, age: .anyTime)
        #expect(OverviewLargeFilesLine.text(count: 12, filter: filter) == "12 files over 100 MB")
        #expect(OverviewLargeFilesLine.text(count: 1, filter: filter) == "1 file over 100 MB")
    }

    @Test
    func theLineNamesBothFiltersWhenLastUsedIsSet() {
        #expect(
            OverviewLargeFilesLine.text(count: 12, filter: LargeFileFilterSnapshot(size: .gb1, age: .year1))
                == "12 files over 1 GB not used in a year"
        )
        #expect(
            OverviewLargeFilesLine.text(count: 1, filter: LargeFileFilterSnapshot(size: .mb250, age: .months3))
                == "1 file over 250 MB not used in 3 months"
        )
    }

    /// A zero says what was looked for, so a Mac full of 1 GB files does not
    /// read as having none.
    @Test
    func aZeroSaysWhatWasLookedFor() {
        #expect(
            OverviewLargeFilesLine.text(count: 0, filter: LargeFileFilterSnapshot(size: .gb1, age: .year1))
                == "No files over 1 GB not used in a year"
        )
        #expect(
            OverviewLargeFilesLine.text(count: 0, filter: LargeFileFilterSnapshot(size: .gb1, age: .anyTime))
                == "No files over 1 GB"
        )
    }

    @Test
    func everyLastUsedOptionHasASpanExceptAnyTime() {
        #expect(LargeFileAgeThreshold.anyTime.rowSpan == nil)
        #expect(LargeFileAgeThreshold.oneMonth.rowSpan == "a month")
        #expect(LargeFileAgeThreshold.months3.rowSpan == "3 months")
        #expect(LargeFileAgeThreshold.months6.rowSpan == "6 months")
        #expect(LargeFileAgeThreshold.year1.rowSpan == "a year")
    }

    // MARK: The record

    @Test
    func aFinishedScanRecordsTheFiltersItRanUnder() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.defaults.set(LargeFileSizeThreshold.gb1.rawValue, forKey: LargeFileSizeThreshold.userDefaultsKey)
        fake.defaults.set(LargeFileAgeThreshold.year1.rawValue, forKey: LargeFileAgeThreshold.userDefaultsKey)
        fake.largeFileEvents = [.file(file("/Users/someone/Movies/wedding.mov", bytes: 4_000_000_000))]
        let store = fake.makeStore()

        await store.scanLargeFiles()

        let expected = LargeFileFilterSnapshot(size: .gb1, age: .year1)
        #expect(store.scanRecords[.largeFiles]?.largeFileFilter == expected)
        #expect(ScanRecordStore(defaults: fake.defaults).record(for: .largeFiles)?.largeFileFilter == expected)
        #expect(store.applicableRecord(for: .largeFiles)?.count == 1)
    }

    @Test
    func aSavedFigureShowsWhileTheFiltersStillMatch() {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.defaults.set(LargeFileSizeThreshold.gb1.rawValue, forKey: LargeFileSizeThreshold.userDefaultsKey)
        fake.defaults.set(LargeFileAgeThreshold.year1.rawValue, forKey: LargeFileAgeThreshold.userDefaultsKey)
        ScanRecordStore(defaults: fake.defaults).save(
            ScanRecord(
                completedAt: .distantPast, bytes: 5_000_000_000, count: 12,
                largeFileFilter: LargeFileFilterSnapshot(size: .gb1, age: .year1)
            ),
            for: .largeFiles
        )
        let store = fake.makeStore()

        #expect(store.overviewPhase(for: .largeFiles) == .notScanned)
        #expect(store.isShowingRecordedFigure(for: .largeFiles))
        #expect(store.applicableRecord(for: .largeFiles)?.count == 12)
        #expect(store.overviewShowsRecordedFigures())
    }

    /// A count taken at 100 MB says nothing about a 1 GB filter. The row treats
    /// the category as not scanned instead of naming the new filter against the
    /// old count.
    @Test
    func aSavedFigureHidesOnceAFilterChanged() {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.defaults.set(LargeFileSizeThreshold.gb1.rawValue, forKey: LargeFileSizeThreshold.userDefaultsKey)
        ScanRecordStore(defaults: fake.defaults).save(
            ScanRecord(
                completedAt: .distantPast, bytes: 70_000_000_000, count: 312,
                largeFileFilter: LargeFileFilterSnapshot(size: .mb100, age: .anyTime)
            ),
            for: .largeFiles
        )
        let store = fake.makeStore()

        #expect(store.overviewPhase(for: .largeFiles) == .notScanned)
        #expect(!store.isShowingRecordedFigure(for: .largeFiles))
        #expect(store.applicableRecord(for: .largeFiles) == nil)
        #expect(!store.overviewShowsRecordedFigures())
        // The record itself is kept: the next full scan replaces it.
        #expect(store.scanRecords[.largeFiles]?.count == 312)
        // The bar counts nothing for it either, where the old figure would have filled 70 GB.
        #expect(store.overviewBreakdown(totalBytes: 500_000_000_000, freeBytes: 100_000_000_000).bytes(for: .largeFiles) == 0)
    }

    /// Records saved before the filters were stored carry none. They are shown
    /// as they were, and the next scan writes the filters in.
    @Test
    func aRecordSavedWithoutFiltersStillShows() {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.defaults.set(LargeFileSizeThreshold.gb1.rawValue, forKey: LargeFileSizeThreshold.userDefaultsKey)
        ScanRecordStore(defaults: fake.defaults).save(
            ScanRecord(completedAt: .distantPast, bytes: 5_000_000_000, count: 12),
            for: .largeFiles
        )
        let store = fake.makeStore()

        #expect(store.isShowingRecordedFigure(for: .largeFiles))
        #expect(store.applicableRecord(for: .largeFiles)?.count == 12)
    }

    /// The tab rescans on every filter change, but should a filter ever change
    /// without one, this session's rows are not results for the new filter: the
    /// row shows no figure, and opening the tab scans again.
    @Test
    func liveResultsHideOnceAFilterChangedWithoutARescan() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.largeFileEvents = [.file(file("/Users/someone/Movies/wedding.mov", bytes: 4_000_000_000))]
        let store = fake.makeStore()

        await store.scanLargeFiles()
        #expect(store.overviewPhase(for: .largeFiles) == .ready)
        #expect(store.hasSessionResults(for: .largeFiles))

        fake.defaults.set(LargeFileSizeThreshold.gb1.rawValue, forKey: LargeFileSizeThreshold.userDefaultsKey)

        #expect(!store.hasSessionResults(for: .largeFiles))
        #expect(store.overviewPhase(for: .largeFiles) == .notScanned)
        // The record was counted under the old filter too, so no saved figure either.
        #expect(!store.isShowingRecordedFigure(for: .largeFiles))
        #expect(store.overviewBreakdown(totalBytes: 500_000_000_000, freeBytes: 100_000_000_000).bytes(for: .largeFiles) == 0)

        // A scan under the new filter is this session's result again.
        await store.scanLargeFiles()
        #expect(fake.largeFileScanCount == 2)
        #expect(store.overviewPhase(for: .largeFiles) == .ready)
        #expect(store.scanRecords[.largeFiles]?.largeFileFilter == LargeFileFilterSnapshot(size: .gb1, age: .anyTime))
    }

    /// Only Large Files carries filters. Another category's record is untouched
    /// by the Large Files filter changing.
    @Test
    func otherCategoriesIgnoreTheLargeFilesFilter() {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.defaults.set(LargeFileSizeThreshold.gb1.rawValue, forKey: LargeFileSizeThreshold.userDefaultsKey)
        ScanRecordStore(defaults: fake.defaults).save(
            ScanRecord(completedAt: .distantPast, bytes: 2_000_000_000, count: 12),
            for: .leftovers
        )
        let store = fake.makeStore()

        #expect(store.isShowingRecordedFigure(for: .leftovers))
        #expect(store.scanRecords[.leftovers]?.largeFileFilter == nil)
    }

    /// Records saved before this change decode with no filter rather than failing.
    @Test
    func anOldRecordDecodesWithNoFilter() throws {
        let data = Data(#"{"completedAt":0,"bytes":5000000000,"count":12}"#.utf8)
        let record = try JSONDecoder().decode(ScanRecord.self, from: data)
        #expect(record.count == 12)
        #expect(record.largeFileFilter == nil)
    }

    /// A video row at `path`. Nothing exists at the path, so nothing could ever move.
    private func file(_ path: String, bytes: Int64) -> LargeFile {
        LargeFile(path: URL(fileURLWithPath: path), sizeBytes: bytes, lastUsed: Date(), category: .video)
    }
}
