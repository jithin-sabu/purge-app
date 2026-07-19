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
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/PurgeOffMainTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = dir.appendingPathComponent("payload.bin")
        try Data(repeating: 0xAB, count: 1024).write(to: payload)
        defer { try? fm.removeItem(at: dir) }

        let flag = MainThreadFlag()
        let key = dir.standardizedFileURL.path
        let report = try await FileDeleter().deleteItems(
            at: [dir],
            pathToDisplayName: [key: "Off-main test payload"],
            pathToExpectedSizeBytes: [key: 1024],
            onProgress: { _ in flag.record() }
        )

        #expect(report.deletedItems.count == 1)
        #expect(report.bytesMovedToTrash == 1024)
        #expect(!fm.fileExists(atPath: dir.path))
        #expect(flag.events >= 2)
        #expect(!flag.hitMainThread)
    }

    @MainActor
    @Test func deleteUserSelectedFilesRunsOffMainThreadWhenCalledFromMainActor() async throws {
        let fm = FileManager.default
        let downloads = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        try #require(fm.fileExists(atPath: downloads.path))
        let file = downloads.appendingPathComponent("PurgeOffMainTests-\(UUID().uuidString).bin")
        try Data(repeating: 0xCD, count: 2048).write(to: file)
        defer { try? fm.removeItem(at: file) }

        let flag = MainThreadFlag()
        let key = file.standardizedFileURL.path
        let report = try await FileDeleter().deleteUserSelectedFiles(
            at: [file],
            pathToDisplayName: [key: "Off-main test file"],
            pathToExpectedSizeBytes: [key: 2048],
            onProgress: { _ in flag.record() }
        )

        #expect(report.deletedItems.count == 1)
        #expect(!fm.fileExists(atPath: file.path))
        #expect(flag.events >= 2)
        #expect(!flag.hitMainThread)
    }
}
