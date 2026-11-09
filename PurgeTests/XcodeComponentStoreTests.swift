import Foundation
import Testing
@testable import Purge

/// The Metal Toolchain row rides the Dev Tools scan and the manual clean, and
/// stays out of the one-click safe clean: `xcodebuild` deletes it permanently,
/// which is not a trash move (#132). Nothing here runs a real `xcodebuild`.
@MainActor
@Suite("Xcode component store rows")
struct XcodeComponentStoreTests {
    private static let assetURL = URL(
        fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/389a215aea89fda945178f9fb8bcdc6aa0e20570.asset",
        isDirectory: true
    )

    private func toolchain(level: SafetyLevel? = nil) -> XcodeComponent {
        var safety = XcodeComponent.safetyInfo(kind: .metalToolchain, sizeBytes: 923_582_464)
        if let level {
            safety = SafetyInfo(
                level: level,
                headline: safety.headline,
                explanation: safety.explanation,
                recoverySteps: safety.recoverySteps,
                reinstallCommand: safety.reinstallCommand
            )
        }
        return XcodeComponent(kind: .metalToolchain, build: "27A266a", assetURL: Self.assetURL, sizeBytes: 923_582_464, safetyInfo: safety)
    }

    @Test func scanPublishesTheRow() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.developerEvents = [.xcodeComponentFound(toolchain())]
        let store = scans.makeStore()
        #expect(!store.hasLiveDevToolsRows)

        await store.scanDeveloper()

        #expect(store.xcodeComponents.map(\.kind) == [.metalToolchain])
        #expect(store.devToolsTotals.count == 1)
        #expect(store.devToolsTotals.bytes == 923_582_464)
        #expect(store.hasLiveDevToolsRows)
    }

    @Test func selectedRowBecomesAPermanentCandidate() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = toolchain()
        scans.developerEvents = [.xcodeComponentFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()

        store.setXcodeComponentSelected(id: row.id, isSelected: true)

        #expect(store.selectedCount == 1)
        #expect(store.selectedTotalBytes == 923_582_464)
        let candidate = try #require(store.deletionCandidates.first)
        #expect(candidate.path == Self.assetURL.standardizedFileURL)
        #expect(candidate.title == "Metal Toolchain")
        #expect(candidate.xcodeComponent == .metalToolchain)
        #expect(store.selectedDeveloperDeletionCandidates.map(\.path) == [candidate.path])
        // The confirm sheet lists it under "Deleted permanently" (#170).
        #expect(store.permanentlyDeletedCandidateIDs(in: [candidate]) == [candidate.id])

        store.setXcodeComponentSelected(id: row.id, isSelected: false)
        #expect(store.selectedCount == 0)
    }

    /// The safe clean and the scheduled clean only move things to the Trash. The
    /// row is never Safe; it is forced Safe here to prove the one-click clean
    /// skips it even so.
    @Test func safeRowStaysOutOfTheOneClickSafeClean() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.developerEvents = [.xcodeComponentFound(toolchain(level: .safe))]
        let store = scans.makeStore()
        await store.scanDeveloper()

        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    /// The Not Sure alert names `xcodebuild` for the toolchain, and does not
    /// claim `simctl` when no simulator is in the cleanup.
    @Test func notSureAlertNamesXcodebuild() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = toolchain()
        scans.developerEvents = [.xcodeComponentFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/PurgeXcodeComponentWording-\(UUID().uuidString)", isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: folder.path))
        let notSure = PurgeStore.DeletionCandidate(
            title: folder.lastPathComponent,
            path: folder,
            sizeBytes: 1,
            safetyInfo: SafetyInfo(level: .unknown, headline: "", explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .unknown
        )
        store.setXcodeComponentSelected(id: row.id, isSelected: true)
        let component = try #require(store.deletionCandidates.first)

        store.presentDeletionSheet(candidates: [notSure, component])
        store.userConfirmedDeletionFromPrimarySheet()
        try #require(store.showHighRiskDeletionSecondConfirm)
        let message = store.highRiskDeletionSecondConfirmMessage
        store.cancelHighRiskDeletionSecondStep()

        #expect(message.contains("deleted permanently through xcodebuild"))
        #expect(!message.contains("simctl"))
    }

    /// A clean hands the row to `xcodebuild`, counts it as deleted permanently,
    /// and drops the row.
    @Test func cleanRemovesItThroughTheComponentRemover() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = toolchain()
        scans.developerEvents = [.xcodeComponentFound(row)]
        let asked = Asked()
        let deleter = FileDeleter(xcodeComponentRemover: { kind, url in
            asked.add("\(kind.rawValue) \(url.path)")
            return .removed(freed: .gained(903_900_000))
        })
        let store = scans.makeStore(fileDeleter: deleter)
        await store.scanDeveloper()
        store.setXcodeComponentSelected(id: row.id, isSelected: true)

        store.presentDeletionSheet(candidates: store.deletionCandidates)
        store.userConfirmedDeletionFromPrimarySheet()
        for _ in 0..<500 where store.manualDeletionSession?.phase != .complete {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let session = try #require(store.manualDeletionSession)

        #expect(session.phase == .complete)
        #expect(asked.values == ["metalToolchain \(Self.assetURL.path)"])
        #expect(session.removedPermanentlyCount == 1)
        #expect(session.finalBytesMovedToTrash == 903_900_000)
        #expect(store.xcodeComponents.isEmpty)
        #expect(store.selectedCount == 0)
    }

    /// The first delete fails (say `-deleteComponent` timed out), then finishes in
    /// the background. Retry drops the row and books nothing (#340 review).
    @Test func retryAfterTheToolchainWentDropsTheRow() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = toolchain()
        scans.developerEvents = [.xcodeComponentFound(row)]
        let attempts = Asked()
        let deleter = FileDeleter(xcodeComponentRemover: { kind, _ in
            attempts.add(kind.rawValue)
            return attempts.values.count == 1 ? .failed("xcodebuild -deleteComponent timed out after 180s") : .alreadyGone
        })
        let store = scans.makeStore(fileDeleter: deleter)
        await store.scanDeveloper()
        store.setXcodeComponentSelected(id: row.id, isSelected: true)
        store.presentDeletionSheet(candidates: store.deletionCandidates)
        store.userConfirmedDeletionFromPrimarySheet()
        for _ in 0..<500 where store.manualDeletionSession?.phase != .complete {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let session = try #require(store.manualDeletionSession)
        let failure = try #require(session.failedItems.first)
        #expect(store.xcodeComponents.count == 1)

        let bytes = await store.retryCleanFailure(failure, session: session)

        #expect(bytes == nil)
        #expect(attempts.values.count == 2)
        #expect(session.failedItems.isEmpty)
        #expect(store.xcodeComponents.isEmpty)
    }

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []

        func add(_ value: String) { lock.withLock { list.append(value) } }
        var values: [String] { lock.withLock { list } }
    }
}
