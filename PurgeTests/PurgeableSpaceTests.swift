import Foundation
import Testing
@testable import Purge

/// Purge counts what macOS can clear on its own as free, like System Settings, while
/// Disk Utility counts it as used. These tests pin the figures that let someone line the
/// two up: free space precise enough to match System Settings, and the purgeable gap
/// mentioned only when it is big enough to notice.
@MainActor
@Suite("Purgeable space on the Overview")
struct PurgeableSpaceTests {
    private let gb: Int64 = 1_000_000_000

    @Test func terabytesKeepTwoDecimalsLikeSystemSettings() {
        #expect(formatStorageBytes(1_570_000_000_000) == "1.57 TB")
        #expect(formatStorageBytes(1_574_000_000_000) == "1.57 TB")
        #expect(formatStorageBytes(1_576_000_000_000) == "1.58 TB")
        #expect(formatStorageBytes(1_050_000_000_000) == "1.05 TB")
        #expect(formatStorageBytes(1_500_000_000_000) == "1.5 TB")
        #expect(formatStorageBytes(2_000_000_000_000) == "2 TB")
    }

    @Test func smallerUnitsStillShowOneDecimal() {
        #expect(formatStorageBytes(425_910_000_000) == "425.9 GB")
        #expect(formatStorageBytes(148_000_000_000) == "148 GB")
        #expect(formatStorageBytes(38_800_000) == "38.8 MB")
        #expect(formatStorageBytes(0) == "0 bytes")
    }

    @Test func purgeableIsAvailableMinusEmpty() {
        let capacity = VolumeCapacity(totalBytes: 2_000 * gb, availableBytes: 1_570 * gb, emptyBytes: 1_257 * gb)
        #expect(capacity.purgeableBytes == 313 * gb)
        #expect(capacity.usedBytes == 430 * gb)
    }

    @Test func purgeableIsZeroWhenTheVolumeDoesNotSayOrTheEstimatesCross() {
        #expect(VolumeCapacity(totalBytes: 500 * gb, availableBytes: 200 * gb).purgeableBytes == 0)
        #expect(VolumeCapacity(totalBytes: 500 * gb, availableBytes: 200 * gb, emptyBytes: 201 * gb).purgeableBytes == 0)
    }

    @Test func mentionedOnceItReachesTwentyGigabytes() {
        #expect(!OverviewView.mentionsPurgeable(purgeableBytes: 19 * gb, totalBytes: 2_000 * gb))
        #expect(OverviewView.mentionsPurgeable(purgeableBytes: 20 * gb, totalBytes: 2_000 * gb))
        #expect(OverviewView.mentionsPurgeable(purgeableBytes: 313 * gb, totalBytes: 2_000 * gb))
    }

    /// On a small disk, 5% is reached before 20 GB and is already a gap people notice.
    @Test func mentionedOnASmallDiskOnceItReachesFivePercent() {
        #expect(!OverviewView.mentionsPurgeable(purgeableBytes: 12 * gb, totalBytes: 256 * gb))
        #expect(OverviewView.mentionsPurgeable(purgeableBytes: 13 * gb, totalBytes: 256 * gb))
    }

    @Test func neverMentionedWithoutAnyOrWithoutADisk() {
        #expect(!OverviewView.mentionsPurgeable(purgeableBytes: 0, totalBytes: 2_000 * gb))
        #expect(!OverviewView.mentionsPurgeable(purgeableBytes: 50 * gb, totalBytes: 0))
    }
}
