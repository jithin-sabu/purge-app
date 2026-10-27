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
    ///
    /// Does nothing in the unit-test host (#181). It shares the user's real
    /// defaults and files, so the launch scan would walk the real disk, the
    /// registrar would rewrite the real reminders, and the quit guard and
    /// Shortcuts list would act on a test run. A test that needs one of these
    /// attaches it to throwaway defaults itself.
    static func bootstrapOnce() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        guard runsAtLaunch(environment: ProcessInfo.processInfo.environment) else { return }

        let env = AppEnvironment.self

        // No `diskStore.refresh()` here: the store refreshes in its own init, and
        // `DiskSummaryRefreshModifier` refreshes again when the window appears.
        // A third read would put the expensive APFS capacity key on the path to
        // first paint for a value that cannot have changed since init.
        //
        // A Purge the deleted-apps watcher started windowless shows one review
        // and quits, so it skips the launch scan (#177). The menu bar scans on
        // its first open instead, and a window the user opens scans as usual.
        // The last scan's rows, shown dimmed while this launch scans again (#283).
        // Started first so they are up before the menu bar's launch scan lands.
        Task { await env.store.loadLastScan() }
        env.menuModel.attach(store: env.store, scansAtLaunch: !RemovedAppMonitor.startsWindowless)
        MenuScanNotifier.configure()
        ScheduledNotificationPresentationDelegate.shared.onCleanAction = { [weak menuModel = env.menuModel] in
            menuModel?.performCleanFromNotification()
        }
        ScheduledCleaningRegistrar.shared.attach(store: env.store)
        if ScheduledCleaningRegistrar.cleansOnActivation(environment: ProcessInfo.processInfo.environment) {
            ScheduledCleaningRegistrar.shared.observeAppActivation(quitsOnItsOwn: {
                RemovedAppMonitor.shared.quitsWhenDone
            })
        }
        RemovedAppMonitor.shared.attach(store: env.store)
        CleaningQuitGuard.isCleaningActive = { [weak store = env.store] in
            store?.isAnyCleanInProgress ?? false
        }
        WindowCloseQuitter.start()
        // Brings the yearly ledger up to date with what older versions recorded.
        // Read here, before any clean can run, so the counter and History agree.
        let defaults = UserDefaults.standard
        CleanupLedgerStore.shared.reconcile(with: .init(
            history: CleanupHistoryStore.shared.archive.entries,
            lifetimeMovedBytes: env.store.totalMovedToTrashBytes,
            firstSeenAt: defaults.object(forKey: FirstRunGate.firstSeenAtKey) as? Date,
            firstSeenVersion: defaults.string(forKey: FirstRunGate.firstSeenVersionKey),
            appVersion: FirstRunGate.currentAppVersion()
        ))
        // Lets Siri and Spotlight match "Uninstall <app> with Purge" against the
        // apps installed now.
        PurgeAppShortcuts.refreshAppList()

        // Check the installed helper once per app launch. Keeping this here avoids
        // starting registration work just because a view happened to read the
        // preference store during previews or tests.
        let helperPreferences = PrivilegedHelperPreferenceStore.shared
        Task {
            await PrivilegedHelperManager.shared.reconcileVersion()
            helperPreferences.refresh()
        }
    }

    /// False only in the unit-test host. A build run from Xcode is a real launch
    /// and bootstraps like an installed one.
    nonisolated static func runsAtLaunch(environment: [String: String]) -> Bool {
        !TestHost.isActive(environment: environment)
    }
}
