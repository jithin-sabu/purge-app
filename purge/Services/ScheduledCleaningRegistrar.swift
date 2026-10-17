import AppKit
import Combine
import Foundation
import UserNotifications

/// Outcome of the most recent scheduled clean (including runs that found nothing
/// eligible), persisted so Settings can show what the schedule last did.
struct LastScheduledCleanOutcome: Codable, Equatable {
    let date: Date
    /// Bytes moved to the trash by that run, pending until the trash is emptied.
    let bytesMovedToTrash: Int64
    let deletedCount: Int

    init(date: Date, bytesMovedToTrash: Int64, deletedCount: Int) {
        self.date = date
        self.bytesMovedToTrash = bytesMovedToTrash
        self.deletedCount = deletedCount
    }

    enum CodingKeys: String, CodingKey {
        case date, bytesMovedToTrash, deletedCount
        /// Pre-measurement field, holding the same sum under a misleading name.
        case freedBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decode(Date.self, forKey: .date)
        self.deletedCount = try container.decode(Int.self, forKey: .deletedCount)
        if let moved = try container.decodeIfPresent(Int64.self, forKey: .bytesMovedToTrash) {
            self.bytesMovedToTrash = moved
        } else {
            self.bytesMovedToTrash = try container.decode(Int64.self, forKey: .freedBytes)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(bytesMovedToTrash, forKey: .bytesMovedToTrash)
        try container.encode(deletedCount, forKey: .deletedCount)
    }
}

/// macOS scheduling: repeating local reminders plus a graceful sweep when the app becomes active.
/// Background processing tasks (`BGTaskScheduler` / `BGProcessingTask`) are not available on macOS.
@MainActor
final class ScheduledCleaningRegistrar: ObservableObject {
    static let shared = ScheduledCleaningRegistrar()

    /// Single pending repeating request; aligns with purge bundle conventions.
    static let repeatingReminderIdentifier = "io.getpurge.app.scheduled-clean"

    private static let lastGraceSweepKey = "ScheduledCleaningRegistrar.lastGraceSweep"
    private static let lastOutcomeKey = "ScheduledCleaningRegistrar.lastOutcome"
    private static let lastFailedAttemptKey = "ScheduledCleaningRegistrar.lastFailedAttempt"

    /// How long a failed scheduled clean waits before an activation tries again.
    /// The anchor stays put after a failure, so without this gap a Safe item the
    /// Trash always refuses would run a rescan, a clean and a failure notification
    /// on every switch into Purge (#173).
    static let retryGapAfterFailure: TimeInterval = 60 * 60

    /// Convenience shim over the standard domain, kept for any external caller.
    /// The registrar itself reads the anchor through its injected `ud`.
    static var lastGraceSweepDate: Date? {
        UserDefaults.standard.object(forKey: lastGraceSweepKey) as? Date
    }

    @Published private(set) var lastOutcome: LastScheduledCleanOutcome?

    private weak var store: PurgeStore?
    private var prefsObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var activationCenter: NotificationCenter?
    /// The window's launch `.task` and the activation handler can both find the
    /// same overdue schedule before either advances the anchor (the scan inside
    /// the clean takes a while), producing back-to-back duplicate cleans. One sweep
    /// at a time.
    private var isSweepRunning = false
    /// Sweeps and Run now requests made while another was cleaning. Each returns
    /// with that clean's summary when it ends, so the window's launch scans never
    /// start in the middle of a clean the activation handler started.
    private var sweepWaiters: [CheckedContinuation<PurgeStore.ScheduledCleaningSummary?, Never>] = []
    /// True while Purge runs only to review a removed app and will quit after it.
    private var quitsOnItsOwn: () -> Bool = { false }

    // Injected dependencies. Production uses the defaults (the shared prefs store,
    // the standard defaults domain, the attached PurgeStore, the real re-arm);
    // tests substitute an isolated defaults suite plus fakes so the timing logic
    // can be exercised without touching the filesystem, FDA, or notifications.
    private let ud: UserDefaults
    private let prefs: ScheduledCleaningPreferenceStore
    private let performCleanOverride: (() async -> PurgeStore.ScheduledCleaningSummary)?
    private let rearmOverride: (() async -> Void)?
    private let isReviewingOrCleaningOverride: (() -> Bool)?

    /// The anchor timestamp of the last clean, read through the injected domain.
    private var currentLastGraceSweepDate: Date? {
        ud.object(forKey: Self.lastGraceSweepKey) as? Date
    }

    /// When the last clean failed, until a clean works again.
    private var lastFailedAttemptDate: Date? {
        ud.object(forKey: Self.lastFailedAttemptKey) as? Date
    }

    init(
        prefs: ScheduledCleaningPreferenceStore = .shared,
        userDefaults: UserDefaults = .standard,
        performClean: (() async -> PurgeStore.ScheduledCleaningSummary)? = nil,
        rearm: (() async -> Void)? = nil,
        isReviewingOrCleaning: (() -> Bool)? = nil
    ) {
        self.prefs = prefs
        self.ud = userDefaults
        self.performCleanOverride = performClean
        self.rearmOverride = rearm
        self.isReviewingOrCleaningOverride = isReviewingOrCleaning
        if let data = ud.data(forKey: Self.lastOutcomeKey) {
            lastOutcome = try? JSONDecoder().decode(LastScheduledCleanOutcome.self, from: data)
        }
    }

    /// Runs the actual clean, through the injected override when present.
    private func performClean() async -> PurgeStore.ScheduledCleaningSummary {
        if let performCleanOverride {
            return await performCleanOverride()
        }
        return await store?.performScheduledClean()
            ?? PurgeStore.ScheduledCleaningSummary(deletedCount: 0, bytesMovedToTrash: 0)
    }

    /// Re-arms the pending reminder, through the injected override when present.
    private func performRearm() async {
        if let rearmOverride {
            await rearmOverride()
        } else {
            await applyScheduleFromPrefs()
        }
    }

    /// Whether a review, a delete confirmation, or a clean is under way, through
    /// the injected override when present.
    private var isReviewingOrCleaning: Bool {
        if let isReviewingOrCleaningOverride {
            return isReviewingOrCleaningOverride()
        }
        return store?.isReviewingOrCleaning ?? false
    }

    /// Moves the anchor, records the outcome, and re-arms, unless the clean removed
    /// nothing because another clean was running, a review was open, or it failed.
    /// Then the clean stays due. A skipped clean runs on the next activation; a
    /// failed one waits out `retryGapAfterFailure` first (#173).
    private func finishSchedule(after summary: PurgeStore.ScheduledCleaningSummary, at now: Date) async {
        guard !summary.skippedForAnotherClean else { return }
        guard !summary.failed else {
            ud.set(now, forKey: Self.lastFailedAttemptKey)
            return
        }
        ud.removeObject(forKey: Self.lastFailedAttemptKey)
        ud.set(now, forKey: Self.lastGraceSweepKey)
        recordOutcome(summary, at: now)
        await performRearm()
    }

    private func recordOutcome(_ summary: PurgeStore.ScheduledCleaningSummary, at date: Date) {
        let outcome = LastScheduledCleanOutcome(
            date: date,
            bytesMovedToTrash: summary.bytesMovedToTrash,
            deletedCount: summary.deletedCount
        )
        lastOutcome = outcome
        if let data = try? JSONEncoder().encode(outcome) {
            ud.set(data, forKey: Self.lastOutcomeKey)
        }
    }

    func attach(store: PurgeStore) {
        self.store = store
        Task { await applyScheduleFromPrefs() }
        observePrefsChanges()
    }

    /// Re-arms when this registrar's own prefs change, and only then. The tests run
    /// inside the app, whose registrar is attached, and they make prefs stores of
    /// their own. Hearing those re-armed the user's real reminder (#171).
    func observePrefsChanges() {
        guard prefsObserver == nil else { return }
        prefsObserver = NotificationCenter.default.addObserver(
            forName: .scheduledCleaningPrefsChanged,
            object: prefs,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.performRearm() }
        }
    }

    /// Checks for a due clean each time Purge comes forward. This lives on the app,
    /// not a window: Purge left running in the menu bar has no window to check from,
    /// and `scenePhase` never changes after launch on macOS, so a due clean used to
    /// wait until a new window opened (#173). Waits for onboarding, like the
    /// window's launch sweep, since onboarding runs its own scan.
    ///
    /// `quitsOnItsOwn` is true while the deleted-apps watcher has Purge open only
    /// for a review. Purge quits as soon as that is done, which would cut a clean
    /// off and leave it out of Cleanup History, so the clean waits for a launch
    /// the user started.
    func observeAppActivation(
        center: NotificationCenter = .default,
        quitsOnItsOwn: @escaping () -> Bool = { false }
    ) {
        guard activationObserver == nil else { return }
        activationCenter = center
        self.quitsOnItsOwn = quitsOnItsOwn
        activationObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.sweepAfterActivation() }
        }
    }

    private func sweepAfterActivation() async {
        guard ud.bool(forKey: FirstRunGate.onboardingCompletedKey), !quitsOnItsOwn() else { return }
        await runGracefulActivationSweepIfPastDue()
    }

    /// False in the unit-test host and in Xcode previews. Both run the app on the
    /// user's real defaults, so an overdue schedule there would clean the user's
    /// real caches.
    nonisolated static func cleansOnActivation(environment: [String: String]) -> Bool {
        !TestHost.isActive(environment: environment)
            && environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
    }

    deinit {
        if let prefsObserver {
            NotificationCenter.default.removeObserver(prefsObserver)
        }
        if let activationObserver {
            activationCenter?.removeObserver(activationObserver)
        }
    }

    /// Anchor the schedule hangs off of: the later of the last clean and the last
    /// time automatic cleaning was turned on, and live `now` before either. Shared
    /// by `nextCleanDate` and the due check so the displayed date and the
    /// activation sweep can never disagree. The last enable counts so that
    /// turning the schedule off for a while and back on starts a fresh interval
    /// instead of running an overdue clean at the next activation (#173).
    func scheduleAnchor(referenceDate now: Date) -> Date {
        // A stamp from a clock that was ahead. Left alone it would outlast real
        // cleans; clamped on each read the anchor would slide with `now` and never
        // come due. Re-stamped once, at `now`, so the schedule runs from here.
        var enabledAt = prefs.enabledAt
        if let stamp = enabledAt, stamp > now {
            prefs.restartSchedule(at: now)
            enabledAt = now
        }
        switch (currentLastGraceSweepDate, enabledAt) {
        case let (lastClean?, enabledAt?): return max(lastClean, enabledAt)
        case let (lastClean?, nil): return lastClean
        case let (nil, enabledAt?): return enabledAt
        case (nil, nil): return now
        }
    }

    /// The moment the next clean becomes due (anchor + one interval), without the
    /// clamp `nextCleanDate` applies for display. After a failed clean this is the
    /// end of the retry gap, if that comes later, so the sweep and Settings agree.
    func dueDate(referenceDate now: Date) -> Date {
        let interval = prefs.effectiveRepeatIntervalSeconds
        let due = scheduleAnchor(referenceDate: now).addingTimeInterval(interval)
        guard let failedAt = lastFailedAttemptDate else { return due }
        return max(due, failedAt.addingTimeInterval(Self.retryGapAfterFailure))
    }

    /// Single source of truth for the next scheduled clean, clamped to `now` once
    /// it is overdue so the UI never shows a past date.
    func nextCleanDate(referenceDate now: Date = Date()) -> Date {
        let candidate = dueDate(referenceDate: now)
        return candidate < now ? now : candidate
    }

    func applyScheduleFromPrefs() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.repeatingReminderIdentifier])

        guard prefs.isEnabled else { return }

        _ = await ScheduledCleanupNotifier.requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Scheduled cleanup due")
        content.body = String(localized: "Open Purge when you’re ready — safe items clear automatically soon after launch.")
        content.sound = .default

        // One-shot reminder anchored to the canonical next-clean date. Re-armed by
        // prefs changes and by the activation sweep, so it stays anchor-accurate
        // instead of restarting on every toggle.
        let secondsUntil = max(60, nextCleanDate().timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secondsUntil, repeats: false)
        let request = UNNotificationRequest(identifier: Self.repeatingReminderIdentifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
        } catch {
            print("ScheduledCleaningRegistrar: repeating notification schedule failed — \(error.localizedDescription)")
        }
    }

    /// Runs the scheduled-clean pipeline immediately, ignoring the due date. Backs
    /// the Settings "Run now" affordance so the schedule can be verified without
    /// waiting out a full interval. Advances the anchor and re-arms exactly like an
    /// activation sweep, so the next scheduled clean moves forward one interval.
    ///
    /// Asked while a sweep is cleaning, it waits and returns that clean's summary.
    /// Settings reads `nil` as "auto-clean is off", which it was not (#173).
    ///
    /// A failed Run now leaves the schedule as it was: before the due date it
    /// stamps nothing, so it never pushes the next scheduled clean back by the
    /// retry gap. On a schedule that is already due it does stamp the failed
    /// attempt, like a sweep would, or the next activation would run the clean
    /// again at once with a second failure notification. Settings shows the
    /// failure either way.
    @discardableResult
    func runScheduledCleanNow(referenceDate now: Date = Date()) async -> PurgeStore.ScheduledCleaningSummary? {
        guard prefs.isEnabled else { return nil }
        guard performCleanOverride != nil || store != nil else { return nil }
        if isSweepRunning {
            return await waitForRunningSweep()
        }

        isSweepRunning = true
        var summary: PurgeStore.ScheduledCleaningSummary?
        defer { finishSweep(with: summary) }

        // The schedule's own due date, not the retry-adjusted one: a failure
        // inside an existing gap refreshes the gap instead of leaving its end in
        // place for the next activation to run the clean again.
        let wasDue = now >= scheduleAnchor(referenceDate: now)
            .addingTimeInterval(prefs.effectiveRepeatIntervalSeconds)
        let result = await performClean()
        summary = result
        if !result.failed || wasDue {
            await finishSchedule(after: result, at: now)
        }
        return result
    }

    /// Runs cleanup whenever the app is foregrounded past the next due date.
    /// macOS has no background scheduling, so this lazy sweep — fired on launch and
    /// on every activation — is what actually executes the schedule. Anchored to the
    /// same due date the UI shows, so an overdue clean runs the next time Purge opens.
    ///
    /// Called while another sweep or Run now is cleaning, it starts no clean of its
    /// own and returns once that one ends. The window scans right after this
    /// returns, and those scans must show the state after the clean.
    ///
    /// A due clean waits while the user is in a review or a delete confirmation, or
    /// a clean is running, and the anchor stays put so the next activation runs it.
    /// Starting then would hold `isDeleting` under the review: a leftover or
    /// uninstall review confirmed during the clean closed without removing
    /// anything or saying why, and a confirmed manual clean could run beside the
    /// scheduled one (#173). A review can also open during the clean's rescan, so
    /// the store checks again before it claims `isDeleting`
    /// (`PurgeStore.mayStartSafeClean(trigger:)`).
    func runGracefulActivationSweepIfPastDue(referenceDate now: Date = Date()) async {
        if isSweepRunning {
            _ = await waitForRunningSweep()
            return
        }
        guard prefs.isEnabled else { return }
        guard performCleanOverride != nil || store != nil else { return }
        guard now >= dueDate(referenceDate: now) else { return }
        guard !isReviewingOrCleaning else { return }

        isSweepRunning = true
        var summary: PurgeStore.ScheduledCleaningSummary?
        defer { finishSweep(with: summary) }

        let result = await performClean()
        summary = result
        await finishSchedule(after: result, at: now)
    }

    /// Returns when the running sweep or Run now ends, with its summary.
    private func waitForRunningSweep() async -> PurgeStore.ScheduledCleaningSummary? {
        await withCheckedContinuation { sweepWaiters.append($0) }
    }

    /// Ends the running sweep and lets every request that waited on it return.
    private func finishSweep(with summary: PurgeStore.ScheduledCleaningSummary?) {
        isSweepRunning = false
        let waiters = sweepWaiters
        sweepWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: summary)
        }
    }
}
