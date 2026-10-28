import Foundation
import Testing
@testable import Purge

/// Two checks inside the cache route that nothing tested (#189): a folder emptied
/// entry by entry asks the gate about each entry, and every folder is checked once
/// more right before it moves. The fake Trash moves nothing (#171).
@Suite("FileDeleter cache route")
struct FileDeleterCacheRouteTests {
    /// `~/Library/Caches` itself: a clean empties it and never moves it. Its entries
    /// come from a fixed list, so the user's own folder is never listed, and none
    /// of the entries exists.
    private let caches = URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
        .appendingPathComponent("Library/Caches", isDirectory: true)

    private func entry(_ name: String) -> URL {
        caches.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: Emptied entry by entry

    /// Apple's account daemon keeps its cache here, and the gate refuses it by name.
    /// Only the entry the gate offers moves, and the folder stays.
    @Test func onlyEntriesTheGateOffersMoveAndTheFolderStays() async throws {
        try #require(DeletionSafetyPolicy.shouldDeleteContentsOnly(caches))
        let refused = entry("com.apple.akd")
        let offered = entry("com.purge.test.offered-\(UUID().uuidString)")
        let key = caches.standardizedFileURL.path
        let trash = FakeTrash()
        let deleter = FileDeleter(trash: trash.trash, listContents: { _ in [refused, offered] })

        let report = try await deleter.deleteItems(at: [caches], pathToDisplayName: [key: "App Caches"])

        #expect(trash.trashedPaths == [offered.standardizedFileURL.path])
        #expect(report.deletedItems.map(\.path) == [caches.path])
        let row = try #require(report.deletedItems.first)
        #expect(row.displayName == "App Caches")
        #expect(report.failedItems.isEmpty)
    }

    /// An entry that fails to move is a failed row of its own. The entries after it
    /// still move, and the folder counts as cleaned.
    @Test func anEntryThatFailsIsItsOwnRowAndTheRestStillMove() async throws {
        let busy = entry("com.purge.test.busy-\(UUID().uuidString)")
        let free = entry("com.purge.test.free-\(UUID().uuidString)")
        let trash = FakeTrash()
        trash.failNextCalls(1)
        let deleter = FileDeleter(trash: trash.trash, listContents: { _ in [busy, free] })

        let report = try await deleter.deleteItems(at: [caches])

        #expect(trash.trashedPaths == [free.standardizedFileURL.path])
        #expect(report.failedItems.map(\.path) == [busy.path])
        #expect(report.failedItems.first?.route == .cache)
        #expect(report.deletedItems.map(\.path) == [caches.path])
    }

    /// With every entry refused, nothing moved, so the folder is not reported as cleaned.
    @Test func aFolderWhoseEntriesAllStayIsNotReportedAsCleaned() async throws {
        let refused = entry("com.apple.akd")
        let trash = FakeTrash()
        let deleter = FileDeleter(trash: trash.trash, listContents: { _ in [refused] })

        let report = try await deleter.deleteItems(at: [caches])

        #expect(trash.trashedPaths.isEmpty)
        #expect(report.deletedItems.isEmpty)
        #expect(report.failedItems.isEmpty)
    }

    /// The live listing leaves hidden entries such as `.DS_Store` out.
    @Test func theListingLeavesHiddenEntriesOut() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-contents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try Data().write(to: folder.appendingPathComponent("visible"))

        #expect(try FileDeleter.visibleContents(of: folder).map(\.lastPathComponent) == ["visible"])
    }

    // MARK: Checked again before the move

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = false

        func set() {
            lock.lock(); seen = true; lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    /// A `.terraform` folder is offered while it holds only providers. Terraform can
    /// write state into it after the first checks passed; the check right before the
    /// move then refuses it. The project sits under the real home, where the policy
    /// offers project folders, and is removed afterwards.
    @Test func aFolderThatStartsHoldingStateDuringTheCleanStays() async throws {
        let folders = RealHomeFolders()
        defer { folders.remove() }
        let project = try folders.make(".purge-test-recheck-\(UUID().uuidString)")
        try Data().write(to: project.appendingPathComponent("main.tf"))
        let terraform = project.appendingPathComponent(".terraform", isDirectory: true)
        try FileManager.default.createDirectory(
            at: terraform.appendingPathComponent("providers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #require(DeletionSafetyPolicy.isOfferedForCleanup(terraform))

        let key = terraform.standardizedFileURL.path
        let state = terraform.appendingPathComponent("terraform.tfstate")
        let trash = FakeTrash()
        let started = Seen()
        let report = try await FileDeleter(trash: trash.trash).deleteItems(
            at: [terraform],
            pathToExpectedSizeBytes: [key: 4096],
            onProgress: { event in
                // Sent once the first checks passed, before the move.
                guard case .itemStarted = event else { return }
                started.set()
                FileManager.default.createFile(atPath: state.path, contents: Data("{}".utf8))
            }
        )

        #expect(started.isSet)
        #expect(trash.trashedPaths.isEmpty)
        #expect(report.deletedItems.isEmpty)
        let skipped = try #require(report.skippedItems.first)
        #expect(skipped.path == terraform.path)
        #expect(skipped.isUserVisible)
    }
}
