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

    func applyScheduleFromPrefs() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.repeatingReminderIdentifier])

        guard ScheduledCleaningPreferenceStore.shared.isEnabled else { return }

        _ = await ScheduledCleanupNotifier.requestAuthorizationIfNeeded()

        let prefs = ScheduledCleaningPreferenceStore.shared
        var interval = prefs.frequency.repeatIntervalSeconds
        if interval < 60 { interval = 60 }

        let content = UNMutableNotificationContent()
        content.title = "Scheduled cleanup due"
        content.body = """
        Open Purge when you’re ready — if it’s safe by your filters, unused items clear automatically soon after launch.
        """
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: true)
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
