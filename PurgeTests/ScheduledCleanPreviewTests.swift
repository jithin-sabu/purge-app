import Foundation
import Testing
@testable import Purge

/// The first scheduled clean shows its list and waits (#331). Each test drives a
/// `ScheduledCleaningRegistrar` on throwaway defaults with fakes for the list,
/// the approved clean, the automatic clean and the reminder, so nothing here
/// scans, moves a file, or touches the user's notifications.
@Suite("First scheduled clean preview")
@MainActor
struct ScheduledCleanPreviewTests {
    private static let enabledAtKey = "scheduledClean.enabledAt"
    private static let lastSweepKey = "ScheduledCleaningRegistrar.lastGraceSweep"
    private static let lastOutcomeKey = "ScheduledCleaningRegistrar.lastOutcome"
    private static let lastFailedAttemptKey = "ScheduledCleaningRegistrar.lastFailedAttempt"

    @MainActor
    private final class Fakes {
        var previewResult: ScheduledCleanPreviewResult = .presented
        var previewCount = 0
        var approvedPaths: [Set<String>] = []
        var approvedSummary = PurgeStore.ScheduledCleaningSummary(deletedCount: 2, bytesMovedToTrash: 2_048)
        var reminderCancels = 0
        var rearms = 0
        let clean = FakeScheduledClean()
        let review = FakeReview()
    }

    private struct Harness {
        let registrar: ScheduledCleaningRegistrar
        let prefs: ScheduledCleaningPreferenceStore
        let defaults: UserDefaults
        let fakes: Fakes
    }

    private let suite = ThrowawayDefaults()

    /// A stable enable moment so the date math is exact.
    private let enabledAt = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private var monthLater: Date { enabledAt.addingTimeInterval(31 * 86_400) }

    private func makeHarness(fakes given: Fakes? = nil, enabled: Bool = true) -> Harness {
        let fakes = given ?? Fakes()
        let defaults = suite.defaults
        if defaults.object(forKey: Self.enabledAtKey) == nil {
            defaults.set(enabledAt, forKey: Self.enabledAtKey)
        }
        let prefs = ScheduledCleaningPreferenceStore(userDefaults: defaults)
        prefs.isEnabled = enabled
        prefs.frequency = .monthly
        let registrar = ScheduledCleaningRegistrar(
            prefs: prefs,
            userDefaults: defaults,
            performClean: { fakes.clean.run() },
            rearm: { fakes.rearms += 1 },
            isReviewingOrCleaning: { fakes.review.isOpen },
            preparePreview: {
                fakes.previewCount += 1
                return fakes.previewResult
            },
            performApprovedClean: { paths in
                fakes.approvedPaths.append(paths)
                return fakes.approvedSummary
            },
            cancelReminder: { fakes.reminderCancels += 1 }
        )
        return Harness(registrar: registrar, prefs: prefs, defaults: defaults, fakes: fakes)
    }

    private func anchor(_ h: Harness) -> Date? {
        h.defaults.object(forKey: Self.lastSweepKey) as? Date
    }

    // MARK: Nothing moves before approval

    @Test("A due first clean shows its list and moves nothing")
    func dueFirstCleanShowsListOnly() async {
        let h = makeHarness()

        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater)

        #expect(h.fakes.previewCount == 1)
        #expect(h.fakes.clean.callCount == 0)
        #expect(h.fakes.approvedPaths.isEmpty)
        #expect(!h.prefs.firstCleanApproved)
        // Still due: no anchor, no outcome, nothing recorded as cleaned.
        #expect(anchor(h) == nil)
        #expect(h.registrar.lastOutcome == nil)
        #expect(h.defaults.object(forKey: Self.lastOutcomeKey) == nil)
        #expect(h.registrar.dueDate(referenceDate: monthLater) <= monthLater)
        // The due-date reminder would arrive over the open list.
        #expect(h.fakes.reminderCancels == 1)
    }

    @Test("Before the due date the first clean shows nothing")
    func notDueShowsNothing() async {
        let h = makeHarness()

        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: enabledAt.addingTimeInterval(86_400))

        #expect(h.fakes.previewCount == 0)
        #expect(h.fakes.clean.callCount == 0)
    }

    @Test("Run now shows the list too, and says so")
    func runNowShowsList() async {
        let h = makeHarness()

        let summary = await h.registrar.runScheduledCleanNow(referenceDate: enabledAt.addingTimeInterval(60))

        #expect(summary?.awaitsApproval == true)
        #expect(summary?.deletedCount == 0)
        #expect(h.fakes.previewCount == 1)
        #expect(h.fakes.clean.callCount == 0)
        #expect(anchor(h) == nil)
        #expect(!h.prefs.firstCleanApproved)
    }

    @Test("An open review holds the list back, and the clean stays due")
    func reviewHoldsList() async {
        let h = makeHarness()
        h.fakes.review.isOpen = true

        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater)

        #expect(h.fakes.previewCount == 0)
        #expect(anchor(h) == nil)
    }

    @Test("A list the store skipped leaves the clean due")
    func skippedListStaysDue() async {
        let fakes = Fakes()
        fakes.previewResult = .skipped
        let h = makeHarness(fakes: fakes)

        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater)

        #expect(h.fakes.previewCount == 1)
        #expect(anchor(h) == nil)
        #expect(h.fakes.reminderCancels == 0)
        #expect(!h.prefs.firstCleanApproved)
    }

    // MARK: Not Now

    @Test("Not Now records nothing and the list waits out its gap")
    func notNowWaitsOutGap() async {
        let h = makeHarness()
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater)

        let rearmsBefore = h.fakes.rearms
        await h.registrar.closeFirstCleanPreview(at: monthLater)

        // The reminder taken back when the list opened is armed again.
        #expect(h.fakes.rearms == rearmsBefore + 1)
        #expect(!h.prefs.firstCleanApproved)
        #expect(anchor(h) == nil)
        #expect(h.registrar.lastOutcome == nil)
        let gapEnd = monthLater.addingTimeInterval(ScheduledCleaningRegistrar.previewGapAfterNotNow)
        #expect(h.registrar.dueDate(referenceDate: monthLater) == gapEnd)

        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: gapEnd.addingTimeInterval(-1))
        #expect(h.fakes.previewCount == 1)

        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: gapEnd)
        #expect(h.fakes.previewCount == 2)
        #expect(h.fakes.clean.callCount == 0)
    }

    @Test("A Not Now stamp from a clock that was ahead hides the list for one gap at most")
    func futureNotNowStampIsClamped() async {
        let h = makeHarness()
        await h.registrar.closeFirstCleanPreview(at: monthLater.addingTimeInterval(365 * 86_400))
        let gapEnd = monthLater.addingTimeInterval(ScheduledCleaningRegistrar.previewGapAfterNotNow)

        #expect(h.registrar.dueDate(referenceDate: monthLater) == gapEnd)
        // Re-stamped once, so the end of the gap stays put instead of sliding.
        #expect(h.registrar.dueDate(referenceDate: gapEnd) == gapEnd)
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: gapEnd)
        #expect(h.fakes.previewCount == 1)
    }

    // MARK: Approval

    @Test("Clean cleans the shown paths and counts as this period's clean")
    func approvalCleansShownPaths() async throws {
        let h = makeHarness()
        let paths: Set<String> = ["/tmp/purge-preview-a", "/tmp/purge-preview-b"]
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater)
        await h.registrar.closeFirstCleanPreview(at: monthLater)

        let summary = await h.registrar.cleanApprovedPreview(paths: paths, referenceDate: monthLater)

        #expect(summary?.deletedCount == 2)
        #expect(h.fakes.approvedPaths == [paths])
        #expect(h.fakes.clean.callCount == 0)
        #expect(h.prefs.firstCleanApproved)
        #expect(anchor(h) == monthLater)
        let outcome = try #require(h.registrar.lastOutcome)
        #expect(outcome.deletedCount == 2)
        #expect(outcome.bytesMovedToTrash == 2_048)
        // The Not Now gap no longer applies; the next clean is one interval on.
        #expect(h.registrar.dueDate(referenceDate: monthLater) == monthLater.addingTimeInterval(2_592_000))
    }

    @Test("After approval the next due clean runs on its own")
    func afterApprovalCleansAutomatically() async {
        let h = makeHarness()
        await h.registrar.cleanApprovedPreview(paths: ["/tmp/purge-preview-a"], referenceDate: monthLater)

        let nextMonth = monthLater.addingTimeInterval(31 * 86_400)
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: nextMonth)

        #expect(h.fakes.clean.callCount == 1)
        #expect(h.fakes.previewCount == 0)
    }

    @Test("A clean that never started keeps asking")
    func skippedApprovalKeepsAsking() async {
        let fakes = Fakes()
        fakes.approvedSummary = PurgeStore.ScheduledCleaningSummary(
            deletedCount: 0, bytesMovedToTrash: 0, skippedForAnotherClean: true
        )
        let h = makeHarness(fakes: fakes)

        await h.registrar.cleanApprovedPreview(paths: ["/tmp/purge-preview-a"], referenceDate: monthLater)

        #expect(!h.prefs.firstCleanApproved)
        #expect(anchor(h) == nil)
        #expect(h.registrar.lastOutcome == nil)
        // Still due, so the reminder taken back when the list opened is armed again.
        #expect(h.fakes.rearms >= 1)
    }

    @Test("A clean with nothing left to move keeps asking")
    func nothingLeftKeepsAsking() async {
        let fakes = Fakes()
        fakes.approvedSummary = PurgeStore.ScheduledCleaningSummary(
            deletedCount: 0, bytesMovedToTrash: 0, hadNothingToMove: true
        )
        let h = makeHarness(fakes: fakes)

        await h.registrar.cleanApprovedPreview(paths: ["/tmp/purge-preview-a"], referenceDate: monthLater)

        #expect(!h.prefs.firstCleanApproved)
        // The period counts as done, as a clean that found nothing does.
        #expect(anchor(h) == monthLater)
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater.addingTimeInterval(31 * 86_400))
        #expect(h.fakes.previewCount == 1)
        #expect(h.fakes.clean.callCount == 0)
    }

    @Test("A failed approved clean keeps the approval and waits out the retry gap")
    func failedApprovalKeepsApproval() async {
        let fakes = Fakes()
        fakes.approvedSummary = PurgeStore.ScheduledCleaningSummary(
            deletedCount: 0, bytesMovedToTrash: 0, failed: true
        )
        let h = makeHarness(fakes: fakes)

        await h.registrar.cleanApprovedPreview(paths: ["/tmp/purge-preview-a"], referenceDate: monthLater)

        #expect(h.prefs.firstCleanApproved)
        #expect(anchor(h) == nil)
        #expect(h.defaults.object(forKey: Self.lastFailedAttemptKey) as? Date == monthLater)
    }

    @Test("Turning the schedule off while the list is open moves nothing")
    func disabledWhileOpenMovesNothing() async {
        let h = makeHarness()
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater)
        h.prefs.applyEnabled(false, now: monthLater)

        let summary = await h.registrar.cleanApprovedPreview(paths: ["/tmp/purge-preview-a"], referenceDate: monthLater)

        #expect(summary == nil)
        #expect(h.fakes.approvedPaths.isEmpty)
        #expect(!h.prefs.firstCleanApproved)
    }

    // MARK: Nothing eligible

    @Test("Nothing eligible ends the period without using up the approval")
    func nothingEligibleKeepsApprovalUnused() async throws {
        let fakes = Fakes()
        fakes.previewResult = .nothingEligible
        let h = makeHarness(fakes: fakes)

        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater)

        #expect(h.fakes.clean.callCount == 0)
        #expect(!h.prefs.firstCleanApproved)
        #expect(anchor(h) == monthLater)
        let outcome = try #require(h.registrar.lastOutcome)
        #expect(outcome.deletedCount == 0)
        #expect(outcome.bytesMovedToTrash == 0)

        // The next due period shows the list again.
        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater.addingTimeInterval(31 * 86_400))
        #expect(h.fakes.previewCount == 2)
    }

    // MARK: Persisted state

    @Test("Quitting with the list open shows it again at the next launch")
    func relaunchShowsListAgain() async {
        let first = makeHarness()
        await first.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater)

        // A new registrar and prefs store on the same defaults is a relaunch.
        let relaunched = makeHarness()
        #expect(!relaunched.prefs.firstCleanApproved)
        await relaunched.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater.addingTimeInterval(60))

        #expect(relaunched.fakes.previewCount == 1)
        #expect(relaunched.fakes.clean.callCount == 0)
    }

    @Test("The approval survives a relaunch")
    func approvalPersists() async {
        let first = makeHarness()
        await first.registrar.cleanApprovedPreview(paths: ["/tmp/purge-preview-a"], referenceDate: monthLater)

        let relaunched = makeHarness()

        #expect(relaunched.prefs.firstCleanApproved)
    }

    @Test("Turning the schedule off and on keeps the approval")
    func reEnableKeepsApproval() async {
        let h = makeHarness()
        await h.registrar.cleanApprovedPreview(paths: ["/tmp/purge-preview-a"], referenceDate: monthLater)

        h.prefs.applyEnabled(false, now: monthLater)
        h.prefs.applyEnabled(true, now: monthLater.addingTimeInterval(60))

        #expect(h.prefs.firstCleanApproved)
        await h.registrar.runGracefulActivationSweepIfPastDue(
            referenceDate: monthLater.addingTimeInterval(60 + 31 * 86_400)
        )
        #expect(h.fakes.clean.callCount == 1)
        #expect(h.fakes.previewCount == 0)
    }

    @Test("An install that cleaned on a schedule before still sees the list once")
    func existingInstallSeesListOnce() async {
        // Defaults as an earlier version left them: cleans have run, and the
        // approval key has never been written.
        suite.defaults.set(enabledAt, forKey: Self.lastSweepKey)
        let h = makeHarness()
        #expect(!h.prefs.firstCleanApproved)

        await h.registrar.runGracefulActivationSweepIfPastDue(referenceDate: monthLater)

        #expect(h.fakes.previewCount == 1)
        #expect(h.fakes.clean.callCount == 0)
        #expect(anchor(h) == enabledAt)
    }
}

/// The list's own rules: one row per path, and an approved clean that takes only
/// shown paths that are still Safe.
@Suite("First scheduled clean list")
@MainActor
struct ScheduledCleanPreviewListTests {
    private static func candidate(_ path: String, level: SafetyLevel = .safe, size: Int64 = 1) -> PurgeStore.DeletionCandidate {
        PurgeStore.DeletionCandidate(
            title: (path as NSString).lastPathComponent,
            path: URL(fileURLWithPath: path, isDirectory: true),
            sizeBytes: size,
            safetyInfo: SafetyInfo(level: level, headline: "Cache", explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
    }

    @Test("The approved clean takes only shown paths that are still Safe")
    func approvedTakesOnlyShownSafePaths() {
        let shown: Set<String> = ["/tmp/purge-list/a", "/tmp/purge-list/b", "/tmp/purge-list/c"]
        let current = [
            Self.candidate("/tmp/purge-list/a"),
            // Turned Check First since the list was built.
            Self.candidate("/tmp/purge-list/b", level: .medium),
            // Appeared since the list was built.
            Self.candidate("/tmp/purge-list/new"),
        ]

        let approved = ScheduledCleanPreview.approved(current, paths: shown)

        #expect(approved.map(\.path.path) == ["/tmp/purge-list/a"])
    }

    @Test("Paths match however the scan spelled them")
    func approvedMatchesStandardizedPaths() {
        let preview = ScheduledCleanPreview(candidates: [Self.candidate("/tmp/purge-list/./a")])

        let approved = ScheduledCleanPreview.approved([Self.candidate("/tmp/purge-list/a")], paths: preview.paths)

        #expect(approved.count == 1)
    }

    @Test("The list shows each path once, and totals what it shows")
    func listIsUniqueByPath() {
        let unique = ScheduledCleanPreview.uniqueByPath([
            Self.candidate("/tmp/purge-list/a", size: 10),
            Self.candidate("/tmp/purge-list/a", size: 10),
            Self.candidate("/tmp/purge-list/b", size: 5),
        ])
        let preview = ScheduledCleanPreview(candidates: unique)

        #expect(unique.count == 2)
        #expect(preview.totalBytes == 15)
        #expect(preview.sortedCandidates.map(\.sizeBytes) == [10, 5])
    }

    @Test("Move to Trash says why when nothing moved")
    func approvedPreviewExplainsNothingMoved() {
        #expect(PurgeStore.approvedPreviewMessage(for: nil) != nil)
        #expect(PurgeStore.approvedPreviewMessage(
            for: PurgeStore.ScheduledCleaningSummary(deletedCount: 0, bytesMovedToTrash: 0, skippedForAnotherClean: true)
        ) != nil)
        #expect(PurgeStore.approvedPreviewMessage(
            for: PurgeStore.ScheduledCleaningSummary(deletedCount: 1, bytesMovedToTrash: 10)
        ) == nil)
    }

    @Test("The list waits while another sheet or alert is open")
    func listWaitsForOtherSheets() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let states: [(String, (Bool) -> Void)] = [
            ("Look Deeper", { store.isLookDeeperPresented = $0 }),
            ("error alert", { store.errorMessage = $0 ? "Test error" : nil }),
            ("deletion sheet", { store.showDeletionSheet = $0 }),
        ]

        #expect(store.mayPresentScheduledCleanPreview)
        for (name, setOpen) in states {
            setOpen(true)
            #expect(!store.mayPresentScheduledCleanPreview, "\(name) should hold the list")
            setOpen(false)
            #expect(store.mayPresentScheduledCleanPreview, "\(name) should release the list")
        }
    }

    @Test("The list holds the schedule and counts as an open sheet")
    func listHoldsTheSchedule() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        store.scheduledCleanPreview = ScheduledCleanPreview(candidates: [Self.candidate("/tmp/purge-list/a")])

        #expect(store.isReviewingOrCleaning)
        #expect(store.isAnotherSheetOpen)
        #expect(!store.mayStartSafeClean(trigger: .scheduled))
    }
}
