import Combine
import Foundation

/// What Purge's App Intents do once they reach the app. The intent types stay
/// thin so the behavior lives here, where tests can drive it with a fake store
/// and without a window.
///
/// Nothing here deletes anything. Every clean and uninstall still ends at the
/// confirm sheet in the window.
@MainActor
final class IntentRouter {
    static let shared = IntentRouter(
        store: AppEnvironment.store,
        reveal: revealWindow,
        onboardingDone: { FirstRunGate.hasCompletedOnboarding }
    )

    private let store: PurgeStore
    private let reveal: @MainActor () -> Void
    private let onboardingDone: @MainActor () -> Bool

    init(
        store: PurgeStore,
        reveal: @escaping @MainActor () -> Void,
        onboardingDone: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.reveal = reveal
        self.onboardingDone = onboardingDone
    }

    /// The person asked for the window, so it is theirs now: a deleted-app review
    /// that ends later must leave it open, the same as opening Purge from the Dock.
    static func revealWindow() {
        RemovedAppMonitor.shared.userOpenedWindow()
        AppWindowPresenter.reveal()
    }

    enum ScanOutcome: Equatable {
        /// Onboarding is not done, so the window shows that instead of scanning.
        case needsSetup
        /// A clean is running. Scanning waits for it, as the Scan Everything menu does.
        case busyCleaning
        /// App Caches and Dev Tools have results; this much of them is safe to clean.
        case scanned(safeBytes: Int64)
        /// The scan was stopped before App Caches and Dev Tools finished.
        case stopped
    }

    /// Scan my Mac: opens the window and scans every category, then answers once
    /// App Caches and Dev Tools are done. Large Files and apps keep scanning in
    /// the window. A scan already under way is joined rather than restarted.
    /// Without Full Disk Access, `scanEverything` runs the limited scan.
    func scanMac() async -> ScanOutcome {
        reveal()
        guard onboardingDone() else { return .needsSetup }
        guard !store.isDeleting else { return .busyCleaning }
        if store.scanQueue.isRunning {
            // Joining: make sure the answer has a cache scan behind it.
            store.requestScanIfNeeded(.cachesAndDevTools)
        } else {
            store.scanEverything()
        }
        await store.waitUntilSettled(.cachesAndDevTools)
        // The queue stops waiting on a slow cache scan after a while and moves on,
        // and project discovery can run past the step. Neither is done yet.
        for await busy in store.$isScanningAll.combineLatest(store.$isScanningProjects).values
        where !busy.0 && !busy.1 {
            break
        }
        guard store.hasSessionResults(for: .cachesAndDevTools) else { return .stopped }
        return .scanned(safeBytes: store.safeRecoverableBytes)
    }

    /// Uninstall an app: opens the uninstaller with only that app ticked and the
    /// search box set to its name. Nothing is removed until the person reviews
    /// and confirms in the window. Without Full Disk Access the tab asks for it
    /// first, and the tick waits.
    func showUninstaller(appID: String, name: String) {
        if onboardingDone() {
            store.selectedTab = .uninstaller
            store.uninstallSection = .installedApps
            // Replaces any earlier ticks, so Uninstall acts on this app alone.
            store.selectedAppIDs = [appID]
            store.uninstallerFocus = UninstallerFocus(appID: appID, name: name)
        }
        reveal()
    }

    /// Opens the window on a tab. Before onboarding is done the window shows
    /// onboarding instead, so the tab is left alone.
    func open(tab: PurgeStore.Tab) {
        if onboardingDone() {
            store.selectedTab = tab
        }
        reveal()
    }
}
