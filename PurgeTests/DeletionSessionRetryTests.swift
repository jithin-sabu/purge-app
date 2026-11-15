import Testing
@testable import Purge

@Suite("Deletion session retry accounting")
@MainActor
struct DeletionSessionRetryTests {
    @Test("A partial retry credits moved bytes and keeps only the remaining failures")
    func partialRetryAccounting() {
        let groupedFailure = CleanFailureItem(
            path: "/Applications/Example.app",
            displayName: "Example",
            reason: .needsAdministrator,
            sizeBytes: 300
        )
        let session = DeletionSession.completed(
            bytesMovedToTrash: 100,
            elapsedSeconds: 1,
            movedToTrashCount: 1,
            failedItems: [groupedFailure]
        )
        let remaining = CleanFailureItem(
            path: "/Library/Application Support/Example",
            displayName: "Example Application Support",
            reason: .unknown,
            sizeBytes: 50
        )

        session.addRetriedMovedBytes(250)
        session.replaceFailure(id: groupedFailure.id, with: [remaining])

        #expect(session.finalBytesMovedToTrash == 350)
        #expect(session.failedCount == 1)
        #expect(session.failedItems == [remaining])
    }
}

@Suite("Deletion session retry Trash count")
@MainActor
struct DeletionSessionRetryTrashCountTests {
    /// A run that moved nothing shows no "Empty your Trash" line. Once a retry
    /// moves something, the line has to appear, so the count moves with it (#174).
    @Test("A retry that moved an item to the Trash counts toward the Trash line")
    func retryCountsTowardTheTrashLine() {
        let failure = CleanFailureItem(
            path: "/Users/me/Downloads/payload.bin",
            displayName: "payload.bin",
            reason: .unknown,
            sizeBytes: 2048,
            route: .userSelected(isAIModel: false, privilegedEligible: false)
        )
        let session = DeletionSession.completed(
            bytesMovedToTrash: 0,
            elapsedSeconds: 1,
            movedToTrashCount: 0,
            failedItems: [failure]
        )

        session.removeResolvedFailure(id: failure.id, additionalMovedBytes: 2048)
        session.noteMovedToTrash(count: 1)

        #expect(session.failedItems.isEmpty)
        #expect(session.finalBytesMovedToTrash == 2048)
        #expect(session.movedToTrashCount == 1)
    }

    @Test("An item removed outright does not count toward the Trash line")
    func directRemovalDoesNotCount() {
        let session = DeletionSession.completed(
            bytesMovedToTrash: 0,
            elapsedSeconds: 1,
            movedToTrashCount: 0,
            failedItems: []
        )

        session.noteMovedToTrash(count: 0)

        #expect(session.movedToTrashCount == 0)
    }

    @Test("A retry that found a different reason keeps the row with that reason")
    func replacingReasonKeepsTheRow() {
        let failure = CleanFailureItem(
            path: "/Users/me/Downloads/payload.bin",
            displayName: "payload.bin",
            reason: .unknown,
            sizeBytes: 2048,
            route: .userSelected(isAIModel: false, privilegedEligible: false)
        )
        let session = DeletionSession.completed(
            bytesMovedToTrash: 0,
            elapsedSeconds: 1,
            movedToTrashCount: 0,
            failedItems: [failure]
        )

        session.replaceFailure(id: failure.id, with: [failure.replacingReason(.safetySkipped)])

        let row = session.failedItems.first
        #expect(row?.id == failure.id)
        #expect(row?.reason == .safetySkipped)
        #expect(row?.route == failure.route)
        #expect(row?.reason.showsRetry == false)
    }
}
