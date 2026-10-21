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
}
