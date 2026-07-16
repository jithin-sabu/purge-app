import Foundation
import Testing
@testable import Purge

/// The point of this feature: a sum of moved file sizes must never be presentable as
/// reclaimed space. These tests pin the boundary between the two numbers.
@Suite("Trash-pending accounting")
struct TrashPendingAccountingTests {
    private func report(
        movedToTrash: Int64,
        removedDirectly: Int64 = 0,
        availableBefore: Int64?,
        availableAfter: Int64?
    ) -> DeletionReport {
        DeletionReport(
            bytesMovedToTrash: movedToTrash,
            bytesRemovedDirectly: removedDirectly,
            deletedItems: [],
            failedItems: [],
            skippedItems: [],
            capacityBefore: availableBefore.map { VolumeCapacity(totalBytes: 1_000, availableBytes: $0) },
            capacityAfter: availableAfter.map { VolumeCapacity(totalBytes: 1_000, availableBytes: $0) },
            timestamp: Date()
        )
    }

    @Test func reclaimedIsNilWhenTheVolumeWasNeverMeasured() {
        let unmeasured = report(movedToTrash: 5_000_000_000, availableBefore: nil, availableAfter: nil)
        #expect(unmeasured.bytesReclaimedOnVolume == nil)
        #expect(unmeasured.reportableBytesReclaimedOnVolume == nil)
    }

    /// A trash move frees nothing, so the delta sits at noise. The moved figure must
    /// not be substituted in to make the result look better.
    @Test func trashMoveReportsNoReclaimDespiteLargeMovedTotal() {
        let trashOnly = report(
            movedToTrash: 5_000_000_000,
            availableBefore: 100_000_000_000,
            availableAfter: 100_000_000_000
        )
        #expect(trashOnly.bytesReclaimedOnVolume == 0)
        #expect(trashOnly.reportableBytesReclaimedOnVolume == nil)
    }

    /// Other processes write while we measure, so the volume can end up with less
    /// free space than it started with. That must read as unmeasurable, not as zero
    /// and not as the moved total.
    @Test func negativeDeltaIsNotReportedAsReclaim() {
        let noisy = report(
            movedToTrash: 5_000_000_000,
            availableBefore: 100_000_000_000,
            availableAfter: 99_000_000_000
        )
        #expect(noisy.bytesReclaimedOnVolume == -1_000_000_000)
        #expect(noisy.reportableBytesReclaimedOnVolume == nil)
    }

    @Test func realReclaimAboveNoiseIsReported() {
        let real = report(
            movedToTrash: 0,
            availableBefore: 100_000_000_000,
            availableAfter: 105_000_000_000
        )
        #expect(real.reportableBytesReclaimedOnVolume == 5_000_000_000)
    }

    /// Simulators go through `simctl delete` and never reach the trash, so their bytes
    /// must not inflate the pending-in-trash figure.
    @Test func directRemovalsAreNotCountedAsPendingInTrash() {
        let mixed = report(
            movedToTrash: 1_000,
            removedDirectly: 9_000,
            availableBefore: nil,
            availableAfter: nil
        )
        #expect(mixed.bytesMovedToTrash == 1_000)
        #expect(mixed.bytesRemovedDirectly == 9_000)
    }

    /// History written before this change stored a sum of moved sizes under a field
    /// named as if it were freed space. It must decode as moved and never as reclaimed.
    @Test func legacyHistoryEntryDecodesAsMovedAndNeverAsReclaimed() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "date": "2026-01-01T00:00:00Z",
          "trigger": "manual",
          "totalFreedBytes": 4096,
          "deletedItems": [],
          "skippedItems": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(CleanupHistoryEntry.self, from: Data(legacy.utf8))

        #expect(entry.bytesMovedToTrash == 4096)
        #expect(entry.bytesReclaimedOnVolume == nil)
    }

    @Test func historyEntryRoundTripsMeasuredReclaim() throws {
        let entry = CleanupHistoryEntry(
            trigger: .scheduled,
            bytesMovedToTrash: 4096,
            bytesReclaimedOnVolume: 2048,
            deletedItems: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CleanupHistoryEntry.self, from: encoder.encode(entry))
        #expect(decoded.bytesMovedToTrash == 4096)
        #expect(decoded.bytesReclaimedOnVolume == 2048)
    }

    /// The persisted scheduled-clean outcome carries the same legacy field name.
    @Test func legacyScheduledOutcomeDecodesAsMoved() throws {
        let legacy = """
        { "date": "2026-01-01T00:00:00Z", "freedBytes": 8192, "deletedCount": 3 }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outcome = try decoder.decode(LastScheduledCleanOutcome.self, from: Data(legacy.utf8))

        #expect(outcome.bytesMovedToTrash == 8192)
        #expect(outcome.deletedCount == 3)
    }
}
