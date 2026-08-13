import AppKit

/// Connects the app's models and services at launch.
///
/// This work used to live in `WindowGroup`'s `onAppear`, which meant it only ran
/// once a window existed. In menu-bar-only mode the app can launch windowless,
/// and without this the status item would come up dead — no scan state, no
/// scheduled cleaning, no quit guard. It runs from `applicationDidFinishLaunching`
/// instead, so the menu bar works whether or not a window is ever created.
///
/// Appearance stays with the view: `AppAppearance.apply` runs in the delegate
/// (it is `NSApp`-level and matters windowless), but `preferredColorScheme` and
/// the system-theme observer only mean anything when there is a window to repaint.
@MainActor
enum AppBootstrapper {
    private static var hasBootstrapped = false

    /// Idempotent: safe to call from more than one launch path.
    static func bootstrapOnce() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        let env = AppEnvironment.self

        // No `diskStore.refresh()` here: the store refreshes in its own init, and
        // `DiskSummaryRefreshModifier` refreshes again when the window appears.
        // A third read would put the expensive APFS capacity key on the path to
        // first paint for a value that cannot have changed since init.
        env.menuModel.attach(store: env.store)
        MenuScanNotifier.configure()
        ScheduledNotificationPresentationDelegate.shared.onCleanAction = { [weak menuModel = env.menuModel] in
            menuModel?.performCleanFromNotification()
        }
        ScheduledCleaningRegistrar.shared.attach(store: env.store)
        CleaningQuitGuard.isCleaningActive = { [weak store = env.store] in
            store?.isManualCleaningInProgress ?? false
        }
    }
}
