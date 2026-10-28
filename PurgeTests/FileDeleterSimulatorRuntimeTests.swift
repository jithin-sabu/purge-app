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

    private func deleteRuntime(
        with deleter: FileDeleter,
        title: String = "iOS 26.3.1 Runtime",
        listedBytes: Int64 = 8_393_503_393
    ) async throws -> DeletionReport {
        let key = mount.standardizedFileURL.path
        return try await deleter.deleteItems(
            at: [mount],
            pathToDisplayName: [key: title],
            pathToExpectedSizeBytes: [key: listedBytes],
            simulatorRuntimeIDsByPath: [key: identifier]
        )
    }

    @Test func removedRuntimeCountsAsRemovedDirectly() async throws {
        let recorder = Recorder()
        let deleter = FileDeleter(simulatorRuntimeRemover: { id in
            recorder.record(id)
            return .removed(freedBytes: nil, keptDownloadBytes: nil)
        })
        let report = try await deleteRuntime(with: deleter)

        #expect(recorder.asked == [identifier])
        // No settled reading, and no download left behind: the listed size stands.
        #expect(report.bytesRemovedDirectly == 8_393_503_393)
        #expect(report.bytesMovedToTrash == 0)
        #expect(report.movedToTrashCount == 0)
        let item = try #require(report.deletedItems.first)
        #expect(item.movedToTrash == false)
        #expect(item.displayName == "iOS 26.3.1 Runtime")
        #expect(item.path == mount.path)
        #expect(report.failedItems.isEmpty)
        #expect(report.skippedItems.isEmpty)
        #expect(report.keptRuntimeDownloads.isEmpty)
    }

    /// iOS 26.3.1 listed 8.4 GB and freed 12.5 GB, because Apple removed its
    /// download too. The record says what the volume gave back.
    @Test func measuredGainReplacesTheListedSize() async throws {
        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in
            .removed(freedBytes: 12_500_000_000, keptDownloadBytes: nil)
        })
        let report = try await deleteRuntime(with: deleter)

        #expect(report.bytesRemovedDirectly == 12_500_000_000)
        #expect(report.deletedItems.map(\.sizeBytes) == [12_500_000_000])
        #expect(report.keptRuntimeDownloads.isEmpty)
    }

    /// The #165 case: iOS 18.4 listed 8.8 GB, and its image stayed inside the
    /// download Apple kept. Nothing measurable came back, so nothing is claimed.
    @Test func aKeptDownloadIsNeverCountedAtTheListedSize() async throws {
        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in
            .removed(freedBytes: nil, keptDownloadBytes: 9_116_354_048)
        })
        let report = try await deleteRuntime(with: deleter, title: "iOS 18.4 Runtime", listedBytes: 8_825_558_354)

        #expect(report.bytesRemovedDirectly == 0)
        #expect(report.deletedItems.map(\.sizeBytes) == [0])
        #expect(report.keptRuntimeDownloads == [KeptRuntimeDownload(displayName: "iOS 18.4 Runtime", bytes: 9_116_354_048)])
    }

    /// A first delete can free the runtime's dyld cache while the download stays:
    /// 3.7 GB of the 8.8 GB listed on 2026-10-09.
    @Test func whatWasFreedBesideAKeptDownloadIsWhatCounts() async throws {
        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in
            .removed(freedBytes: 3_700_000_000, keptDownloadBytes: 9_116_354_048)
        })
        let report = try await deleteRuntime(with: deleter, title: "iOS 18.4 Runtime", listedBytes: 8_825_558_354)

        #expect(report.bytesRemovedDirectly == 3_700_000_000)
        #expect(report.keptRuntimeDownloads.map(\.bytes) == [9_116_354_048])
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
            return .removed(freedBytes: nil, keptDownloadBytes: nil)
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
            return .removed(freedBytes: nil, keptDownloadBytes: nil)
        })
        let result = await deleter.retryDeleteItem(
            at: mount,
            displayName: "iOS 26.3.1 Runtime",
            expectedSizeBytes: 42,
            route: .cache,
            simulatorRuntimeID: identifier
        )

        #expect(recorder.asked == [identifier])
        // Removed outright, so the row is never counted as moved to the Trash.
        #expect(result == .deleted(bytes: 42, movedToTrash: false, remaining: []))
    }

    // MARK: - The remover (#165)

    /// A fake simctl. `runtime list` names the runtime until `runtime delete` runs;
    /// the delete can also remove a folder, the way Apple removes a newer runtime's
    /// download.
    private final class FakeRuntimeSimctl: @unchecked Sendable {
        private let lock = NSLock()
        private var deleted = false
        private var recorded: [[String]] = []
        let identifier: String
        let build: String
        let deleteStatus: Int32
        let removedOnDelete: URL?

        init(identifier: String, build: String, deleteStatus: Int32 = 0, removedOnDelete: URL? = nil) {
            self.identifier = identifier
            self.build = build
            self.deleteStatus = deleteStatus
            self.removedOnDelete = removedOnDelete
        }

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func run(_ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output? {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(arguments)
            if arguments.starts(with: ["runtime", "delete"]) {
                guard deleteStatus == 0 else {
                    return ProcessRunner.Output(status: deleteStatus, stdout: Data(), stderr: Data("Unable to delete".utf8), timedOut: false)
                }
                deleted = true
                if let removedOnDelete { try? FileManager.default.removeItem(at: removedOnDelete) }
                return ProcessRunner.Output(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
            }
            let listing = deleted
                ? "{}"
                : #"{"\#(identifier)": {"build": "\#(build)", "kind": "Cryptex Disk Image", "deletable": true}}"#
            return ProcessRunner.Output(status: 0, stdout: Data(listing.utf8), stderr: Data(), timedOut: false)
        }
    }

    /// Free-space readings in order; the last one repeats.
    private final class FakeVolume: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [Int64]

        init(_ readings: [Int64]) { self.readings = readings }

        func read() -> Int64? {
            lock.lock()
            defer { lock.unlock() }
            return readings.count > 1 ? readings.removeFirst() : readings.first
        }
    }

    private func remove(
        _ simctl: FakeRuntimeSimctl,
        assets: FakeAssetsV2,
        volume: FakeVolume
    ) async -> SimulatorRuntimeRemoval {
        await FileDeleter.removeSimulatorRuntime(
            identifier: simctl.identifier,
            runSimctl: { simctl.run($0, $1) },
            assetsRoot: assets.root,
            readAvailableBytes: { volume.read() },
            pollInterval: 0,
            settleInterval: .zero
        )
    }

    /// The issue's own test: an older runtime whose download stays is never
    /// reported as freeing its full size, and the result says the download stayed.
    @Test func olderRuntimeWhoseDownloadStaysClaimsNothing() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let download = try assets.addDownload(build: "22E238")
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "22E238")
        // 1 MB more free space: under the noise floor, so nothing can be claimed.
        let volume = FakeVolume([100_000_000_000, 100_001_000_000])

        let removal = await remove(simctl, assets: assets, volume: volume)
        guard case .removed(let freedBytes, let keptDownloadBytes) = removal else {
            Issue.record("expected the runtime to be removed, got \(removal)")
            return
        }
        #expect(freedBytes == nil)
        #expect((keptDownloadBytes ?? 0) > 0)
        #expect(simctl.calls.contains(["runtime", "delete", identifier]))
        // Purge only reads AssetsV2: the download is Apple's to remove.
        #expect(FileManager.default.fileExists(atPath: download.appendingPathComponent("Info.plist").path))
        #expect(simctl.calls.allSatisfy { $0 == ["runtime", "list", "-j"] || $0 == ["runtime", "delete", identifier] })

        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in removal })
        let report = try await deleteRuntime(with: deleter, title: "iOS 18.4 Runtime", listedBytes: 8_825_558_354)
        #expect(report.bytesRemovedDirectly == 0)
        #expect(report.keptRuntimeDownloads.map(\.displayName) == ["iOS 18.4 Runtime"])
    }

    @Test func runtimeWhoseDownloadGoesRecordsWhatTheVolumeGaveBack() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let download = try assets.addDownload(build: "23D8133")
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "23D8133", removedOnDelete: download)
        let volume = FakeVolume([100_000_000_000, 112_500_000_000])

        let removal = await remove(simctl, assets: assets, volume: volume)

        #expect(removal == .removed(freedBytes: 12_500_000_000, keptDownloadBytes: nil))
        #expect(!FileManager.default.fileExists(atPath: download.path))
    }

    /// A runtime added from a disk image has no Apple download to keep.
    @Test func runtimeWithNoDownloadReportsNoneKept() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        try assets.addDownload(build: "22E238")
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "21A328")
        let volume = FakeVolume([100_000_000_000, 108_000_000_000])

        let removal = await remove(simctl, assets: assets, volume: volume)

        #expect(removal == .removed(freedBytes: 8_000_000_000, keptDownloadBytes: nil))
    }

    @Test func refusedDeleteKeepsSimctlsWords() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "22E238", deleteStatus: 1)
        let volume = FakeVolume([100_000_000_000])

        let removal = await remove(simctl, assets: assets, volume: volume)

        #expect(removal == .failed("Unable to delete"))
    }
}
