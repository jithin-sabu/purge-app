import Foundation
import Testing
@testable import Purge

/// A confirmed clean that finds another clean running must not run beside it,
/// and must not close with nothing happening and no word (#173). Every path
/// here points at a folder that is never created, so nothing can move even if a
/// guard is missing.
@Suite("Confirmed clean while another clean runs")
@MainActor
struct ConfirmedCleanSingleFlightTests {
    private static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("purge-single-flight-\(UUID().uuidString)", isDirectory: true)

    private static let safeInfo = SafetyInfo(
        level: .safe, headline: "Cache", explanation: "", recoverySteps: "", reinstallCommand: nil
    )

    private static func candidate() -> PurgeStore.DeletionCandidate {
        PurgeStore.DeletionCandidate(
            title: "Cache",
            path: folder.appendingPathComponent("cache", isDirectory: true),
            sizeBytes: 1,
            safetyInfo: safeInfo,
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
    }

    // The delete confirmation sheet, confirmed while a clean holds `isDeleting`.
    // `executeStagedDeletion` had no guard at all, so the second clean ran beside
    // the first.
    @Test("A confirmed delete sheet during another clean is refused with a message")
    func confirmedDeleteSheetIsRefused() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.isDeleting = true
        store.deletionSheetCandidates = [Self.candidate()]

        store.userConfirmedDeletionFromPrimarySheet()
        await waitUntil { store.errorMessage != nil }

        #expect(store.errorMessage != nil)
        #expect(store.manualDeletionSession == nil)
        #expect(!store.showDeletionSheet)
        #expect(store.isDeleting)
    }

    // The Large Files confirmation. It used to return with no message.
    @Test("A confirmed Large Files delete during another clean is refused with a message")
    func confirmedLargeFileDeleteIsRefused() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.isDeleting = true
        let file = LargeFile(
            path: Self.folder.appendingPathComponent("big.zip"),
            sizeBytes: 1,
            lastUsed: Date(),
            category: LargeFileCategory.category(forExtension: "zip")
        )
        store.largeFiles = [file]
        store.setLargeFileSelected(id: file.id, isSelected: true)
        #expect(!store.selectedLargeFiles.isEmpty)
        store.showLargeFileDeletionSheet = true

        await store.confirmLargeFileDeletion()

        #expect(store.errorMessage != nil)
        #expect(store.manualDeletionSession == nil)
        #expect(!store.showLargeFileDeletionSheet)
    }

    // A leftover review (orphans, removed apps). It used to drop the confirmed
    // plan with no message.
    @Test("A confirmed leftover review during another clean is refused with a message")
    func confirmedLeftoverReviewIsRefused() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.isDeleting = true
        let item = UninstallItem(
            path: Self.folder.appendingPathComponent("Group Containers/group.example", isDirectory: true),
            sizeBytes: 1,
            category: .groupContainers,
            safetyInfo: Self.safeInfo,
            matchReason: .groupID,
            isSelected: true
        )

        await store.confirmOrphanCleanup(OrphanCleanupPlan(items: [item]))

        #expect(store.errorMessage != nil)
        #expect(store.manualDeletionSession == nil)
        #expect(store.orphanCleanupPlan == nil)
    }
}

/// Waits for `condition`, giving up after about two seconds. The confirm sheet
/// runs the clean in a task of its own.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
