import Foundation
import Testing
@testable import Purge

/// The quit guard asks before Purge quits mid-clean. It read only the cleanup
/// overlay, so a scheduled clean, the menu bar's Clean, an uninstall or a
/// leftover review, which run with `isDeleting` and no overlay, could be cut off
/// by Cmd-Q or a window close without a word (#173). `AppBootstrapper` wires the
/// guard to `isAnyCleanInProgress`.
@Suite("Cleaning quit guard")
@MainActor
struct CleaningQuitGuardTests {
    /// A row in a temporary folder that is never created. Nothing here deletes.
    private static func candidate() -> PurgeStore.DeletionCandidate {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-quit-guard-\(UUID().uuidString)", isDirectory: true)
        return PurgeStore.DeletionCandidate(
            title: "Cache",
            path: path,
            sizeBytes: 1,
            safetyInfo: SafetyInfo(level: .safe, headline: "Cache", explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
    }

    /// An engine run with no overlay is what a scheduled clean looks like.
    @Test("A clean with no overlay holds quit")
    func cleanWithNoOverlayHoldsQuit() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        #expect(!store.isAnyCleanInProgress)

        store.isDeleting = true
        #expect(store.isAnyCleanInProgress)
        #expect(!store.isManualCleaningInProgress)

        store.isDeleting = false
        #expect(!store.isAnyCleanInProgress)
    }

    /// The overlay's cleaning phase still holds quit, as before.
    @Test("The cleanup overlay holds quit while it cleans")
    func overlayHoldsQuit() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        let started = store.beginInteractiveSafeCleanup(
            candidates: [Self.candidate()],
            reduceMotion: true,
            presentsLiveSession: true
        )

        #expect(started)
        #expect(store.isAnyCleanInProgress)

        store.cancelInteractiveSafeCleanup()
        #expect(!store.isAnyCleanInProgress)
    }

    /// With nothing cleaning, quit and window close go through at once.
    @Test("Quit is allowed when nothing is cleaning")
    func quitAllowedWhenIdle() {
        let previous = CleaningQuitGuard.isCleaningActive
        defer { CleaningQuitGuard.isCleaningActive = previous }

        CleaningQuitGuard.isCleaningActive = { false }
        #expect(CleaningQuitGuard.shouldAllowTermination())
    }
}
