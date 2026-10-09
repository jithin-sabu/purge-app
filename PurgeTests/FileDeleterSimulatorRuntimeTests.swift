import Foundation
import Testing
@testable import Purge

/// A runtime row's path is a root-owned mounted image. The engine must hand it to
/// CoreSimulator and never to the trash policy, and must count it as removed
/// outright, not as pending in the Trash.
@Suite("FileDeleter simulator runtimes")
struct FileDeleterSimulatorRuntimeTests {
    private let mount = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes/iOS_TEST1", isDirectory: true)
    private let identifier = "7AE1D6B6-5524-4FAD-B793-1D1C911E5269"

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var asked: [String] = []
        func record(_ id: String) {
            lock.lock(); asked.append(id); lock.unlock()
        }
    }

    @Test func removedRuntimeCountsAsRemovedDirectly() async throws {
        let recorder = Recorder()
        let deleter = FileDeleter(simulatorRuntimeRemover: { id in
            recorder.record(id)
            return .removed
        })
        let key = mount.standardizedFileURL.path
        let report = try await deleter.deleteItems(
            at: [mount],
            pathToDisplayName: [key: "iOS 26.3.1 Runtime"],
            pathToExpectedSizeBytes: [key: 8_393_503_393],
            simulatorRuntimeIDsByPath: [key: identifier]
        )

        #expect(recorder.asked == [identifier])
        #expect(report.bytesRemovedDirectly == 8_393_503_393)
        #expect(report.bytesMovedToTrash == 0)
        #expect(report.movedToTrashCount == 0)
        let item = try #require(report.deletedItems.first)
        #expect(item.movedToTrash == false)
        #expect(item.displayName == "iOS 26.3.1 Runtime")
        #expect(item.path == mount.path)
        #expect(report.failedItems.isEmpty)
        #expect(report.skippedItems.isEmpty)
    }

    @Test func failedRemovalIsReportedNotSkipped() async throws {
        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in .failed("runtime still listed after 180s") })
        let key = mount.standardizedFileURL.path
        let report = try await deleter.deleteItems(
            at: [mount],
            pathToExpectedSizeBytes: [key: 1_000],
            simulatorRuntimeIDsByPath: [key: identifier]
        )

        #expect(report.deletedItems.isEmpty)
        #expect(report.bytesRemovedDirectly == 0)
        let failed = try #require(report.failedItems.first)
        #expect(failed.path == mount.path)
        #expect(failed.sizeBytes == 1_000)
        #expect(failed.reason == .unknown)
    }

    /// Without the identifier the path is just a folder under /Library, which the
    /// allowlist has never offered. Nothing may touch it.
    @Test func mountPathWithoutAnIdentifierNeverReachesTheRemoverOrTheTrash() async throws {
        let recorder = Recorder()
        let deleter = FileDeleter(simulatorRuntimeRemover: { id in
            recorder.record(id)
            return .removed
        })
        let report = try await deleter.deleteItems(at: [mount])

        #expect(recorder.asked.isEmpty)
        #expect(report.deletedItems.isEmpty)
        #expect(report.failedItems.isEmpty)
    }

    @Test func retryPassesTheIdentifierThrough() async {
        let recorder = Recorder()
        let deleter = FileDeleter(simulatorRuntimeRemover: { id in
            recorder.record(id)
            return .removed
        })
        let result = await deleter.retryDeleteItem(
            at: mount,
            displayName: "iOS 26.3.1 Runtime",
            expectedSizeBytes: 42,
            simulatorRuntimeID: identifier
        )

        #expect(recorder.asked == [identifier])
        guard case .success(let bytes) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(bytes == 42)
    }
}
