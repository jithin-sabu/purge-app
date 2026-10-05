import Testing
@testable import Purge

/// A folder emptied one entry at a time must move the progress screen as it goes,
/// and the partial reports plus the final one must add up to exactly its size (#59).
@Suite("Contents progress splitter")
struct ContentsProgressSplitterTests {
    @Test("Every entry reports a share and the remainder makes up the exact size")
    func sharesAddUpToTheFolderSize() {
        var splitter = ContentsProgressSplitter(totalBytes: 1_000, entryCount: 3)
        var reported: [Int64] = []
        for _ in 0..<3 {
            if let share = splitter.shareForMovedEntry() { reported.append(share) }
        }
        #expect(reported == [333, 333, 333])
        #expect(splitter.remainingBytes == 1)
        #expect(reported.reduce(0, +) + splitter.remainingBytes == 1_000)
    }

    @Test("Partial reports never reach the full size, so the item still finishes the run")
    func partialReportsStopShortOfTheTotal() {
        var splitter = ContentsProgressSplitter(totalBytes: 100, entryCount: 4)
        var reported: Int64 = 0
        for _ in 0..<4 {
            reported += splitter.shareForMovedEntry() ?? 0
        }
        #expect(reported == 75)
        #expect(splitter.remainingBytes == 25)
    }

    @Test("Failed entries leave their share for the final report")
    func skippedEntriesFoldIntoTheRemainder() {
        var splitter = ContentsProgressSplitter(totalBytes: 900, entryCount: 3)
        _ = splitter.shareForMovedEntry()
        #expect(splitter.remainingBytes == 600)
    }

    @Test("More entries than bytes, an empty folder, or no size report nothing early")
    func degenerateInputsReportOnlyAtTheEnd() {
        var tiny = ContentsProgressSplitter(totalBytes: 5, entryCount: 50)
        #expect(tiny.shareForMovedEntry() == nil)
        #expect(tiny.remainingBytes == 5)

        var empty = ContentsProgressSplitter(totalBytes: 5, entryCount: 0)
        #expect(empty.shareForMovedEntry() == nil)
        #expect(empty.remainingBytes == 5)

        var unsized = ContentsProgressSplitter(totalBytes: 0, entryCount: 10)
        #expect(unsized.shareForMovedEntry() == nil)
        #expect(unsized.remainingBytes == 0)
    }

    @MainActor
    @Test("Partial events move the byte total without counting an item")
    func bufferCountsPartialBytesButNotItems() {
        let buffer = DeletionProgressBuffer()
        buffer.ingest(.itemStarted(name: "Telegram Media Cache"))
        buffer.ingest(.itemPartlyDeleted(sizeBytes: 300))
        buffer.ingest(.itemPartlyDeleted(sizeBytes: 300))
        var snapshot = buffer.snapshot()
        #expect(snapshot.bytesMovedToTrash == 600)
        #expect(snapshot.itemsCompleted == 0)

        buffer.ingest(.itemDeleted(sizeBytes: 400))
        snapshot = buffer.snapshot()
        #expect(snapshot.bytesMovedToTrash == 1_000)
        #expect(snapshot.itemsCompleted == 1)
    }
}
