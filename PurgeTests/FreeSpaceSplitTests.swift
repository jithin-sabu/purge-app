import Foundation
import Testing
@testable import Purge

/// The Overview's free figure includes purgeable space, so on its own it read
/// 508.2 GB where System Settings said 310.4 GB. The split names both.
@Suite("Free space shows empty and purgeable space apart")
struct FreeSpaceSplitTests {
    @Test func splitsPurgeableSpaceOut() throws {
        let split = try #require(FreeSpaceSplit(availableBytes: 508_200_934_638, freeNowBytes: 310_416_699_392))
        #expect(split.freeNowBytes == 310_416_699_392)
        #expect(split.purgeableBytes == 197_784_235_246)
    }

    @Test func showsOneFigureWhenLittleIsPurgeable() {
        #expect(FreeSpaceSplit(availableBytes: 100_500_000_000, freeNowBytes: 100_000_000_000) == nil)
    }

    @Test func showsOneFigureWithoutAnEmptySpaceReading() {
        #expect(FreeSpaceSplit(availableBytes: 508_200_934_638, freeNowBytes: nil) == nil)
    }

    /// Two readings taken a moment apart can cross; that is not purgeable space.
    @Test func neverShowsNegativePurgeableSpace() {
        #expect(FreeSpaceSplit(availableBytes: 300_000_000_000, freeNowBytes: 310_000_000_000) == nil)
    }

    // MARK: What the Overview shows (#243)

    private static let gb: Int64 = 1_000_000_000

    /// The readings from the Mac in #243: purgeable space moves from free to used,
    /// and used plus purgeable stays apart from what is empty.
    @Test func overviewCountsPurgeableAsUsedAndShowsTheEmptyFigureAsFree() throws {
        let breakdown = OverviewBreakdown(totalBytes: 994_600_000_000, freeBytes: 504_800_000_000, sources: [:])
        let split = try #require(FreeSpaceSplit(availableBytes: 504_800_000_000, freeNowBytes: 306_800_000_000))
        let shown = OverviewFreeSpace(breakdown: breakdown, split: split)

        #expect(shown.emptyBytes == 306_800_000_000)
        #expect(shown.purgeableBytes == 198_000_000_000)
        #expect(shown.usedBytes == 687_800_000_000)
        #expect(shown.usedBytes + shown.emptyBytes == breakdown.totalBytes)
        // Everything else is still the used space Purge did not sort, without the
        // purgeable part, which has its own segment.
        #expect(breakdown.everythingElseBytes == 489_800_000_000)
    }

    @Test func overviewShowsTodaysFiguresWithoutASplit() {
        let breakdown = OverviewBreakdown(totalBytes: 500 * Self.gb, freeBytes: 180 * Self.gb, sources: [:])
        let shown = OverviewFreeSpace(breakdown: breakdown, split: nil)

        #expect(shown.purgeableBytes == 0)
        #expect(shown.emptyBytes == breakdown.freeBytes)
        #expect(shown.usedBytes == breakdown.usedBytes)
    }

    /// The split comes from the volume and the breakdown caps free at the total, so
    /// a purgeable figure larger than free can't push empty space below zero.
    @Test func overviewNeverShowsMorePurgeableThanFree() throws {
        let breakdown = OverviewBreakdown(totalBytes: 500 * Self.gb, freeBytes: 500 * Self.gb, sources: [:])
        let split = try #require(FreeSpaceSplit(availableBytes: 600 * Self.gb, freeNowBytes: 0))
        let shown = OverviewFreeSpace(breakdown: breakdown, split: split)

        #expect(shown.purgeableBytes == 500 * Self.gb)
        #expect(shown.emptyBytes == 0)
        #expect(shown.usedBytes == 500 * Self.gb)
    }

    @MainActor
    @Test func diskSummaryPublishesTheSplitWithEachRead() {
        let store = DiskSummaryStore(read: {
            VolumeCapacity(totalBytes: 994_600_000_000, availableBytes: 504_800_000_000, freeNowBytes: 306_800_000_000)
        })
        #expect(store.freeDiskBytes == 504_800_000_000)
        #expect(store.freeSpaceSplit?.purgeableBytes == 198_000_000_000)

        let noSplit = DiskSummaryStore(read: {
            VolumeCapacity(totalBytes: 994_600_000_000, availableBytes: 504_800_000_000)
        })
        #expect(noSplit.freeSpaceSplit == nil)
    }
}
