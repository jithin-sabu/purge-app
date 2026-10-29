import Foundation
import Testing
@testable import Purge

/// The uninstaller's last resort: an item whose ordinary move failed goes to the
/// root helper, but only when the uninstall planner marked it and macOS gave no
/// reason for the failure (#189). The helper is a fake that records what it was
/// asked to move, every file lives in a temporary home, and the fake Trash moves
/// nothing (#171).
@Suite("FileDeleter hands a stuck uninstall item to the helper")
struct FileDeleterPrivilegedFallbackTests {
    /// A temporary home with leftovers in `Library/Preferences`, which the uninstall
    /// gate admits.
    private struct Home {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("purgetest-helper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func leftover(_ name: String) throws -> URL {
            let file = url.appendingPathComponent("Library/Preferences/\(name)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: 512).write(to: file)
            return file
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Records each request and answers it with `answer`.
    private final class Helper: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String]] = []
        private let answer: @Sendable ([URL]) -> PrivilegedMoveResult

        init(_ answer: @escaping @Sendable ([URL]) -> PrivilegedMoveResult) {
            self.answer = answer
        }

        func move(_ urls: [URL]) -> PrivilegedMoveResult {
            lock.lock()
            requests.append(urls.map(\.standardizedFileURL.path))
            lock.unlock()
            return answer(urls)
        }

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private func deleter(home: Home, helper: Helper, trash: @escaping FileDeleter.Trasher) -> FileDeleter {
        FileDeleter(privilegedMover: { helper.move($0) }, home: home.url, trash: trash)
    }

    @Test func aMoveTheHelperMadeCountsAsMovedToTheTrash() async throws {
        let home = try Home()
        defer { home.remove() }
        let leftover = try home.leftover("com.purgetest.locked.plist")
        let key = leftover.standardizedFileURL.path
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let helper = Helper { PrivilegedMoveResult(moved: $0, failed: [], indeterminate: [], ownershipIncomplete: $0) }

        let report = try await deleter(home: home, helper: helper, trash: trash.trash).deleteUserSelectedFiles(
            at: [leftover],
            pathToDisplayName: [key: "Locked Preferences"],
            pathToExpectedSizeBytes: [key: 512],
            privilegedEligiblePaths: [key]
        )

        #expect(helper.calls == [[key]])
        #expect(report.failedItems.isEmpty)
        #expect(report.bytesMovedToTrash == 512)
        let row = try #require(report.deletedItems.first)
        #expect(row.path == leftover.path)
        #expect(row.displayName == "Locked Preferences")
        #expect(row.movedToTrash)
        // The helper could not hand the item back, so emptying the Trash may ask
        // for a password, and the result says so.
        #expect(report.ownershipWarningPaths == [leftover.path])
    }

    /// The helper is set up and tried, and the item is still there: a real failure
    /// with Retry, not one-time setup again.
    @Test func aMoveTheHelperTriedAndFailedKeepsItsReason() async throws {
        let home = try Home()
        defer { home.remove() }
        let leftover = try home.leftover("com.purgetest.stuck.plist")
        let key = leftover.standardizedFileURL.path
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let helper = Helper { PrivilegedMoveResult(moved: [], failed: $0, indeterminate: []) }

        let report = try await deleter(home: home, helper: helper, trash: trash.trash).deleteUserSelectedFiles(
            at: [leftover],
            pathToExpectedSizeBytes: [key: 512],
            privilegedEligiblePaths: [key]
        )

        #expect(helper.calls == [[key]])
        #expect(report.deletedItems.isEmpty)
        let failed = try #require(report.failedItems.first)
        #expect(failed.reason == .unknown)
        #expect(failed.reason.showsRetry)
    }

    /// The helper timed out. An item gone from its place did move and is credited;
    /// one still there keeps its failure.
    @Test func anUnsettledHelperMoveCountsOnlyOnceTheItemIsGone() async throws {
        let home = try Home()
        defer { home.remove() }
        let gone = try home.leftover("com.purgetest.gone.plist")
        let stays = try home.leftover("com.purgetest.stays.plist")
        let keys = [gone, stays].map(\.standardizedFileURL.path)
        let trash = FakeTrash()
        trash.failNextCalls(2)
        let helper = Helper { urls in
            // It moved one before the request timed out.
            try? FileManager.default.removeItem(at: gone)
            return PrivilegedMoveResult(moved: [], failed: [], indeterminate: urls)
        }

        let report = try await deleter(home: home, helper: helper, trash: trash.trash).deleteUserSelectedFiles(
            at: [gone, stays],
            pathToExpectedSizeBytes: [keys[0]: 512, keys[1]: 512],
            privilegedEligiblePaths: Set(keys)
        )

        #expect(helper.calls == [keys])
        #expect(report.deletedItems.map(\.path) == [gone.path])
        #expect(report.bytesMovedToTrash == 512)
        #expect(report.failedItems.map(\.path) == [stays.path])
        #expect(report.failedItems.first?.reason == .unknown)
    }

    /// Only a path the planner marked, whose move failed for no reason macOS gave,
    /// goes to the helper. An item in use is never retried as root, and an unmarked
    /// one never reaches the helper however its move fails.
    @Test func onlyMarkedPathsWithAnUnexplainedFailureReachTheHelper() async throws {
        let home = try Home()
        defer { home.remove() }
        let marked = try home.leftover("com.purgetest.marked.plist")
        let unmarked = try home.leftover("com.purgetest.unmarked.plist")
        let inUse = try home.leftover("com.purgetest.inuse.plist")
        let markedKey = marked.standardizedFileURL.path
        let inUseKey = inUse.standardizedFileURL.path
        let inUseName = inUse.lastPathComponent
        // Every ordinary move fails: the one in use says so, the others say nothing.
        let trash: FileDeleter.Trasher = { url in
            let code = url.lastPathComponent == inUseName ? NSFileLockingError : NSFileWriteUnknownError
            throw NSError(domain: NSCocoaErrorDomain, code: code, userInfo: nil)
        }
        let helper = Helper { PrivilegedMoveResult(moved: $0, failed: [], indeterminate: []) }

        let report = try await deleter(home: home, helper: helper, trash: trash).deleteUserSelectedFiles(
            at: [marked, unmarked, inUse],
            privilegedEligiblePaths: [markedKey, inUseKey]
        )

        #expect(helper.calls == [[markedKey]])
        #expect(report.deletedItems.map(\.path) == [marked.path])
        #expect(report.failedItems.first { $0.path == unmarked.path }?.reason == .unknown)
        #expect(report.failedItems.first { $0.path == inUse.path }?.reason == .inUse)
        #expect(report.failedItems.count == 2)
    }
}
