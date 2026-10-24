import Foundation
import Testing
@testable import Purge

/// The result screen is picked from what happened, one row of the table in #162
/// per test. Never from a share of the items: that rule called a run with one
/// 40 GB failure beside nine small successes a success.
@Suite("Clean outcome")
@MainActor
struct CleanOutcomeTests {
    private func failure(_ name: String, _ reason: CleanFailureReason, bytes: Int64 = 1) -> CleanFailureItem {
        CleanFailureItem(path: "/tmp/\(name)", displayName: name, reason: reason, sizeBytes: bytes)
    }

    @Test("Nothing failed is a success")
    func nothingFailed() {
        #expect(CleanOutcome.resolve(removedCount: 3, failedItems: []) == .success)
    }

    @Test("Some removed and some failed is partial")
    func someFailed() {
        let outcome = CleanOutcome.resolve(removedCount: 4, failedItems: [failure("a", .inUse)])
        #expect(outcome == .partial)
    }

    @Test("Nothing removed and a failure is failed")
    func nothingRemoved() {
        let outcome = CleanOutcome.resolve(removedCount: 0, failedItems: [failure("iPhone 17", .xcodeLicenseNotAccepted)])
        #expect(outcome == .failed)
    }

    @Test("Nothing removed and only safety skips is skipped only")
    func onlySkips() {
        let outcome = CleanOutcome.resolve(
            removedCount: 0,
            failedItems: [failure("a", .safetySkipped), failure("b", .safetySkipped)]
        )
        #expect(outcome == .skippedOnly)
    }

    @Test("A safety skip beside a real failure, with nothing removed, is failed")
    func skipBesideFailure() {
        let outcome = CleanOutcome.resolve(
            removedCount: 0,
            failedItems: [failure("a", .safetySkipped), failure("b", .unknown)]
        )
        #expect(outcome == .failed)
    }

    @Test("A locked app with nothing removed is failed, not skipped")
    func lockedApp() {
        let outcome = CleanOutcome.resolve(removedCount: 0, failedItems: [failure("Teams", .needsAdministrator)])
        #expect(outcome == .failed)
    }

    @Test("One big failure beside nine small successes is partial, not a success")
    func bigFailureSmallSuccesses() {
        let big = failure("Docker.raw", .inUse, bytes: 40_000_000_000)
        #expect(CleanOutcome.resolve(removedCount: 9, failedItems: [big]) == .partial)
    }

    @Test("A permanent removal counts as removed even with nothing in the Trash")
    func permanentRemovalCounts() {
        let session = DeletionSession.completed(
            bytesMovedToTrash: 6_000_000_000,
            elapsedSeconds: 1,
            movedToTrashCount: 0,
            removedPermanentlyCount: 1,
            failedItems: [failure("iPad", .unknown)]
        )
        #expect(session.outcome == .partial)
    }

    @Test("Only the figure outcomes show the figure")
    func figureOutcomes() {
        #expect(CleanOutcome.success.showsFigure)
        #expect(CleanOutcome.partial.showsFigure)
        #expect(!CleanOutcome.failed.showsFigure)
        #expect(!CleanOutcome.skippedOnly.showsFigure)
    }
}
