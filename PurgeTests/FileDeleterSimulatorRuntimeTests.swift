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

    private static let older = "Cryptex Disk Image"
    private static let newer = "Patchable Cryptex Disk Image"

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

    private func report(for removal: SimulatorRuntimeRemoval, listedBytes: Int64 = 8_393_503_393) async throws -> DeletionReport {
        try await deleteRuntime(with: FileDeleter(simulatorRuntimeRemover: { _ in removal }), listedBytes: listedBytes)
    }

    @Test func removedRuntimeCountsAsRemovedDirectly() async throws {
        let recorder = Recorder()
        let deleter = FileDeleter(simulatorRuntimeRemover: { id in
            recorder.record(id)
            return .removed(freed: .unknown, download: .notKept, isLegacyImage: false)
        })
        let report = try await deleteRuntime(with: deleter)

        #expect(recorder.asked == [identifier])
        // A newer runtime whose download is gone, with no settled reading: its
        // image was that download, so the listed size stands.
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
        let report = try await report(for: .removed(freed: .gained(12_500_000_000), download: .notKept, isLegacyImage: false))

        #expect(report.bytesRemovedDirectly == 12_500_000_000)
        #expect(report.deletedItems.map(\.sizeBytes) == [12_500_000_000])
        #expect(report.keptRuntimeDownloads.isEmpty)
    }

    /// A reading that settled under the noise floor is a measured "nothing came
    /// back", not a missing reading, so the listed size never stands in for it.
    @Test func aGainUnderTheNoiseFloorBooksNothing() async throws {
        let report = try await report(for: .removed(freed: .belowNoiseFloor, download: .notKept, isLegacyImage: false))

        #expect(report.bytesRemovedDirectly == 0)
        #expect(report.deletedItems.map(\.sizeBytes) == [0])
    }

    /// The #165 case: the image stayed inside the download Apple kept. Nothing
    /// measurable came back, so nothing is claimed, and the result says why.
    @Test func aKeptDownloadIsNeverCountedAtTheListedSize() async throws {
        let report = try await report(for: .removed(freed: .unknown, download: .kept(bytes: 9_116_354_048), isLegacyImage: false))

        #expect(report.bytesRemovedDirectly == 0)
        #expect(report.deletedItems.map(\.sizeBytes) == [0])
        let kept = try #require(report.keptRuntimeDownloads.first)
        #expect(kept == KeptRuntimeDownload(displayName: "iOS 26.3.1 Runtime", bytes: 9_116_354_048))
        #expect(kept.note == "macOS kept the iOS 26.3.1 Runtime download (\(formatBytes(9_116_354_048))), so that space is still in use.")
    }

    /// `du` gave no size, and the folder is still there: the note says so
    /// without a size instead of claiming 0 bytes.
    @Test func aKeptDownloadThatCouldNotBeMeasuredHasNoSize() async throws {
        let report = try await report(for: .removed(freed: .unknown, download: .kept(bytes: nil), isLegacyImage: false))

        #expect(report.bytesRemovedDirectly == 0)
        #expect(report.keptRuntimeDownloads.map(\.note) == [
            "macOS kept the iOS 26.3.1 Runtime download, so that space is still in use."
        ])
    }

    /// When the runtime list or AssetsV2 could not be read, "no download" can't be
    /// told from "Apple kept it", so nothing is claimed without a reading.
    @Test func anUnknownDownloadBooksNothingWithoutAReading() async throws {
        let report = try await report(for: .removed(freed: .unknown, download: .unknown, isLegacyImage: false))

        #expect(report.bytesRemovedDirectly == 0)
        #expect(report.keptRuntimeDownloads.isEmpty)
    }

    /// An older runtime's image may still sit in a download the build match
    /// missed, so without a reading it books nothing either.
    @Test func anOlderRuntimeBooksNothingWithoutAReading() async throws {
        let report = try await report(for: .removed(freed: .unknown, download: .notKept, isLegacyImage: true), listedBytes: 8_825_558_354)

        #expect(report.bytesRemovedDirectly == 0)
    }

    /// A first delete can free the runtime's dyld cache while the download stays:
    /// 3.7 GB of the 8.8 GB listed on 2026-10-09.
    @Test func whatWasFreedBesideAKeptDownloadIsWhatCounts() async throws {
        let report = try await report(for: .removed(freed: .gained(3_700_000_000), download: .kept(bytes: 9_116_354_048), isLegacyImage: false))

        #expect(report.bytesRemovedDirectly == 3_700_000_000)
        #expect(report.keptRuntimeDownloads.map(\.bytes) == [9_116_354_048])
    }

    /// The remover's own gate refused it: skipped for safety, with no Retry, as
    /// every other gate's refusal is.
    @Test func refusedRuntimeIsSkippedForSafety() async throws {
        let report = try await report(for: .refused("older runtime mounted from Apple's download of build 22E238"))

        #expect(report.deletedItems.isEmpty)
        #expect(report.failedItems.isEmpty)
        #expect(report.bytesRemovedDirectly == 0)
        let skipped = try #require(report.skippedItems.first)
        #expect(skipped.path == mount.path)
        #expect(skipped.isUserVisible)
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
            return .removed(freed: .unknown, download: .notKept, isLegacyImage: false)
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
            return .removed(freed: .unknown, download: .notKept, isLegacyImage: false)
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

    /// A retry that removes the runtime while Apple keeps its download carries
    /// that back, so the completion screen can say so as the clean does.
    @Test func retryCarriesAKeptDownload() async {
        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in
            .removed(freed: .unknown, download: .kept(bytes: 9_116_354_048), isLegacyImage: false)
        })
        let result = await deleter.retryDeleteItem(
            at: mount,
            displayName: "iOS 26.3.1 Runtime",
            expectedSizeBytes: 8_393_503_393,
            route: .cache,
            simulatorRuntimeID: identifier
        )

        #expect(result == .deleted(
            bytes: 0,
            movedToTrash: false,
            remaining: [],
            keptRuntimeDownloads: [KeptRuntimeDownload(displayName: "iOS 26.3.1 Runtime", bytes: 9_116_354_048)]
        ))
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
        let kind: String
        let listReadable: Bool
        let deleteStatus: Int32
        let removedOnDelete: URL?

        init(
            identifier: String,
            build: String,
            kind: String,
            listReadable: Bool = true,
            deleteStatus: Int32 = 0,
            removedOnDelete: URL? = nil
        ) {
            self.identifier = identifier
            self.build = build
            self.kind = kind
            self.listReadable = listReadable
            self.deleteStatus = deleteStatus
            self.removedOnDelete = removedOnDelete
        }

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var deleteWasCalled: Bool {
            calls.contains { $0.starts(with: ["runtime", "delete"]) }
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
            guard listReadable else {
                return ProcessRunner.Output(status: 0, stdout: Data(), stderr: Data(), timedOut: true)
            }
            let listing = deleted
                ? "{}"
                : #"{"\#(identifier)": {"build": "\#(build)", "kind": "\#(kind)", "deletable": true}}"#
            return ProcessRunner.Output(status: 0, stdout: Data(listing.utf8), stderr: Data(), timedOut: false)
        }
    }

    /// Free-space readings in order; the last one repeats. `moving` adds 1 GB to
    /// every reading after the first, so the figure never settles.
    private final class FakeVolume: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [Int64]
        private var drift: Int64 = 0
        let moving: Bool

        init(_ readings: [Int64], moving: Bool = false) {
            self.readings = readings
            self.moving = moving
        }

        func read() -> Int64? {
            lock.lock()
            defer { lock.unlock() }
            let reading = readings.count > 1 ? readings.removeFirst() : readings[0]
            defer { if moving { drift += 1_000_000_000 } }
            return reading + drift
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

    /// The scan's rule, checked again right before the delete: an older runtime
    /// whose download Apple keeps is never handed to `runtime delete`, whatever
    /// case or spacing the two build strings use. Purge only reads AssetsV2.
    @Test func olderRuntimeInAnAppleDownloadIsRefusedBeforeTheDelete() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let download = try assets.addDownload(build: "22E238")
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: " 22e238", kind: Self.older)

        let removal = await remove(simctl, assets: assets, volume: FakeVolume([100_000_000_000]))

        guard case .refused = removal else {
            Issue.record("expected a refusal, got \(removal)")
            return
        }
        #expect(!simctl.deleteWasCalled)
        #expect(FileManager.default.fileExists(atPath: download.appendingPathComponent("Info.plist").path))
    }

    /// Unknown is never "no download": with AssetsV2 unreadable, an older runtime
    /// is refused, as the scan would have left it out.
    @Test func olderRuntimeIsRefusedWhenAssetsV2CannotBeRead() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        try assets.addDownload(build: nil)
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "21A328", kind: Self.older)

        let removal = await remove(simctl, assets: assets, volume: FakeVolume([100_000_000_000]))

        guard case .refused = removal else {
            Issue.record("expected a refusal, got \(removal)")
            return
        }
        #expect(!simctl.deleteWasCalled)
    }

    /// A list that can't be read gives no build to check, so nothing is deleted.
    @Test func anUnreadableListIsAFailureBeforeTheDelete() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "23D8133", kind: Self.newer, listReadable: false)

        let removal = await remove(simctl, assets: assets, volume: FakeVolume([100_000_000_000]))

        guard case .failed = removal else {
            Issue.record("expected a failure, got \(removal)")
            return
        }
        #expect(!simctl.deleteWasCalled)
    }

    /// A download that stays is never counted at the runtime's listed size, and
    /// the result says it stayed. Purge leaves it where it is.
    @Test func runtimeWhoseDownloadStaysClaimsNothing() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let download = try assets.addDownload(build: "23D8133")
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "23D8133", kind: Self.newer)
        // 1 MB more free space: under the noise floor, so nothing can be claimed.
        let volume = FakeVolume([100_000_000_000, 100_001_000_000])

        let removal = await remove(simctl, assets: assets, volume: volume)
        guard case .removed(let freed, .kept(let bytes), false) = removal else {
            Issue.record("expected a removal with the download kept, got \(removal)")
            return
        }
        #expect(freed == .belowNoiseFloor)
        #expect((bytes ?? 0) > 0)
        #expect(FileManager.default.fileExists(atPath: download.appendingPathComponent("Info.plist").path))
        #expect(simctl.calls.allSatisfy { $0 == ["runtime", "list", "-j"] || $0 == ["runtime", "delete", identifier] })

        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in removal })
        let report = try await deleteRuntime(with: deleter)
        #expect(report.bytesRemovedDirectly == 0)
        #expect(report.keptRuntimeDownloads.map(\.displayName) == ["iOS 26.3.1 Runtime"])
    }

    @Test func runtimeWhoseDownloadGoesRecordsWhatTheVolumeGaveBack() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let download = try assets.addDownload(build: "23D8133")
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "23D8133", kind: Self.newer, removedOnDelete: download)
        let volume = FakeVolume([100_000_000_000, 112_500_000_000])

        let removal = await remove(simctl, assets: assets, volume: volume)

        #expect(removal == .removed(freed: .gained(12_500_000_000), download: .notKept, isLegacyImage: false))
        #expect(!FileManager.default.fileExists(atPath: download.path))
    }

    /// An older runtime added from a disk image has no Apple download, so the
    /// gate lets it through.
    @Test func olderRuntimeWithNoDownloadIsRemoved() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        try assets.addDownload(build: "22E238")
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "21A328", kind: Self.older)
        let volume = FakeVolume([100_000_000_000, 108_000_000_000])

        let removal = await remove(simctl, assets: assets, volume: volume)

        #expect(removal == .removed(freed: .gained(8_000_000_000), download: .notKept, isLegacyImage: true))
        #expect(simctl.deleteWasCalled)
    }

    /// A newer runtime with AssetsV2 unreadable is still removed, but what became
    /// of its download is unknown, and with a reading that never settles nothing
    /// is booked.
    @Test func unreadableAssetsV2LeavesTheDownloadUnknown() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        try assets.addDownload(build: nil)
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "23D8133", kind: Self.newer)
        let volume = FakeVolume([100_000_000_000], moving: true)

        let removal = await remove(simctl, assets: assets, volume: volume)

        #expect(removal == .removed(freed: .unknown, download: .unknown, isLegacyImage: false))
        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in removal })
        let report = try await deleteRuntime(with: deleter)
        #expect(report.bytesRemovedDirectly == 0)
    }

    @Test func failedDeleteKeepsSimctlsWords() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let simctl = FakeRuntimeSimctl(identifier: identifier, build: "23D8133", kind: Self.newer, deleteStatus: 1)

        let removal = await remove(simctl, assets: assets, volume: FakeVolume([100_000_000_000]))

        #expect(removal == .failed("Unable to delete"))
    }
}
