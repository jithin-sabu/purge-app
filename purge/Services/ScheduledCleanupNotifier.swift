import UserNotifications

enum ScheduledCleanupNotifier {
    static func requestAuthorizationIfNeeded() async -> Bool {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }

    static func notifyNothingEligible() async {
        await deliver(title: "Scheduled clean finished", body: "Nothing matched your safe settings yet. We’ll try again later.")
    }

    static func notifyScheduledCleanFinished(bytesMovedToTrash: Int64, deletedCount: Int) async {
        let space = formatBytes(bytesMovedToTrash)
        let noun = deletedCount == 1 ? "item" : "items"
        await deliver(
            title: "Scheduled clean finished",
            body: "Moved \(deletedCount) \(noun) to Trash, about \(space). Empty the trash to reclaim the space."
        )
    }

    static func notifyScheduledCleanFailed() async {
        await deliver(
            title: "Scheduled clean",
            body: "Something went wrong during the automated clean. Open Purge when you get a chance to try again."
        )
    }

    private static func deliver(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.75, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().add(request) { _ in cont.resume() }
        }
    }
}

/// Shows banners while the Purge window is visible and routes notification
/// actions (currently the menu-scan Clean button) back into the app.
final class ScheduledNotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ScheduledNotificationPresentationDelegate()

    /// Invoked on the main actor when the menu-scan Clean action is tapped.
    var onCleanAction: (@MainActor () -> Void)?

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == MenuScanNotifier.cleanActionIdentifier {
            let handler = onCleanAction
            Task { @MainActor in handler?() }
        }
        completionHandler()
    }
}
