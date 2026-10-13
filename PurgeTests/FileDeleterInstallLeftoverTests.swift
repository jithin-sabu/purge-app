import Foundation
import Testing
@testable import Purge

/// Leftover macOS update files are root-owned (#127). The engine must hand them to
/// the helper in one request and never try a plain Trash move. These paths don't
/// exist: the fake mover never touches the disk, and the policy reads paths only.
@Suite("FileDeleter macOS install leftovers")
struct FileDeleterInstallLeftoverTests {
    private let bundle = MacOSInstallLeftovers.root.appendingPathComponent("UpdateBundle", isDirectory: true)
    private let info = MacOSInstallLeftovers.root.appendingPathComponent("InstallInfo.plist")

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var requests: [[String]] = []
        func record(_ urls: [URL]) {
            lock.lock(); requests.append(urls.map(\.path)); lock.unlock()
        }
    }

    private func deleter(
        recorder: Recorder,
        ruleHolds: Bool = true,
        result: @escaping @Sendable ([URL]) -> PrivilegedMoveResult
    ) -> FileDeleter {
        FileDeleter(
            privilegedMover: { urls in
                recorder.record(urls)
                return result(urls)
            },
            installLeftoverRule: { ruleHolds }
        )
    }

    private func sizes(_ urls: [URL], bytes: Int64) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: urls.map { ($0.standardizedFileURL.path, bytes) })
    }

    @Test func movedEntriesAreCreditedFromOneRequest() async throws {
        let recorder = Recorder()
        let deleter = deleter(recorder: recorder) { urls in
            PrivilegedMoveResult(moved: urls, failed: [], indeterminate: [], ownershipIncomplete: [urls[1]])
        }
        let report = try await deleter.deleteItems(
            at: [bundle, info],
            pathToDisplayName: [bundle.path: "Leftover macOS update files"],
            pathToExpectedSizeBytes: sizes([bundle, info], bytes: 600)
        )

        #expect(recorder.requests == [[bundle.path, info.path]])
        #expect(report.bytesMovedToTrash == 1_200)
        #expect(report.movedToTrashCount == 2)
        #expect(report.deletedItems.first?.displayName == "Leftover macOS update files")
        #expect(report.ownershipWarningPaths == [info.path])
        #expect(report.failedItems.isEmpty)
        #expect(report.skippedItems.isEmpty)
    }

    @Test func helperOffIsOneTimeSetup() async throws {
        let recorder = Recorder()
        let deleter = deleter(recorder: recorder) { urls in
            PrivilegedMoveResult(moved: [], failed: urls, indeterminate: [], helperAvailable: false)
        }
        let report = try await deleter.deleteItems(at: [bundle], pathToExpectedSizeBytes: sizes([bundle], bytes: 900))

        #expect(report.deletedItems.isEmpty)
        let failed = try #require(report.failedItems.first)
        #expect(failed.reason == .needsAdministrator)
        #expect(failed.sizeBytes == 900)
        #expect(report.failedItems.count == 1)
    }

    @Test func helperThatTriedAndFailedOffersRetry() async throws {
        let recorder = Recorder()
        let deleter = deleter(recorder: recorder) { urls in
            PrivilegedMoveResult(moved: [], failed: urls, indeterminate: [])
        }
        let report = try await deleter.deleteItems(at: [bundle], pathToExpectedSizeBytes: sizes([bundle], bytes: 900))

        #expect(report.failedItems.map(\.reason) == [.unknown])
    }

    /// The helper timed out but the entry is gone from disk, so the move landed.
    @Test func indeterminateEntryThatIsGoneCountsAsMoved() async throws {
        let recorder = Recorder()
        let deleter = deleter(recorder: recorder) { urls in
            PrivilegedMoveResult(moved: [], failed: [], indeterminate: urls)
        }
        let report = try await deleter.deleteItems(at: [bundle], pathToExpectedSizeBytes: sizes([bundle], bytes: 900))

        #expect(report.bytesMovedToTrash == 900)
        #expect(report.failedItems.isEmpty)
    }

    /// An update downloaded since the scan: nothing is sent to the helper.
    @Test func waitingUpdateIsSkippedAndNeverSent() async throws {
        let recorder = Recorder()
        let deleter = deleter(recorder: recorder, ruleHolds: false) { urls in
            PrivilegedMoveResult(moved: urls, failed: [], indeterminate: [])
        }
        let report = try await deleter.deleteItems(at: [bundle, info], pathToExpectedSizeBytes: sizes([bundle, info], bytes: 1))

        #expect(recorder.requests.isEmpty)
        #expect(report.deletedItems.isEmpty)
        #expect(report.skippedItems.count == 2)
        #expect(report.skippedItems.allSatisfy { $0.isUserVisible })
    }

    /// The folder and `Locked Files` are not entries: neither reaches the helper.
    @Test func folderAndLockedFilesNeverReachTheHelper() async throws {
        let recorder = Recorder()
        let deleter = deleter(recorder: recorder) { urls in
            PrivilegedMoveResult(moved: urls, failed: [], indeterminate: [])
        }
        let locked = MacOSInstallLeftovers.root.appendingPathComponent("Locked Files", isDirectory: true)
        let report = try await deleter.deleteItems(
            at: [MacOSInstallLeftovers.root, locked],
            pathToExpectedSizeBytes: sizes([MacOSInstallLeftovers.root, locked], bytes: 1)
        )

        #expect(recorder.requests.isEmpty)
        #expect(report.deletedItems.isEmpty)
    }

    /// A row the user overrode to Safe still never goes into a safe or scheduled
    /// clean: the helper moves these as root, so only when the user picks them.
    @Test @MainActor func leftoversNeverJoinSafeCleanup() {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        defer { fake.cleanUp() }
        func item(_ url: URL, key: String) -> CacheItem {
            CacheItem(
                definitionKey: key,
                location: CacheLocation(path: url, sizeBytes: 1_000_000, lastModified: .distantPast, folderName: key),
                appName: key,
                safetyInfo: SafetyInfo(level: .safe, headline: key, explanation: "", recoverySteps: "", reinstallCommand: nil),
                gitStatus: .clean
            )
        }
        let normal = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.purge.test.\(UUID().uuidString)")
        store.cacheItems = [
            item(bundle, key: CacheDiscoveryPaths.macOSInstallDataKey),
            item(normal, key: "normal")
        ]

        let paths = store.manualSafeCleanupCandidates().map(\.path.path)
        #expect(paths == [normal.standardizedFileURL.path])
    }
}
