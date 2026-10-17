import Foundation
import Testing
@testable import Purge

/// `DeletionReport.movedNothingAndFailed` decides whether a scheduled clean is
/// retried. Only a run that moved nothing and had a real failure counts; a run
/// that counted skips or missing files as failures would retry far too often (#173).
@Suite("Deletion report failure rule")
struct DeletionReportFailureTests {
    private func report(
        deleted: [DeletedItem] = [],
        failed: [FailedDeletionItem] = [],
        skipped: [SkippedDeletionItem] = []
    ) -> DeletionReport {
        DeletionReport(
            bytesMovedToTrash: deleted.filter(\.movedToTrash).reduce(0) { $0 + $1.sizeBytes },
            bytesRemovedDirectly: deleted.filter { !$0.movedToTrash }.reduce(0) { $0 + $1.sizeBytes },
            deletedItems: deleted,
            failedItems: failed,
            skippedItems: skipped,
            capacityBefore: nil,
            capacityAfter: nil,
            timestamp: Date()
        )
    }

    private let trashed = DeletedItem(path: "/tmp/purge-tests/a", sizeBytes: 10)
    private let removedForGood = DeletedItem(path: "/tmp/purge-tests/sim", sizeBytes: 10, movedToTrash: false)
    private let refusedByTrash = FailedDeletionItem(path: "/tmp/purge-tests/b", displayName: "b", reason: .inUse, sizeBytes: 10)
    private let keptForSafety = SkippedDeletionItem(path: "/tmp/purge-tests/c", displayName: "c", reason: "policy", isUserVisible: true)

    /// Nothing moved and something failed: the run did not do its job.
    @Test("Every item failing is a failed run")
    func everyItemFailingIsAFailedRun() {
        #expect(report(failed: [refusedByTrash]).movedNothingAndFailed)
        #expect(report(failed: [refusedByTrash], skipped: [keptForSafety]).movedNothingAndFailed)
    }

    /// A partial clean counts as done; the items that failed are listed instead.
    @Test("A partial clean is not a failed run")
    func partialCleanIsNotAFailedRun() {
        #expect(!report(deleted: [trashed], failed: [refusedByTrash]).movedNothingAndFailed)
    }

    /// Items the safety policy kept back are not failures, and neither is an empty run.
    @Test("Only skipped items, or nothing at all, is not a failed run")
    func skipsAloneAreNotAFailedRun() {
        #expect(!report(skipped: [keptForSafety]).movedNothingAndFailed)
        #expect(!report().movedNothingAndFailed)
    }

    /// A simulator removed through simctl is deleted, even though nothing went to the Trash.
    @Test("A permanent removal is not a failed run")
    func permanentRemovalIsNotAFailedRun() {
        #expect(!report(deleted: [removedForGood]).movedNothingAndFailed)
        #expect(!report(deleted: [removedForGood], failed: [refusedByTrash]).movedNothingAndFailed)
    }
}
