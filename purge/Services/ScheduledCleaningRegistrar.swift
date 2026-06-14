import Foundation
import UserNotifications

/// macOS scheduling: repeating local reminders plus a graceful sweep when the app becomes active.
/// Background processing tasks (`BGTaskScheduler` / `BGProcessingTask`) are not available on macOS.
@MainActor
final class ScheduledCleaningRegistrar {
    static let shared = ScheduledCleaningRegistrar()

    /// Single pending repeating request; aligns with purge bundle conventions.
    static let repeatingReminderIdentifier = "io.getpurge.app.scheduled-clean"

    private static let lastGraceSweepKey = "ScheduledCleaningRegistrar.lastGraceSweep"

    static var lastGraceSweepDate: Date? {
        UserDefaults.standard.object(forKey: lastGraceSweepKey) as? Date
    }

    private weak var store: PurgeStore?
    private var prefsObserver: NSObjectProtocol?

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

    /// Single source of truth for the next scheduled clean.
    /// Anchor priority: the last actual clean wins; before any clean, fall back to
    /// `enabledAt`; live `now` is only a last resort.
    func nextCleanDate(referenceDate now: Date = Date()) -> Date {
        let anchor = ScheduledCleaningRegistrar.lastGraceSweepDate
            ?? ScheduledCleaningPreferenceStore.shared.enabledAt
            ?? now
        let interval = ScheduledCleaningPreferenceStore.shared.frequency.repeatIntervalSeconds
        let candidate = anchor.addingTimeInterval(interval)
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
        Open Purge when you’re ready — if it’s safe by your filters, unused items clear automatically soon after launch.
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

    /// Runs cleanup at most once per frequency interval whenever the window is foregrounded.
    func runGracefulActivationSweepIfPastDue(referenceDate now: Date = Date()) async {
        guard ScheduledCleaningPreferenceStore.shared.isEnabled else { return }
        guard let store else { return }

        let prefs = ScheduledCleaningPreferenceStore.shared
        let last = UserDefaults.standard.object(forKey: Self.lastGraceSweepKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= prefs.frequency.repeatIntervalSeconds else { return }

        _ = await store.performScheduledClean(referenceDate: now)
        UserDefaults.standard.set(Date(), forKey: Self.lastGraceSweepKey)

        Task { await applyScheduleFromPrefs() }
    }
}
