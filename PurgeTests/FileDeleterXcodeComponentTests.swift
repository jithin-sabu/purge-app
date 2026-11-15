import Foundation
import Testing
@testable import Purge

/// An Xcode component row's path is Apple's asset store. The engine must hand it
/// to `xcodebuild` and never to the trash policy, count it as removed outright,
/// and the gate must check again from disk right before the delete (#132).
@Suite("FileDeleter Xcode components")
struct FileDeleterXcodeComponentTests {
    private let asset = URL(
        fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/389a215aea89fda945178f9fb8bcdc6aa0e20570.asset",
        isDirectory: true
    )
    private static let listed: Int64 = 923_582_464

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var asked: [(XcodeComponent.Kind, String)] = []
        func record(_ kind: XcodeComponent.Kind, _ url: URL) {
            lock.withLock { asked.append((kind, url.path)) }
        }
    }

    private func delete(with deleter: FileDeleter, mapped: Bool = true) async throws -> DeletionReport {
        let key = asset.standardizedFileURL.path
        return try await deleter.deleteItems(
            at: [asset],
            pathToDisplayName: [key: "Metal Toolchain"],
            pathToExpectedSizeBytes: [key: Self.listed],
            xcodeComponentsByPath: mapped ? [key: .metalToolchain] : [:]
        )
    }

    private func report(for removal: XcodeComponentRemoval) async throws -> DeletionReport {
        try await delete(with: FileDeleter(xcodeComponentRemover: { _, _ in removal }))
    }

    // MARK: Engine

    @Test func removedComponentCountsAsRemovedDirectly() async throws {
        let recorder = Recorder()
        let deleter = FileDeleter(xcodeComponentRemover: { kind, url in
            recorder.record(kind, url)
            return .removed(freed: .gained(903_900_000))
        })

        let report = try await delete(with: deleter)

        #expect(recorder.asked.map(\.0) == [.metalToolchain])
        #expect(recorder.asked.map(\.1) == [asset.path])
        // What the volume gave back, not the scan's size.
        #expect(report.bytesRemovedDirectly == 903_900_000)
        #expect(report.bytesMovedToTrash == 0)
        #expect(report.movedToTrashCount == 0)
        let item = try #require(report.deletedItems.first)
        #expect(item.movedToTrash == false)
        #expect(item.displayName == "Metal Toolchain")
        #expect(report.failedItems.isEmpty && report.skippedItems.isEmpty)
    }

    /// With no settled reading the scan's size stands, since the gate saw the
    /// asset folder go. A gain under the noise floor books nothing.
    @Test func bookedBytesFollowTheVolume() async throws {
        #expect(try await report(for: .removed(freed: .unknown)).bytesRemovedDirectly == Self.listed)
        #expect(try await report(for: .removed(freed: .belowNoiseFloor)).bytesRemovedDirectly == 0)
    }

    @Test func refusedIsSkippedForSafety() async throws {
        let report = try await report(for: .refused("no Xcode to run xcodebuild from"))

        #expect(report.deletedItems.isEmpty && report.failedItems.isEmpty)
        let skipped = try #require(report.skippedItems.first)
        #expect(skipped.isUserVisible)
    }

    /// Gone before Purge asked: nothing is deleted, skipped or failed, so the
    /// clean books nothing and a Retry reads it as gone.
    @Test func alreadyGoneRecordsNothing() async throws {
        let report = try await report(for: .alreadyGone)

        #expect(report.deletedItems.isEmpty)
        #expect(report.skippedItems.isEmpty)
        #expect(report.failedItems.isEmpty)
        #expect(report.bytesRemovedDirectly == 0)
    }

    @Test func failedOffersRetry() async throws {
        let report = try await report(for: .failed("xcodebuild: error"))

        #expect(report.deletedItems.isEmpty)
        let failed = try #require(report.failedItems.first)
        #expect(failed.sizeBytes == Self.listed)
        #expect(report.movedNothingAndFailed)
    }

    /// The asset path without its handle reaches the trash policy, which refuses
    /// a path under /System. Nothing is moved and `xcodebuild` is never asked.
    @Test func unmappedAssetPathIsRefusedByThePolicy() async throws {
        let recorder = Recorder()
        let trash = FakeTrash()
        let deleter = FileDeleter(
            xcodeComponentRemover: { kind, url in
                recorder.record(kind, url)
                return .removed(freed: .unknown)
            },
            trash: trash.trash
        )

        let report = try await delete(with: deleter, mapped: false)

        #expect(recorder.asked.isEmpty)
        #expect(trash.trashedPaths.isEmpty)
        #expect(report.deletedItems.isEmpty)
    }

    @Test func confirmationsCountItAsPermanent() {
        #expect(FileDeleter.removesDirectly(asset, simulatorRuntimePaths: [], xcodeComponentPaths: [asset.standardizedFileURL.path]))
        #expect(!FileDeleter.removesDirectly(asset, simulatorRuntimePaths: []))
    }

    @Test func retryGoesBackToXcodebuild() async throws {
        let recorder = Recorder()
        let deleter = FileDeleter(xcodeComponentRemover: { kind, url in
            recorder.record(kind, url)
            return .removed(freed: .gained(903_900_000))
        })

        let outcome = await deleter.retryDeleteItem(
            at: asset,
            displayName: "Metal Toolchain",
            expectedSizeBytes: Self.listed,
            route: .cache,
            xcodeComponent: .metalToolchain
        )

        #expect(outcome == .deleted(bytes: 903_900_000, movedToTrash: false, remaining: []))
        #expect(recorder.asked.map(\.0) == [.metalToolchain])
    }

    /// A delete that timed out finished later, or another tool removed it. The
    /// Retry drops the row instead of showing "skipped for safety" with no Retry.
    @Test func retryAfterTheToolchainWentReadsAsGone() async throws {
        let deleter = FileDeleter(xcodeComponentRemover: { _, _ in .alreadyGone })

        let outcome = await deleter.retryDeleteItem(
            at: asset,
            displayName: "Metal Toolchain",
            expectedSizeBytes: Self.listed,
            route: .cache,
            xcodeComponent: .metalToolchain
        )

        #expect(outcome == .alreadyGone)
    }

    // MARK: The gate before the delete

    private func remove(
        _ xcodebuild: FakeXcodebuild?,
        expecting expected: URL,
        assets: FakeAssetsV2,
        readings: [Int64] = [10_000_000_000, 10_903_900_000],
        goneDeadline: TimeInterval = 5
    ) async -> XcodeComponentRemoval {
        let volume = FakeVolume(readings)
        return await FileDeleter.removeXcodeComponent(
            .metalToolchain,
            expectedAsset: expected,
            runXcodebuild: { xcodebuild?.run($0, $1) },
            assetsRoot: assets.root,
            readAvailableBytes: { volume.read() },
            pollInterval: 0,
            goneDeadline: goneDeadline,
            settleInterval: .zero
        )
    }

    private func installedToolchain(_ assets: FakeAssetsV2) throws -> URL {
        try assets.addDownload(build: nil, folder: XcodeComponent.Kind.metalToolchain.assetTypeFolderName)
    }

    @Test func deletesThroughXcodebuildAndWaitsForTheFolderToGo() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let folder = try installedToolchain(assets)
        let xcodebuild = FakeXcodebuild(asset: folder)

        let result = await remove(xcodebuild, expecting: folder, assets: assets)

        #expect(result == .removed(freed: .gained(903_900_000)))
        #expect(xcodebuild.deleteCalls == [["-deleteComponent", "metalToolchain"]])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// Xcode was deleted or swapped for the Command Line Tools since the scan.
    @Test func noXcodeIsRefused() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let folder = try installedToolchain(assets)

        let result = await remove(nil, expecting: folder, assets: assets)

        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func noLongerInstalledIsRefusedWithoutADelete() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let folder = try installedToolchain(assets)
        let xcodebuild = FakeXcodebuild(asset: folder, installed: false)

        let result = await remove(xcodebuild, expecting: folder, assets: assets)

        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(xcodebuild.deleteCalls.isEmpty)
    }

    /// A second download appeared since the scan. `-deleteComponent` takes no
    /// asset ID, so it could remove both: refused, and nothing is run.
    @Test func aSecondDownloadIsRefusedWithoutADelete() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let ticked = try installedToolchain(assets)
        _ = try installedToolchain(assets)
        let xcodebuild = FakeXcodebuild(asset: ticked)

        let result = await remove(xcodebuild, expecting: ticked, assets: assets)

        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(xcodebuild.deleteCalls.isEmpty)
    }

    /// Not listed and the ticked folder gone: already gone, and nothing is run.
    @Test func notInstalledAndFolderGoneIsAlreadyGone() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let folder = try installedToolchain(assets)
        try FileManager.default.removeItem(at: folder)
        let xcodebuild = FakeXcodebuild(asset: folder, installed: false)

        let result = await remove(xcodebuild, expecting: folder, assets: assets)

        #expect(result == .alreadyGone)
        #expect(xcodebuild.deleteCalls.isEmpty)
    }

    /// Xcode updated the toolchain since the scan: the ticked folder is gone but
    /// another one is listed. That is a different download, so still a refusal.
    @Test func aNewerDownloadAfterTheTickedOneWentIsRefused() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let ticked = try installedToolchain(assets)
        let current = try installedToolchain(assets)
        try FileManager.default.removeItem(at: ticked)
        let xcodebuild = FakeXcodebuild(asset: current)

        let result = await remove(xcodebuild, expecting: ticked, assets: assets)

        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(xcodebuild.deleteCalls.isEmpty)
    }

    /// A different download than the one the user ticked: Xcode updated the
    /// toolchain while the sheet was open.
    @Test func aDifferentDownloadIsRefusedWithoutADelete() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let ticked = try installedToolchain(assets)
        let current = try installedToolchain(assets)
        let xcodebuild = FakeXcodebuild(asset: current)

        let result = await remove(xcodebuild, expecting: ticked, assets: assets)

        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(xcodebuild.deleteCalls.isEmpty)
    }

    @Test func unreadableStatusFailsWithoutADelete() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let folder = try installedToolchain(assets)
        let xcodebuild = FakeXcodebuild(asset: folder)
        xcodebuild.showFails = true

        let result = await remove(xcodebuild, expecting: folder, assets: assets)

        guard case .failed = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(xcodebuild.deleteCalls.isEmpty)
    }

    @Test func nonZeroExitFails() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let folder = try installedToolchain(assets)
        let xcodebuild = FakeXcodebuild(asset: folder)
        xcodebuild.deleteStatus = 1

        let result = await remove(xcodebuild, expecting: folder, assets: assets)

        #expect(result == .failed("xcodebuild: error: Failed to delete component."))
    }

    /// Exit 0 is not trusted: a component still listed fails, and claims nothing.
    @Test func stillInstalledAfterExitZeroFails() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let folder = try installedToolchain(assets)
        let xcodebuild = FakeXcodebuild(asset: folder)
        xcodebuild.staysInstalled = true

        let result = await remove(xcodebuild, expecting: folder, assets: assets, goneDeadline: 0.2)

        guard case .failed = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
    }

    /// Free-space readings in order; the last one repeats.
    private final class FakeVolume: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [Int64]

        init(_ readings: [Int64]) { self.readings = readings }

        func read() -> Int64? {
            lock.withLock { readings.count > 1 ? readings.removeFirst() : readings[0] }
        }
    }
}
