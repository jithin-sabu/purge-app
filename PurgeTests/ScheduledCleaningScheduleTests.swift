import Foundation
import Testing
@testable import Purge

/// Records how many times the schedule asked for a clean and lets a test read
/// back the summary it handed out, without any of the real filesystem/FDA work.
@MainActor
final class FakeScheduledClean {
    private(set) var callCount = 0
    var summary = PurgeStore.ScheduledCleaningSummary(deletedCount: 3, bytesMovedToTrash: 4_096)

    func run() -> PurgeStore.ScheduledCleaningSummary {
        callCount += 1
        return summary
    }
}

/// Proves the custom interval a user sets in Settings actually governs *when* a
/// clean fires — the half the interval-math tests don't cover. Each test drives a
/// `ScheduledCleaningRegistrar` built on an isolated defaults suite with a fake
/// clean action and a no-op re-arm, so timing is exercised deterministically.
@Suite("Scheduled cleaning schedule")
@MainActor
struct ScheduledCleaningScheduleTests {
    /// Raw defaults key the prefs store anchors the schedule from.
    private static let enabledAtKey = "scheduledClean.enabledAt"
    /// Raw defaults key the registrar stamps after each clean.
    private static let lastSweepKey = "ScheduledCleaningRegistrar.lastGraceSweep"

    private struct Harness {
        let registrar: ScheduledCleaningRegistrar
        let prefs: ScheduledCleaningPreferenceStore
        let defaults: UserDefaults
        let clean: FakeScheduledClean
        let review: FakeReview
    }

    private let suite = ThrowawayDefaults()

    private func makeHarness(enabledAt: Date, enabled: Bool = true) -> Harness {
        let defaults = suite.defaults
        defaults.set(enabledAt, forKey: Self.enabledAtKey)

        let prefs = ScheduledCleaningPreferenceStore(userDefaults: defaults)
        prefs.isEnabled = enabled

        let clean = FakeScheduledClean()
        let review = FakeReview()
        let registrar = ScheduledCleaningRegistrar(
            prefs: prefs,
            userDefaults: defaults,
            performClean: { clean.run() },
            rearm: {},
            isReviewingOrCleaning: { review.isOpen }
        )
        return Harness(registrar: registrar, prefs: prefs, defaults: defaults, clean: clean, review: review)
    }

    private func anchor(_ h: Harness) -> Date? {
        h.defaults.object(forKey: Self.lastSweepKey) as? Date
    }

    /// A stable, arbitrary enable moment so date math is exact and repeatable.
    private let enabledAt = Date(timeIntervalSinceReferenceDate: 700_000_000)

    // 1. The due date is the anchor plus the custom interval the user chose.
    @Test("Due date honors the custom interval", arguments: [
        (3, CustomCleaningIntervalUnit.day, TimeInterval(3 * 86_400)),
        (2, CustomCleaningIntervalUnit.week, TimeInterval(2 * 604_800)),
        (1, CustomCleaningIntervalUnit.month, TimeInterval(2_592_000)),
    ])
    func dueDateHonorsCustomInterval(amount: Int, unit: CustomCleaningIntervalUnit, seconds: TimeInterval) {
        let h = makeHarness(enabledAt: enabledAt)

        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = amount
        h.prefs.customIntervalUnit = unit

        #expect(h.registrar.dueDate(referenceDate: enabledAt) == enabledAt.addingTimeInterval(seconds))
    }

    // 2. Presets still gate on their own interval — the seam didn't disturb them.
    @Test("Preset frequency still gates the due date")
    func presetGatesDueDate() {
        let h = makeHarness(enabledAt: enabledAt)

        h.prefs.frequency = .monthly
        #expect(h.registrar.dueDate(referenceDate: enabledAt) == enabledAt.addingTimeInterval(30 * 86_400))
    }

    // 3. Before the interval elapses, the activation sweep must not clean anything.
    @Test("No clean fires before the interval elapses")
    func noCleanBeforeDue() async {
        let h = makeHarness(enabledAt: enabledAt)

        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 3
        h.prefs.customIntervalUnit = .day

        let twoDaysIn = enabledAt.addingTimeInterval(2 * 86_400)
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: twoDaysIn)

        #expect(h.clean.callCount == 0)
        #expect(anchor(h) == nil)
        #expect(h.registrar.lastOutcome == nil)
    }

    // 4. At the due moment the sweep runs exactly one clean and records it.
    @Test("A clean fires once when the interval has elapsed")
    func cleanFiresWhenDue() async {
        let h = makeHarness(enabledAt: enabledAt)

        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 3
        h.prefs.customIntervalUnit = .day

        let due = enabledAt.addingTimeInterval(3 * 86_400)
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: due)

        #expect(h.clean.callCount == 1)
        #expect(anchor(h) == due)
        #expect(h.registrar.lastOutcome?.deletedCount == 3)
        #expect(h.registrar.lastOutcome?.bytesMovedToTrash == 4_096)
    }

    // 5. After a clean the schedule steps forward one interval — it doesn't refire.
    @Test("The anchor advances one interval after a clean")
    func anchorAdvancesByOneInterval() async {
        let h = makeHarness(enabledAt: enabledAt)

        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 3
        h.prefs.customIntervalUnit = .day

        let firstDue = enabledAt.addingTimeInterval(3 * 86_400)
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: firstDue)

        // Immediately re-running at the same moment must not clean again…
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: firstDue)
        #expect(h.clean.callCount == 1)

        // …and the next due date is now one full interval past the clean.
        #expect(h.registrar.dueDate(referenceDate: firstDue) == firstDue.addingTimeInterval(3 * 86_400))
    }

    // 6. An overdue schedule never surfaces a past date to the UI.
    @Test("Next clean date clamps an overdue schedule to now")
    func nextCleanDateClampsOverdue() {
        let h = makeHarness(enabledAt: enabledAt)

        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 1
        h.prefs.customIntervalUnit = .day

        let wayLater = enabledAt.addingTimeInterval(365 * 86_400)
        #expect(h.registrar.nextCleanDate(referenceDate: wayLater) == wayLater)
    }

    // 7. With auto-clean off, an overdue schedule does nothing.
    @Test("Disabled schedule never cleans")
    func disabledNeverCleans() async {
        let h = makeHarness(enabledAt: enabledAt, enabled: false)

        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 1
        h.prefs.customIntervalUnit = .day

        let wayLater = enabledAt.addingTimeInterval(365 * 86_400)
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: wayLater)

        #expect(h.clean.callCount == 0)
        #expect(anchor(h) == nil)
    }

    // 8. "Run now" (the dev verification button) runs immediately, before the due date.
    @Test("Run now cleans immediately and stamps the anchor")
    func runNowIgnoresDueDate() async {
        let h = makeHarness(enabledAt: enabledAt)

        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 3
        h.prefs.customIntervalUnit = .day

        let oneDayIn = enabledAt.addingTimeInterval(86_400) // well before the 3-day due date
        let summary = await h.registrar.runScheduledCleanNow(referenceDate: oneDayIn)

        #expect(summary?.deletedCount == 3)
        #expect(h.clean.callCount == 1)
        #expect(anchor(h) == oneDayIn)
    }

    // 9. Only the registrar's own prefs re-arm it. The app's registrar listens
    //    while the tests run, and every test here makes a prefs store of its own,
    //    which must never re-arm the user's reminder (#171).
    @Test("Another prefs store never re-arms the registrar")
    func onlyItsOwnPrefsRearm() async {
        let h = makeHarness(enabledAt: enabledAt)
        let rearms = RearmCounter()
        let registrar = ScheduledCleaningRegistrar(
            prefs: h.prefs,
            userDefaults: h.defaults,
            performClean: { h.clean.run() },
            rearm: { rearms.count += 1 }
        )
        registrar.observePrefsChanges()
        let otherSuite = ThrowawayDefaults()
        defer { otherSuite.remove() }
        let otherPrefs = ScheduledCleaningPreferenceStore(userDefaults: otherSuite.defaults)

        h.prefs.frequency = .weekly
        await rearms.wait(until: 1)
        otherPrefs.frequency = .weekly
        h.prefs.frequency = .monthly
        await rearms.wait(until: 2)
        // Room for a late re-arm from the other store to show up.
        for _ in 0..<20 { await Task.yield() }

        #expect(rearms.count == 2)
    }

    // 10. A due clean waits while a review or confirmation is open, and leaves the
    //     anchor alone so the next sweep after it closes runs the clean (#173).
    @Test("A due clean waits for an open review")
    func dueCleanWaitsForOpenReview() async {
        let h = makeHarness(enabledAt: enabledAt)

        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 3
        h.prefs.customIntervalUnit = .day

        let due = enabledAt.addingTimeInterval(3 * 86_400)
        h.review.isOpen = true
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: due)

        #expect(h.clean.callCount == 0)
        #expect(anchor(h) == nil)
        #expect(h.registrar.lastOutcome == nil)

        let later = due.addingTimeInterval(60)
        h.review.isOpen = false
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: later)

        #expect(h.clean.callCount == 1)
        #expect(anchor(h) == later)
    }
}

/// Stands in for the store's review state, so the registrar tests need no store.
@MainActor
final class FakeReview {
    var isOpen = false
}

/// The store side of the review check: each review, confirmation, and running
/// clean holds a due scheduled clean back, and an error alert alone does not.
@Suite("Scheduled clean waits for reviews")
@MainActor
struct ScheduledCleanReviewHoldTests {
    @Test("Every review, confirmation, and running clean holds the schedule")
    func everyReviewHoldsTheSchedule() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let app = InstalledApp(
            name: "Gone",
            bundleURL: URL(fileURLWithPath: "/Applications/Gone.app"),
            bundleID: "com.example.gone",
            bundleSizeBytes: 0,
            isRunning: false
        )
        let states: [(String, (Bool) -> Void)] = [
            ("deletion sheet", { store.showDeletionSheet = $0 }),
            ("Not Sure sheet", { store.pendingUnknownDeletion = $0 ? .init(candidates: []) : nil }),
            ("Large Files sheet", { store.showLargeFileDeletionSheet = $0 }),
            ("duplicate cleanup", { store.pendingDuplicateCleanup = $0 ? DuplicateCleanupRequest(sets: []) : nil }),
            ("uninstall review", { store.uninstallPlan = $0 ? UninstallPlan(id: "test", apps: []) : nil }),
            ("uninstall plan being built", { store.isBuildingUninstallPlan = $0 }),
            ("orphan review", { store.orphanCleanupPlan = $0 ? OrphanCleanupPlan(items: []) : nil }),
            ("removed-app review", {
                store.removedAppLeftoverPlan = $0
                    ? RemovedAppLeftoverPlan(app: app, items: [], trashedBundleURL: nil)
                    : nil
            }),
            ("missing lockfile alert", { store.showMissingLockfileFriction = $0 }),
            ("unsaved git alert", { store.showUncommittedGitFriction = $0 }),
            ("Not Sure second alert", { store.showHighRiskDeletionSecondConfirm = $0 }),
            ("clean running", { store.isDeleting = $0 }),
        ]

        #expect(!store.isReviewingOrCleaning)
        for (name, setOpen) in states {
            setOpen(true)
            #expect(store.isReviewingOrCleaning, "\(name) should hold the schedule")
            setOpen(false)
            #expect(!store.isReviewingOrCleaning, "\(name) should release the schedule")
        }
    }

    // An error alert can stay set with no window open to dismiss it. Holding the
    // schedule on it would stop scheduled cleans for good.
    @Test("An error alert does not hold the schedule")
    func errorAlertDoesNotHold() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        store.errorMessage = "Test error"

        #expect(!store.isReviewingOrCleaning)
        #expect(store.isShowingReviewOrCleaning)
    }
}

/// Counts the registrar's re-arms. A re-arm runs in its own task, so a test waits
/// for the count it expects, giving up after about two seconds.
@MainActor
private final class RearmCounter {
    var count = 0

    func wait(until target: Int) async {
        for _ in 0..<200 where count < target {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
