import Foundation
import Testing
@testable import Purge

/// Lock-protected flag written from the deletion engine's executor.
private final class MainThreadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var sawMainThread = false
    private var eventCount = 0

    func record() {
        lock.lock()
        defer { lock.unlock() }
        if Thread.isMainThread { sawMainThread = true }
        eventCount += 1
    }

    var hitMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawMainThread
    }

    var events: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventCount
    }
}

@Suite("FileDeleter off-main execution")
struct FileDeleterOffMainTests {
    /// The 30s-beachball regression: the engine used to inherit @MainActor from
    /// the project's default isolation, so `trashItem` on huge folders froze the
    /// UI. Deletion must run (and report progress) off the main thread even when
    /// invoked from the main actor, as PurgeStore does.
    @MainActor
    @Test func deleteItemsRunsOffMainThreadWhenCalledFromMainActor() async throws {
        // The cache allowlist only offers paths under the real home, so the folder
        // is named there. It is never made, and the fake Trash moves nothing, so
        // nothing on disk is written or moved (#171).
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/PurgeOffMainTests-\(UUID().uuidString)", isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: dir.path))

        let flag = MainThreadFlag()
        let trash = FakeTrash()
        let key = dir.standardizedFileURL.path
        let report = try await FileDeleter(trash: trash.trash).deleteItems(
            at: [dir],
            pathToDisplayName: [key: "Off-main test payload"],
            pathToExpectedSizeBytes: [key: 1024],
            onProgress: { _ in flag.record() }
        )

        #expect(report.deletedItems.count == 1)
        #expect(report.bytesMovedToTrash == 1024)
        #expect(trash.trashedPaths == [key])
        #expect(!trash.sawMainThread)
        #expect(flag.events >= 2)
        #expect(!flag.hitMainThread)
    }

    @MainActor
    @Test func deleteUserSelectedFilesRunsOffMainThreadWhenCalledFromMainActor() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("PurgeOffMainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent("payload.bin")
        try Data(repeating: 0xCD, count: 2048).write(to: file)

        let flag = MainThreadFlag()
        let trash = FakeTrash()
        let key = file.standardizedFileURL.path
        let report = try await FileDeleter(home: home, trash: trash.trash).deleteUserSelectedFiles(
            at: [file],
            pathToDisplayName: [key: "Off-main test file"],
            pathToExpectedSizeBytes: [key: 2048],
            onProgress: { _ in flag.record() }
        )

        #expect(report.deletedItems.count == 1)
        #expect(trash.trashedPaths == [key])
        #expect(!trash.sawMainThread)
        #expect(flag.events >= 2)
        #expect(!flag.hitMainThread)
    }
}
