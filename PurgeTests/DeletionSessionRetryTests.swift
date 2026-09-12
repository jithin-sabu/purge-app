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
