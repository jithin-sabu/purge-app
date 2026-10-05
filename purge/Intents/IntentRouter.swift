import Combine
import Foundation

/// What Purge's App Intents do once they reach the app. The intent types stay
/// thin so the behavior lives here, where tests can drive it with a fake store
/// and without a window.
///
/// Uninstall an App still ends at the review sheet in the window, where the
/// person confirms. Clean Safe Junk does not ask: like the menu bar's Clean, it
/// moves Safe items to the Trash straight away.
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

    /// Scan my Mac: opens the window on the Overview and scans every category,
    /// then answers once App Caches and Dev Tools are done. Large Files and apps
    /// keep scanning in the window. A scan already under way is joined rather
    /// than restarted.
    /// Without Full Disk Access, `scanEverything` runs the limited scan.
    func scanMac() async -> ScanOutcome {
        guard onboardingDone() else {
            reveal()
            return .needsSetup
        }
        // The Overview shows the scan's progress, and its Clean Safe Items
        // button is where the answer leads.
        store.selectedTab = .overview
        reveal()
        guard !store.isDeleting else { return .busyCleaning }
        if store.scanQueue.isRunning {
            // Joining: make sure the answer has a cache scan behind it.
            store.requestScanIfNeeded(.cachesAndDevTools)
        } else {
            store.scanEverything()
        }
        await waitForCacheScan()
        guard store.hasSessionResults(for: .cachesAndDevTools) else { return .stopped }
        return .scanned(safeBytes: store.safeRecoverableBytes)
    }

    /// Returns once App Caches and Dev Tools are neither queued nor running.
    private func waitForCacheScan() async {
        await store.waitUntilSettled(.cachesAndDevTools)
        // The queue stops waiting on a slow cache scan after a while and moves on,
        // and project discovery can run past the step. Neither is done yet.
        for await busy in store.$isScanningAll.combineLatest(store.$isScanningProjects).values
        where !busy.0 && !busy.1 {
            break
        }
    }

    /// Results recent enough to clean from without scanning again: from this
    /// session, newer than the menu bar's freshness window, and gathered with
    /// the access Purge has now.
    private func hasFreshCacheResults(now: Date) -> Bool {
        guard store.hasSessionResults(for: .cachesAndDevTools),
              let scannedAt = store.lastScanCompletedAt else { return false }
        return now.timeIntervalSince(scannedAt) <= MenuViewModel.stalenessWindow
    }

    enum CleanOutcome: Equatable {
        case needsSetup
        case busyCleaning
        case nothingToClean
        /// The scan stopped before App Caches and Dev Tools finished, so nothing
        /// was cleaned.
        case stopped
        case cleaned(bytes: Int64, failedCount: Int)
    }

    /// Clean Safe Junk: what the menu bar's Clean does, run from Spotlight or
    /// Siri. Opens the Overview and cleans Safe items only through the
    /// Overview's Clean Safe Items, which moves them to the Trash and shows the
    /// usual cleaning screen. It does not ask first, matching the menu bar's
    /// Clean: only Safe items move, and the Trash keeps them recoverable.
    ///
    /// Scanning is the slow part, so it scans only when it has to: results from
    /// the last hour are cleaned straight away, a scan already running is
    /// waited on, and otherwise only App Caches and Dev Tools are rescanned,
    /// the part a clean uses. The clean re-checks every item against the
    /// safety rules either way, as the menu bar's does with its saved results.
    func cleanSafeJunk(reduceMotion: Bool, now: Date = Date()) async -> CleanOutcome {
        guard onboardingDone() else {
            reveal()
            return .needsSetup
        }
        store.selectedTab = .overview
        reveal()
        guard !store.isDeleting, !store.isInteractiveSafeCleanupInProgress else { return .busyCleaning }

        let cacheScanRunning = store.isScanningAll
            || store.scanQueue.active == .cachesAndDevTools
            || store.isScanQueued(.cachesAndDevTools)
        if cacheScanRunning {
            await waitForCacheScan()
        } else if !hasFreshCacheResults(now: now) {
            await store.scanThroughQueue(.cachesAndDevTools, forced: true)
            await waitForCacheScan()
        }
        guard store.hasSessionResults(for: .cachesAndDevTools) else { return .stopped }
        guard store.safeRecoverableBytes > 0 else { return .nothingToClean }
        // A clean may have started while this waited on the scan.
        guard !store.isDeleting, !store.isInteractiveSafeCleanupInProgress else { return .busyCleaning }
        guard let clean = store.cleanSafeItemsFromOverview(reduceMotion: reduceMotion) else {
            return .nothingToClean
        }
        let summary = await clean.value
        return .cleaned(bytes: summary.bytesMovedToTrash, failedCount: summary.failedCount)
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
}
