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

    // MARK: Scripts folders (#362)

    /// An Application Scripts folder in the temporary home, as macOS makes one:
    /// empty unless `scripts` names files to put in it.
    private static func scriptsFolder(in home: Home, named name: String, scripts: [String] = []) throws -> URL {
        let folder = home.url.appendingPathComponent("Library/Application Scripts/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for script in scripts {
            try Data("on run\nend run".utf8).write(to: folder.appendingPathComponent(script))
        }
        return folder
    }

    private static func scriptsFailure(for folder: URL, holdsAddedScripts: Bool = false) -> CleanFailureItem {
        CleanFailureItem(
            path: folder.standardizedFileURL.path,
            displayName: "PurgeTest Application Scripts",
            reason: .unknown,
            sizeBytes: 512,
            route: .userSelected(isAIModel: false, privilegedEligible: false),
            holdsAddedScripts: holdsAddedScripts
        )
    }

    /// Every clean reads a scripts folder right before the move and leaves one
    /// that was approved as empty and holds files now (#352). Retry went straight
    /// to the engine, so a script that landed after a failed move went to the
    /// Trash with the folder.
    @Test("Retry leaves a scripts folder that gained files after it was approved as empty")
    func retryLeavesScriptsFolderThatGainedFiles() async throws {
        let home = try Home()
        defer { home.remove() }
        let trash = FakeTrash()
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore(fileDeleter: FileDeleter(home: home.url, trash: trash.trash))
        let folder = try Self.scriptsFolder(in: home, named: "com.purgetest.retry")
        let failure = Self.scriptsFailure(for: folder)
        let session = Self.finishedRun(with: failure)
        // The move failed while the folder was empty. A script lands before Retry.
        try Data("on run\nend run".utf8).write(to: folder.appendingPathComponent("Late.scpt"))

        let moved = await store.retryCleanFailure(failure, session: session)

        #expect(moved == nil)
        #expect(trash.trashedPaths.isEmpty)
        let row = try #require(session.failedItems.first)
        #expect(row.id == failure.id)
        #expect(row.reason == .safetySkipped)
        #expect(!row.reason.showsRetry)
        #expect(session.movedToTrashCount == 0)
    }

    @Test("Retry still moves a scripts folder that is empty, and one ticked with its files")
    func retryMovesScriptsFoldersTheUserApproved() async throws {
        let home = try Home()
        defer { home.remove() }
        let trash = FakeTrash()
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore(fileDeleter: FileDeleter(home: home.url, trash: trash.trash))

        // Still as it was approved: empty but for Finder's own file.
        let empty = try Self.scriptsFolder(in: home, named: "com.purgetest.empty", scripts: [".DS_Store"])
        let emptyFailure = Self.scriptsFailure(for: empty)
        let emptySession = Self.finishedRun(with: emptyFailure)
        #expect(await store.retryCleanFailure(emptyFailure, session: emptySession) == 512)
        #expect(emptySession.failedItems.isEmpty)

        // Ticked with its scripts showing in the sheet, so the row says so.
        let ticked = try Self.scriptsFolder(in: home, named: "com.purgetest.ticked", scripts: ["Export.scpt"])
        let tickedFailure = Self.scriptsFailure(for: ticked, holdsAddedScripts: true)
        let tickedSession = Self.finishedRun(with: tickedFailure)
        #expect(await store.retryCleanFailure(tickedFailure, session: tickedSession) == 512)
        #expect(tickedSession.failedItems.isEmpty)

        #expect(trash.trashedPaths == [empty.standardizedFileURL.path, ticked.standardizedFileURL.path])
    }

    /// The engine's report knows paths, not sheets, so the store marks the rows
    /// of the scripts folders the user ticked with files in them. The mark must
    /// outlive a retry that changes the row's reason.
    @Test("A failure row keeps whether its scripts folder was ticked with files")
    func failureRowCarriesTheScriptsMark() {
        let ticked = "/Users/example/Library/Application Scripts/com.vendor.Ticked"
        let empty = "/Users/example/Library/Application Scripts/com.vendor.Empty"
        func row(_ path: String) -> CleanFailureItem {
            CleanFailureItem(path: path, displayName: "", reason: .inUse, route: .userSelected(isAIModel: false, privilegedEligible: false))
        }
        let original = row(ticked)
        #expect(!original.holdsAddedScripts)

        let marked = original.markingScriptsFolder(approvedWithFiles: [ticked])
        #expect(marked.holdsAddedScripts)
        #expect(marked.id == original.id)
        #expect(marked.reason == .inUse)
        #expect(marked.route == original.route)
        #expect(!row(empty).markingScriptsFolder(approvedWithFiles: [ticked]).holdsAddedScripts)
        // Another spelling of the same path is the same folder.
        #expect(row(ticked + "/../com.vendor.Ticked").markingScriptsFolder(approvedWithFiles: [ticked]).holdsAddedScripts)

        let retried = marked.replacingReason(.unknown)
        #expect(retried.id == marked.id)
        #expect(retried.holdsAddedScripts)
    }
}
