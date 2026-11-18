import Foundation
import Testing
@testable import Purge

/// `FileDeleter`'s last check before a Dev Tools row moves (#400). For an nvm Node
/// version it reads what the main-thread list gate can't afford: configs, `bin`
/// links and `lsof`. A clean and a Retry must both ask it.
///
/// The real check only knows the real home's `~/.nvm`, and tests never touch that,
/// so these hand in a fake check and use a row the gate offers under the real home:
/// a `.terraform` folder holding only providers, in a throwaway project removed
/// afterwards. `NvmNodeVersionTests` checks the real check itself.
@Suite("FileDeleter move check (#400)")
struct FileDeleterMoveCheckTests {
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ url: URL) { lock.lock(); paths.append(url.standardizedFileURL.path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private func terraformFolder(_ folders: RealHomeFolders) throws -> URL {
        let project = try folders.make(".purge-test-move-check-\(UUID().uuidString)")
        try Data().write(to: project.appendingPathComponent("main.tf"))
        let terraform = project.appendingPathComponent(".terraform", isDirectory: true)
        try FileManager.default.createDirectory(
            at: terraform.appendingPathComponent("providers", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #require(DeletionSafetyPolicy.isOfferedForCleanup(terraform))
        return terraform
    }

    @Test func aCleanSkipsARowTheMoveCheckRefuses() async throws {
        let folders = RealHomeFolders()
        defer { folders.remove() }
        let terraform = try terraformFolder(folders)
        let trash = FakeTrash()
        let asked = Asked()
        let deleter = FileDeleter(trash: trash.trash, immediateMoveCheck: { asked.add($0); return false })

        let report = try await deleter.deleteItems(at: [terraform])

        #expect(asked.all == [terraform.standardizedFileURL.path])
        #expect(trash.trashedPaths.isEmpty)
        #expect(report.deletedItems.isEmpty)
        let skipped = try #require(report.skippedItems.first)
        #expect(skipped.path == terraform.path)
        #expect(skipped.isUserVisible)
    }

    @Test func aRetrySkipsARowTheMoveCheckRefuses() async throws {
        let folders = RealHomeFolders()
        defer { folders.remove() }
        let terraform = try terraformFolder(folders)
        let trash = FakeTrash()
        let asked = Asked()
        let deleter = FileDeleter(trash: trash.trash, immediateMoveCheck: { asked.add($0); return false })

        let outcome = await deleter.retryDeleteItem(
            at: terraform, displayName: "Terraform", expectedSizeBytes: 4096, route: .cache
        )

        #expect(asked.all == [terraform.standardizedFileURL.path])
        #expect(trash.trashedPaths.isEmpty)
        #expect(outcome == .failed(.safetySkipped))
    }

    /// The check lets every other row through, so a clean that passes it moves.
    @Test func aRowTheMoveCheckAllowsMoves() async throws {
        let folders = RealHomeFolders()
        defer { folders.remove() }
        let terraform = try terraformFolder(folders)
        let trash = FakeTrash()
        let report = try await FileDeleter(trash: trash.trash).deleteItems(at: [terraform])
        #expect(trash.trashedPaths == [terraform.standardizedFileURL.path])
        #expect(report.skippedItems.isEmpty)
    }
}
