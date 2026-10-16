import AppKit
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

    // 10-13. Purge coming forward checks the schedule, window or not (#173). Each
    //        test posts the activation on a center of its own, so the app hosting
    //        the tests never hears it.

    private func observeActivation(
        _ h: Harness,
        onboarded: Bool = true,
        quitsOnItsOwn: Bool = false
    ) -> NotificationCenter {
        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 3
        h.prefs.customIntervalUnit = .day
        h.defaults.set(onboarded, forKey: FirstRunGate.onboardingCompletedKey)
        let center = NotificationCenter()
        h.registrar.observeAppActivation(center: center, quitsOnItsOwn: { quitsOnItsOwn })
        return center
    }

    private func activate(_ center: NotificationCenter) {
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @Test("An activation past the due date runs one clean")
    func activationPastDueCleansOnce() async {
        // Enabled in 2023 with a three-day interval, so long overdue by the real clock.
        let h = makeHarness(enabledAt: enabledAt)
        let center = observeActivation(h)

        activate(center)
        await waitUntil { anchor(h) != nil }
        // The clean moved the anchor to now, so the next activation finds nothing due.
        activate(center)
        await settle()

        #expect(h.clean.callCount == 1)
        #expect(anchor(h) != nil)
        #expect(h.registrar.lastOutcome?.deletedCount == 3)
    }

    @Test("An activation before the due date runs no clean")
    func activationBeforeDueDoesNothing() async {
        let h = makeHarness(enabledAt: Date())
        let center = observeActivation(h)

        activate(center)
        await settle()

        #expect(h.clean.callCount == 0)
        #expect(anchor(h) == nil)
    }

    @Test("An activation before onboarding ends runs no clean")
    func activationDuringOnboardingDoesNothing() async {
        let h = makeHarness(enabledAt: enabledAt)
        let center = observeActivation(h, onboarded: false)

        activate(center)
        await settle()

        #expect(h.clean.callCount == 0)
        #expect(anchor(h) == nil)
    }

    // The deleted-apps watcher opened Purge only for a review, and Purge quits as
    // soon as that is done. A clean started then would be cut off.
    @Test("An activation in a launch that quits on its own runs no clean")
    func activationInSelfQuittingLaunchDoesNothing() async {
        let h = makeHarness(enabledAt: enabledAt)
        let center = observeActivation(h, quitsOnItsOwn: true)

        activate(center)
        await settle()

        #expect(h.clean.callCount == 0)
        #expect(anchor(h) == nil)
    }

    /// A registrar on the harness's defaults whose clean runs until the test
    /// finishes it, due three days after `enabledAt`.
    private func heldRegistrar(_ h: Harness, clean held: HeldClean) -> ScheduledCleaningRegistrar {
        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 3
        h.prefs.customIntervalUnit = .day
        return ScheduledCleaningRegistrar(
            prefs: h.prefs,
            userDefaults: h.defaults,
            performClean: { await held.run() },
            rearm: {}
        )
    }

    // The window's launch sweep and an activation both find the clean due. The
    // second must neither clean again nor return early: the window scans as soon
    // as its sweep returns, and a scan then would run beside the clean.
    @Test("A sweep asked for during a clean waits for it and starts none")
    func secondSweepWaitsForTheFirst() async {
        let h = makeHarness(enabledAt: enabledAt)
        let held = HeldClean()
        let registrar = heldRegistrar(h, clean: held)
        let due = enabledAt.addingTimeInterval(3 * 86_400)

        let first = Task { await registrar.runGracefulActivationSweepIfPastDue(referenceDate: due) }
        await waitUntil { held.callCount == 1 }
        let secondReturned = Flag()
        let second = Task {
            await registrar.runGracefulActivationSweepIfPastDue(referenceDate: due)
            secondReturned.isSet = true
        }
        await settle()
        #expect(!secondReturned.isSet)

        held.finish()
        await first.value
        await second.value

        #expect(secondReturned.isSet)
        #expect(held.callCount == 1)
        #expect(anchor(h) == due)
    }

    // Run now used to return nil here, which Settings shows as "auto-clean is off".
    @Test("Run now during a sweep waits for it and reports that clean")
    func runNowDuringSweepReportsThatClean() async {
        let h = makeHarness(enabledAt: enabledAt)
        let held = HeldClean()
        let registrar = heldRegistrar(h, clean: held)
        let due = enabledAt.addingTimeInterval(3 * 86_400)

        let sweep = Task { await registrar.runGracefulActivationSweepIfPastDue(referenceDate: due) }
        await waitUntil { held.callCount == 1 }
        let runNow = Task { await registrar.runScheduledCleanNow(referenceDate: due.addingTimeInterval(60)) }
        await settle()

        held.finish()
        await sweep.value
        let summary = await runNow.value

        #expect(summary?.deletedCount == 1)
        #expect(summary?.bytesMovedToTrash == 1_024)
        #expect(held.callCount == 1)
        #expect(anchor(h) == due)
    }

    // The clean found another clean running and removed nothing. Counting it as
    // done would skip the schedule for a whole interval.
    @Test("A clean skipped for another clean stays due")
    func skippedCleanStaysDue() async {
        let h = makeHarness(enabledAt: enabledAt)
        h.prefs.frequency = .custom
        h.prefs.customIntervalAmount = 3
        h.prefs.customIntervalUnit = .day
        let done = h.clean.summary
        h.clean.summary = PurgeStore.ScheduledCleaningSummary(
            deletedCount: 0,
            bytesMovedToTrash: 0,
            skippedForAnotherClean: true
        )
        let due = enabledAt.addingTimeInterval(3 * 86_400)

        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: due)
        #expect(h.clean.callCount == 1)
        #expect(anchor(h) == nil)
        #expect(h.registrar.lastOutcome == nil)

        // The other clean has ended, and the next activation runs this one.
        h.clean.summary = done
        let later = due.addingTimeInterval(60)
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: later)
        #expect(h.clean.callCount == 2)
        #expect(anchor(h) == later)
        #expect(h.registrar.lastOutcome?.deletedCount == 3)
    }

    // 14. The app only observes activation outside the test host and previews.
    //     Both share the user's real defaults and would clean real caches.
    @Test("The test host and previews never clean on activation")
    func activationCleaningSkipsTestHostAndPreviews() {
        #expect(ScheduledCleaningRegistrar.cleansOnActivation(environment: [:]))
        #expect(!ScheduledCleaningRegistrar.cleansOnActivation(environment: ["XCTestConfigurationFilePath": "/tmp/x"]))
        #expect(!ScheduledCleaningRegistrar.cleansOnActivation(environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]))
        #expect(!ScheduledCleaningRegistrar.cleansOnActivation(environment: ProcessInfo.processInfo.environment))
    }

    // 15. A due clean waits while a review or confirmation is open, and leaves the
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

/// Waits for `condition`, giving up after about two seconds. The activation
/// handler runs the sweep in a task of its own.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Room for an activation that should do nothing to show up if it does something.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 100_000_000)
}

/// A clean that stays running until the test lets it finish.
@MainActor
private final class HeldClean {
    private(set) var callCount = 0
    private var release: CheckedContinuation<Void, Never>?

    func run() async -> PurgeStore.ScheduledCleaningSummary {
        callCount += 1
        await withCheckedContinuation { release = $0 }
        return PurgeStore.ScheduledCleaningSummary(deletedCount: 1, bytesMovedToTrash: 1_024)
    }

    func finish() {
        release?.resume()
        release = nil
    }
}

@MainActor
private final class Flag {
    var isSet = false
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

/// The store's half of a skipped clean (#173): a safe clean that finds another
/// clean running removes nothing and says so, so the schedule can stay due.
@Suite("Safe clean while another clean runs")
@MainActor
struct SafeCleanDuringAnotherCleanTests {
    @Test("A safe clean during another clean is marked skipped")
    func safeCleanDuringAnotherCleanIsSkipped() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        // A temporary folder, which the safety policy would refuse anyway.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-skipped-clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let candidate = PurgeStore.DeletionCandidate(
            title: "Cache",
            path: folder,
            sizeBytes: 1,
            safetyInfo: SafetyInfo(level: .safe, headline: "Cache", explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
        store.isDeleting = true

        let summary = await store.performManualSafeCleanNow(pinnedCandidates: [candidate])

        #expect(summary.skippedForAnotherClean)
        #expect(summary.deletedCount == 0)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }
}
