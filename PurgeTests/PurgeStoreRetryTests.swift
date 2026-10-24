import Foundation
import Testing
@testable import Purge

/// Retry on the completion screen runs the row through the route that tried it
/// (#174). The store keeps the row, the session and the Large Files list in step
/// with what the retry found. Every file lives in a temporary home and goes to a
/// fake Trash, so nothing real moves (#171).
@Suite("Retry from the completion screen")
@MainActor
struct PurgeStoreRetryTests {
    private struct Home {
        let url: URL
        let payload: URL

        init() throws {
            let fm = FileManager.default
            url = fm.temporaryDirectory.appendingPathComponent("purge-store-retry-\(UUID().uuidString)", isDirectory: true)
            let downloads = url.appendingPathComponent("Downloads", isDirectory: true)
            try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
            payload = downloads.appendingPathComponent("payload.bin")
            try Data(repeating: 0xAB, count: 2048).write(to: payload)
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func failure(for url: URL, route: DeletionRoute) -> CleanFailureItem {
        CleanFailureItem(
            path: url.standardizedFileURL.path,
            displayName: "payload.bin",
            reason: .unknown,
            sizeBytes: 2048,
            route: route
        )
    }

    private static func finishedRun(with failure: CleanFailureItem) -> DeletionSession {
        DeletionSession.completed(
            bytesMovedToTrash: 0,
            elapsedSeconds: 1,
            movedToTrashCount: 0,
            failedItems: [failure]
        )
    }

    @Test("A Large Files failure retried after the cause is gone succeeds and clears the row")
    func largeFileRetrySucceeds() async throws {
        let home = try Home()
        defer { home.remove() }
        let trash = FakeTrash()
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore(fileDeleter: FileDeleter(home: home.url, trash: trash.trash))
        let row = LargeFile(
            path: home.payload,
            sizeBytes: 2048,
            lastUsed: Date(),
            category: LargeFileCategory.category(forExtension: "bin")
        )
        store.largeFiles = [row]
        let failure = Self.failure(for: home.payload, route: .userSelected(isAIModel: false, privilegedEligible: false))
        let session = Self.finishedRun(with: failure)

        let moved = await store.retryCleanFailure(failure, session: session)

        #expect(moved == 2048)
        #expect(trash.trashedPaths == [home.payload.standardizedFileURL.path])
        #expect(session.failedItems.isEmpty)
        #expect(session.finalBytesMovedToTrash == 2048)
        #expect(session.movedToTrashCount == 1)
        #expect(store.largeFiles.isEmpty)
    }

    /// The same row with the cache route is what every retry used to be. The gate
    /// refuses it, and the row now says so instead of offering Retry for good.
    @Test("A row the gate refuses on retry becomes a safety skip and keeps its id")
    func refusedRetryChangesTheReason() async throws {
        let home = try Home()
        defer { home.remove() }
        let trash = FakeTrash()
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore(fileDeleter: FileDeleter(home: home.url, trash: trash.trash))
        let failure = Self.failure(for: home.payload, route: .cache)
        let session = Self.finishedRun(with: failure)

        let moved = await store.retryCleanFailure(failure, session: session)

        #expect(moved == nil)
        #expect(trash.trashedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.payload.path))
        let row = try #require(session.failedItems.first)
        #expect(row.id == failure.id)
        #expect(row.reason == .safetySkipped)
        #expect(!row.reason.showsRetry)
        #expect(session.movedToTrashCount == 0)
    }

    @Test("A row for a file that is already gone is dropped and credited nothing")
    func goneRowIsDropped() async throws {
        let home = try Home()
        defer { home.remove() }
        try FileManager.default.removeItem(at: home.payload)
        let trash = FakeTrash()
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore(fileDeleter: FileDeleter(home: home.url, trash: trash.trash))
        let row = LargeFile(
            path: home.payload,
            sizeBytes: 2048,
            lastUsed: Date(),
            category: LargeFileCategory.category(forExtension: "bin")
        )
        store.largeFiles = [row]
        let failure = Self.failure(for: home.payload, route: .userSelected(isAIModel: false, privilegedEligible: false))
        let session = Self.finishedRun(with: failure)

        let moved = await store.retryCleanFailure(failure, session: session)

        #expect(moved == nil)
        #expect(trash.trashedPaths.isEmpty)
        #expect(session.failedItems.isEmpty)
        #expect(session.finalBytesMovedToTrash == 0)
        #expect(session.movedToTrashCount == 0)
        #expect(store.largeFiles.isEmpty)
    }
}
