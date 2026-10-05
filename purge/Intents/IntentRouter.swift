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
    private let reviewUninstall: (@MainActor () async -> Void)?

    /// `reviewUninstall` stands in for building the uninstall review in tests,
    /// which would otherwise walk the disk for leftovers.
    init(
        store: PurgeStore,
        reveal: @escaping @MainActor () -> Void,
        onboardingDone: @escaping @MainActor () -> Bool,
        reviewUninstall: (@MainActor () async -> Void)? = nil
    ) {
        self.store = store
        self.reveal = reveal
        self.onboardingDone = onboardingDone
        self.reviewUninstall = reviewUninstall
    }

    private func requestUninstallReview() async {
        if let reviewUninstall {
            await reviewUninstall()
        } else {
            await store.requestUninstallSelectedApps()
        }
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

    /// Scan my Mac: scans every category with the window left as it is, then
    /// answers once App Caches and Dev Tools are done. Large Files and apps keep
    /// scanning. A scan already under way is joined rather than restarted.
    /// Without Full Disk Access, `scanEverything` runs the limited scan.
    func scanMac() async -> ScanOutcome {
        guard onboardingDone() else {
            // Setup happens in the window, so that is the one case that opens it.
            reveal()
            return .needsSetup
        }
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

    /// Uninstall an app: opens the uninstaller on that app and then its review
    /// sheet, the same sheet the Uninstall button opens, listing the app and its
    /// leftovers. Nothing is removed until the person confirms there. Without
    /// Full Disk Access the tab asks for it first, and the review waits for them.
    func showUninstaller(appID: String, name: String) async {
        guard onboardingDone() else {
            reveal()
            return
        }
        store.selectedTab = .uninstaller
        store.uninstallSection = .installedApps
        // Replaces any earlier ticks, so the review covers this app alone.
        store.selectedAppIDs = [appID]
        store.uninstallerFocus = UninstallerFocus(appID: appID, name: name)
        reveal()

        store.refreshPermission()
        guard store.hasFullDiskAccess else { return }
        store.requestScanIfNeeded(.apps)
        guard await appIsListed(appID) else { return }
        // The person may have moved on while the list loaded.
        guard store.selectedTab == .uninstaller,
              store.selectedAppIDs == [appID],
              store.uninstallPlan == nil else { return }
        await requestUninstallReview()
    }

    /// Waits for the app list to include the app. False once the list is done
    /// loading without it (a protected app, or one removed since).
    private func appIsListed(_ appID: String) async -> Bool {
        let updates = store.$installedApps
            .combineLatest(store.$isScanningInstalledApps, store.$scanQueue)
            .values
        for await (apps, isScanning, queue) in updates {
            if apps.contains(where: { $0.id == appID }) { return true }
            if !isScanning, queue.active != .apps, !queue.isQueued(.apps) { return false }
        }
        return false
    }

    /// Yes to "Clean it up in Purge?": shows the Overview with its Clean Safe
    /// Items confirmation open. The person still confirms there.
    func reviewSafeClean() {
        guard onboardingDone() else {
            reveal()
            return
        }
        store.selectedTab = .overview
        if store.safeRecoverableBytes > 0, !store.isDeleting {
            store.isSafeCleanConfirmationRequested = true
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
