import Combine
import Foundation
import UserNotifications

/// Outcome of the most recent scheduled clean (including runs that found nothing
/// eligible), persisted so Settings can show what the schedule last did.
struct LastScheduledCleanOutcome: Codable, Equatable {
    let date: Date
    let freedBytes: Int64
    let deletedCount: Int
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

    static var lastGraceSweepDate: Date? {
        UserDefaults.standard.object(forKey: lastGraceSweepKey) as? Date
    }

    @Published private(set) var lastOutcome: LastScheduledCleanOutcome?

    private weak var store: PurgeStore?
    private var prefsObserver: NSObjectProtocol?
    /// The launch `.task` and the scene-activation handler can both find the same
    /// overdue schedule before either advances the anchor (the scan inside the
    /// clean takes a while), producing back-to-back duplicate cleans. One sweep
    /// at a time.
    private var isSweepRunning = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.lastOutcomeKey) {
            lastOutcome = try? JSONDecoder().decode(LastScheduledCleanOutcome.self, from: data)
        }
    }

    private func recordOutcome(_ summary: PurgeStore.ScheduledCleaningSummary, at date: Date) {
        let outcome = LastScheduledCleanOutcome(
            date: date,
            freedBytes: summary.freedBytes,
            deletedCount: summary.deletedCount
        )
        lastOutcome = outcome
        if let data = try? JSONEncoder().encode(outcome) {
            UserDefaults.standard.set(data, forKey: Self.lastOutcomeKey)
        }
    }

    func attach(store: PurgeStore) {
        self.store = store
        Task { await applyScheduleFromPrefs() }

        if prefsObserver == nil {
            prefsObserver = NotificationCenter.default.addObserver(
                forName: .scheduledCleaningPrefsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { await self?.applyScheduleFromPrefs() }
            }
        }
    }

    deinit {
        if let prefsObserver {
            NotificationCenter.default.removeObserver(prefsObserver)
        }
    }

    /// Anchor the schedule hangs off of. The last actual clean wins; before any
    /// clean, fall back to when auto-clean was enabled; live `now` is the last
    /// resort. Shared by `nextCleanDate` and the due check so the displayed date
    /// and the activation sweep can never disagree.
    private func scheduleAnchor(referenceDate now: Date) -> Date {
        ScheduledCleaningRegistrar.lastGraceSweepDate
            ?? ScheduledCleaningPreferenceStore.shared.enabledAt
            ?? now
    }

    /// The moment the next clean becomes due (anchor + one interval), without the
    /// clamp `nextCleanDate` applies for display.
    private func dueDate(referenceDate now: Date) -> Date {
        let interval = ScheduledCleaningPreferenceStore.shared.frequency.repeatIntervalSeconds
        return scheduleAnchor(referenceDate: now).addingTimeInterval(interval)
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

        guard ScheduledCleaningPreferenceStore.shared.isEnabled else { return }

        _ = await ScheduledCleanupNotifier.requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "Scheduled cleanup due"
        content.body = """
        Open Purge when you’re ready — safe items clear automatically soon after launch.
        """
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
    @discardableResult
    func runScheduledCleanNow(referenceDate now: Date = Date()) async -> PurgeStore.ScheduledCleaningSummary? {
        guard ScheduledCleaningPreferenceStore.shared.isEnabled else { return nil }
        guard let store, !isSweepRunning else { return nil }

        isSweepRunning = true
        defer { isSweepRunning = false }

        let summary = await store.performScheduledClean()
        UserDefaults.standard.set(now, forKey: Self.lastGraceSweepKey)
        recordOutcome(summary, at: now)
        await applyScheduleFromPrefs()
        return summary
    }

    /// Runs cleanup whenever the app is foregrounded past the next due date.
    /// macOS has no background scheduling, so this lazy sweep — fired on launch and
    /// on every activation — is what actually executes the schedule. Anchored to the
    /// same due date the UI shows, so an overdue clean runs the next time Purge opens.
    func runGracefulActivationSweepIfPastDue(referenceDate now: Date = Date()) async {
        guard ScheduledCleaningPreferenceStore.shared.isEnabled else { return }
        guard let store, !isSweepRunning else { return }
        guard now >= dueDate(referenceDate: now) else { return }

        isSweepRunning = true
        defer { isSweepRunning = false }

        let summary = await store.performScheduledClean()
        UserDefaults.standard.set(now, forKey: Self.lastGraceSweepKey)
        recordOutcome(summary, at: now)

        Task { await applyScheduleFromPrefs() }
    }
}
