import Foundation
import Testing
@testable import Purge

/// A retry goes back through the route that tried the item first, with the same
/// flags, so the same gate decides again (#174). Before this, every retry ran the
/// cache route, which refuses the user's own files by design: a Large Files row
/// could never be retried, and the refusal left no trace in the report.
@Suite("FileDeleter retries through the original route")
struct FileDeleterRetryRouteTests {
    /// A temporary home with a Downloads folder, so the Large Files gate has
    /// something to admit without going near the real home (#171).
    private struct Home {
        let url: URL
        let downloads: URL

        init() throws {
            let fm = FileManager.default
            url = fm.temporaryDirectory.appendingPathComponent("purgetest-retry-\(UUID().uuidString)", isDirectory: true)
            downloads = url.appendingPathComponent("Downloads", isDirectory: true)
            try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        }

        func file(_ relativePath: String, bytes: Int = 1024) throws -> URL {
            let file = url.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0xAB, count: bytes).write(to: file)
            return file
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @MainActor
    @Test("A Large Files row that failed once is retried on its own route and goes")
    func largeFileRetrySucceedsOnItsOwnRoute() async throws {
        let home = try Home()
        defer { home.remove() }
        let payload = try home.file("Downloads/payload.bin", bytes: 2048)
        let key = payload.standardizedFileURL.path
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let deleter = FileDeleter(home: home.url, trash: trash.trash)

        let report = try await deleter.deleteUserSelectedFiles(
            at: [payload],
            pathToDisplayName: [key: "payload.bin"],
            pathToExpectedSizeBytes: [key: 2048]
        )
        let failed = try #require(report.failedItems.first)
        #expect(failed.route == .userSelected(isAIModel: false, privilegedEligible: false))
        #expect(trash.trashedPaths.isEmpty)

        let outcome = await deleter.retryDeleteItem(
            at: payload,
            displayName: failed.displayName,
            expectedSizeBytes: failed.sizeBytes,
            route: failed.route
        )

        #expect(outcome == .deleted(bytes: 2048, movedToTrash: true, remaining: []))
        #expect(trash.trashedPaths == [key])
    }

    /// The deletion-safety fact: a retry on the cache route still answers to the
    /// cache allowlist, so a file that route never offered stays where it is.
    @MainActor
    @Test("The cache route refuses a user's file on retry as it did the first time")
    func cacheRouteRetryNeverWidensTheGate() async throws {
        let home = try Home()
        defer { home.remove() }
        let payload = try home.file("Downloads/payload.bin")
        let trash = FakeTrash()
        let deleter = FileDeleter(home: home.url, trash: trash.trash)

        let outcome = await deleter.retryDeleteItem(
            at: payload,
            displayName: "payload.bin",
            expectedSizeBytes: 1024,
            route: .cache
        )

        #expect(outcome == .failed(.safetySkipped))
        #expect(trash.trashedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    /// And the user-selected route still answers to its four gates: a path none of
    /// them vouches for is refused on retry too.
    @MainActor
    @Test("The user-selected route keeps its gates on retry")
    func userSelectedRouteKeepsItsGate() async throws {
        let home = try Home()
        defer { home.remove() }
        // Beside the home, where no scan policy reaches.
        let stray = home.url.deletingLastPathComponent().appendingPathComponent("purgetest-stray-\(UUID().uuidString).bin")
        try Data(repeating: 0x00, count: 512).write(to: stray)
        defer { try? FileManager.default.removeItem(at: stray) }
        let trash = FakeTrash()
        let deleter = FileDeleter(home: home.url, trash: trash.trash)

        let outcome = await deleter.retryDeleteItem(
            at: stray,
            displayName: "stray",
            expectedSizeBytes: 512,
            route: .userSelected(isAIModel: false, privilegedEligible: false)
        )

        #expect(outcome == .failed(.safetySkipped))
        #expect(trash.trashedPaths.isEmpty)
    }

    /// A model component answers to the model gate alone (#157). The flag is kept on
    /// the failure, so a retry cannot fall back to the union of gates, where the
    /// uninstall gate would admit anything under ~/Library.
    @MainActor
    @Test("The AI model flag stays on the retry")
    func aiModelFlagIsKept() async throws {
        let home = try Home()
        defer { home.remove() }
        let database = try home.file("Library/Application Support/nomic.ai/GPT4All/localdocs_v3.db", bytes: 4096)
        let key = database.standardizedFileURL.path
        let trash = FakeTrash()
        let deleter = FileDeleter(home: home.url, trash: trash.trash)

        let report = try await deleter.deleteUserSelectedFiles(
            at: [database],
            aiModelPaths: [key]
        )
        let skipped = try #require(report.skippedItems.first)
        #expect(skipped.route == .userSelected(isAIModel: true, privilegedEligible: false))

        let outcome = await deleter.retryDeleteItem(
            at: database,
            displayName: "GPT4All",
            expectedSizeBytes: 4096,
            route: skipped.route
        )

        #expect(outcome == .failed(.safetySkipped))
        #expect(trash.trashedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: database.path))
    }

    /// On the cache route a refusal used to be a silent `continue`. It is a row now.
    @MainActor
    @Test("A path the cache route refuses is reported as skipped")
    func refusedCacheItemIsReportedAsSkipped() async throws {
        let home = try Home()
        defer { home.remove() }
        let payload = try home.file("Downloads/payload.bin")
        let key = payload.standardizedFileURL.path
        let trash = FakeTrash()
        let deleter = FileDeleter(home: home.url, trash: trash.trash)

        let report = try await deleter.deleteItems(
            at: [payload],
            pathToDisplayName: [key: "payload.bin"]
        )

        #expect(report.deletedItems.isEmpty)
        #expect(report.failedItems.isEmpty)
        let skipped = try #require(report.skippedItems.first)
        #expect(skipped.isUserVisible)
        #expect(skipped.route == .cache)
        let visible = try #require(report.userVisibleFailures.first)
        #expect(visible.reason == .safetySkipped)
        #expect(visible.displayName == "payload.bin")
        #expect(trash.trashedPaths.isEmpty)
    }

    @MainActor
    @Test("A file that went some other way comes back as already gone")
    func goneFileIsAlreadyGone() async throws {
        let home = try Home()
        defer { home.remove() }
        let payload = try home.file("Downloads/payload.bin")
        try FileManager.default.removeItem(at: payload)
        let trash = FakeTrash()
        let deleter = FileDeleter(home: home.url, trash: trash.trash)

        let outcome = await deleter.retryDeleteItem(
            at: payload,
            displayName: "payload.bin",
            expectedSizeBytes: 1024,
            route: .userSelected(isAIModel: false, privilegedEligible: false)
        )

        #expect(outcome == .alreadyGone)
        #expect(trash.trashedPaths.isEmpty)
    }

    /// A leftover whose first clean did not mark it for the helper stays off the
    /// helper on retry, however the move fails.
    @MainActor
    @Test("A retry without helper eligibility never calls the privileged mover")
    func retryWithoutHelperEligibilityNeverCallsTheMover() async throws {
        let home = try Home()
        defer { home.remove() }
        let leftover = try home.file("Library/Preferences/com.purgetest.leftover.plist", bytes: 512)
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let moverCalls = MoverRecorder()
        let deleter = FileDeleter(
            privilegedMover: { urls in
                moverCalls.record(urls)
                return PrivilegedMoveResult(moved: urls, failed: [], indeterminate: [])
            },
            home: home.url,
            trash: trash.trash
        )

        let outcome = await deleter.retryDeleteItem(
            at: leftover,
            displayName: "PurgeTest Preferences",
            expectedSizeBytes: 512,
            route: .userSelected(isAIModel: false, privilegedEligible: false)
        )

        #expect(outcome == .failed(.unknown))
        #expect(moverCalls.calls.isEmpty)
        #expect(trash.trashedPaths.isEmpty)
    }

    private final class MoverRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [[URL]] = []
        func record(_ urls: [URL]) {
            lock.lock(); calls.append(urls); lock.unlock()
        }
    }

    /// The one place a failure is rebuilt from another: the helper is off, so the
    /// move becomes one-time setup. The route must come along, or the retry after
    /// setup would run the cache route and be refused.
    @MainActor
    @Test("The needs-administrator rewrite keeps the route")
    func needsAdministratorRewriteKeepsRoute() async throws {
        let home = try Home()
        defer { home.remove() }
        let leftover = try home.file("Library/Preferences/com.purgetest.leftover.plist", bytes: 512)
        let key = leftover.standardizedFileURL.path
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let deleter = FileDeleter(
            privilegedMover: { urls in
                PrivilegedMoveResult(moved: [], failed: urls, indeterminate: [], helperAvailable: false)
            },
            home: home.url,
            trash: trash.trash
        )

        let report = try await deleter.deleteUserSelectedFiles(
            at: [leftover],
            pathToDisplayName: [key: "PurgeTest Preferences"],
            privilegedEligiblePaths: [key]
        )

        let failed = try #require(report.failedItems.first)
        #expect(failed.reason == .needsAdministrator)
        #expect(failed.route == .userSelected(isAIModel: false, privilegedEligible: true))
        #expect(CleanFailureItem(failed: failed).route == failed.route)
    }
}
