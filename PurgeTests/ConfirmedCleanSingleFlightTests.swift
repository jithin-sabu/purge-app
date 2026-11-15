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

    /// The delete confirmation sheet, confirmed while a clean holds `isDeleting`.
    /// `executeStagedDeletion` had no guard at all, so the second clean ran beside
    /// the first.
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

    /// The Large Files confirmation. It used to return with no message.
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

    private static func leftover() -> UninstallItem {
        UninstallItem(
            path: folder.appendingPathComponent("Group Containers/group.example", isDirectory: true),
            sizeBytes: 1,
            category: .groupContainers,
            safetyInfo: safeInfo,
            matchReason: .groupID,
            isSelected: true
        )
    }

    private static func app() -> InstalledApp {
        InstalledApp(
            name: "Example",
            bundleURL: folder.appendingPathComponent("Example.app", isDirectory: true),
            bundleID: "com.example.purge-tests",
            bundleSizeBytes: 1,
            isRunning: false
        )
    }

    /// The orphan review. It used to drop the confirmed plan with no message.
    @Test("A confirmed orphan review during another clean is refused with a message")
    func confirmedOrphanReviewIsRefused() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.isDeleting = true

        await store.confirmOrphanCleanup(OrphanCleanupPlan(items: [Self.leftover()]))

        #expect(store.errorMessage != nil)
        #expect(store.manualDeletionSession == nil)
        #expect(store.orphanCleanupPlan == nil)
    }

    /// The uninstall review. `performUninstallPlan` checked `isDeleting` but said nothing.
    @Test("A confirmed uninstall during another clean is refused with a message")
    func confirmedUninstallIsRefused() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.isDeleting = true
        let plan = UninstallPlan(id: "single-flight", apps: [
            UninstallAppPlan(app: Self.app(), items: [Self.leftover()])
        ])
        store.uninstallPlan = plan

        await store.confirmUninstallPlan(plan)

        #expect(store.errorMessage != nil)
        #expect(store.manualDeletionSession == nil)
        #expect(store.uninstallPlan == nil)
        #expect(store.isDeleting)
    }

    /// The removed-app review can't be reopened by hand, so instead of dropping it
    /// the store holds it for `RemovedAppMonitor` to show again after the clean.
    @Test("A confirmed removed-app review during another clean is held for later")
    func confirmedRemovedAppReviewIsHeld() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.isDeleting = true
        let plan = RemovedAppLeftoverPlan(app: Self.app(), items: [Self.leftover()], trashedBundleURL: nil)
        store.removedAppLeftoverPlan = plan

        await store.confirmRemovedAppLeftovers(plan)

        #expect(store.errorMessage != nil)
        #expect(store.manualDeletionSession == nil)
        #expect(store.removedAppLeftoverPlan == nil)
        #expect(store.takeRemovedAppReviewHeldForAnotherClean())
        // Read once: the monitor takes it as the sheet closes.
        #expect(!store.takeRemovedAppReviewHeldForAnotherClean())
    }

    /// With no clean running the flag is never set, so the monitor ends the review.
    @Test("A removed-app review confirmed with no clean running is not held")
    func removedAppReviewNotHeldWhenIdle() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        #expect(!store.takeRemovedAppReviewHeldForAnotherClean())
    }

    /// A leftover clean that never failed reads as such, so the monitor ends the
    /// review after a summary rather than showing it again (#177). The failure
    /// itself needs the deleter to throw, which the store's own deleter does not
    /// do on demand.
    @Test("A leftover clean that did not fail is not offered again")
    func leftoverCleanupFailureNotReportedWhenNoneHappened() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        #expect(!store.takeLeftoverCleanupFailure())
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
