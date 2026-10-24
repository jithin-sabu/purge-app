import Foundation
import Testing
@testable import Purge

/// What the session tells the result screen about a finished run (#162): how
/// many went and how many were tried, which outcome that is, and how the line
/// under the figure reads when some items were deleted outright.
@Suite("Deletion session outcome facts")
@MainActor
struct DeletionSessionOutcomeTests {
    private func failure(_ name: String, _ reason: CleanFailureReason = .unknown) -> CleanFailureItem {
        CleanFailureItem(path: "/tmp/\(name)", displayName: name, reason: reason, sizeBytes: 1)
    }

    @Test("Removed and attempted counts cover the Trash, permanent removals and the list")
    func counts() {
        let session = DeletionSession.completed(
            bytesMovedToTrash: 10,
            elapsedSeconds: 1,
            movedToTrashCount: 3,
            removedPermanentlyCount: 1,
            failedItems: [failure("a")]
        )

        #expect(session.removedCount == 4)
        #expect(session.attemptedCount == 5)
        #expect(session.outcome == .partial)
    }

    @Test("A Trash-only run keeps the wording that nothing is reclaimed yet")
    func trashOnlyWording() {
        let session = DeletionSession.completed(bytesMovedToTrash: 10, elapsedSeconds: 1, movedToTrashCount: 2, failedItems: [])

        #expect(session.removalWording == String(localized: "moved to trash, not yet reclaimed"))
    }

    @Test("A run that only deleted outright says so")
    func permanentOnlyWording() {
        let session = DeletionSession.completed(
            bytesMovedToTrash: 6_000_000_000,
            elapsedSeconds: 1,
            movedToTrashCount: 0,
            removedPermanentlyCount: 1,
            failedItems: []
        )

        #expect(session.removalWording == String(localized: "deleted permanently"))
        #expect(session.outcome == .success)
    }

    @Test("A mixed run names both by count")
    func mixedWording() {
        let session = DeletionSession.completed(
            bytesMovedToTrash: 10,
            elapsedSeconds: 1,
            movedToTrashCount: 2,
            removedPermanentlyCount: 1,
            failedItems: []
        )

        #expect(session.removalWording == String(localized: "\(2) moved to trash, \(1) deleted permanently"))
    }

    @Test("A live run records the permanent count at completion")
    func liveRunCompletes() {
        let session = DeletionSession(totalBytes: 10, totalItems: 2)

        session.completeRun(
            bytesMovedToTrash: 10,
            elapsedSeconds: 1,
            failedItems: [],
            movedToTrashCount: 1,
            removedPermanentlyCount: 1
        )

        #expect(session.removedPermanentlyCount == 1)
        #expect(session.removedCount == 2)
    }

    @Test("A retry that removed the last row turns a failed run into a success")
    func retryTurnsFailedIntoSuccess() {
        let row = failure("iPhone 17")
        let session = DeletionSession.completed(bytesMovedToTrash: 0, elapsedSeconds: 1, movedToTrashCount: 0, failedItems: [row])
        #expect(session.outcome == .failed)

        session.removeResolvedFailure(id: row.id, additionalMovedBytes: 5)
        session.noteRemovedPermanently(count: 1)

        #expect(session.outcome == .success)
        #expect(session.removedCount == 1)
        #expect(session.attemptedCount == 1)
        #expect(session.removalWording == String(localized: "deleted permanently"))
    }

    @Test("A retry that removed one of several rows turns a failed run partial")
    func retryTurnsFailedIntoPartial() {
        let first = failure("a")
        let second = failure("b")
        let session = DeletionSession.completed(bytesMovedToTrash: 0, elapsedSeconds: 1, movedToTrashCount: 0, failedItems: [first, second])

        session.removeResolvedFailure(id: first.id, additionalMovedBytes: 5)
        session.noteMovedToTrash(count: 1)

        #expect(session.outcome == .partial)
        #expect(session.attemptedCount == 2)
    }

    @Test("A zero count changes nothing")
    func zeroCount() {
        let session = DeletionSession.completed(bytesMovedToTrash: 0, elapsedSeconds: 1, movedToTrashCount: 0, failedItems: [])

        session.noteRemovedPermanently(count: 0)

        #expect(session.removedPermanentlyCount == 0)
    }
}
