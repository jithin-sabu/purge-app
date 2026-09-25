import AppKit
import Combine
import Foundation
import ServiceManagement

/// Offers a leftovers review when an app leaves the Applications folders outside
/// Purge — usually a Finder drag to the Trash (issue #65).
///
/// Opt-in from Settings, never from onboarding. Watching is done by a background
/// Launch Agent (`io.getpurge.watch`) so removals are caught even when Purge is
/// quit. The agent records the removal and opens Purge with `purge://removed-apps`;
/// this type drains that record and presents the review sheet. Nothing is removed
/// without the sheet. When the review ends, a window Purge opened for it closes
/// again, so the whole thing reads as one interruption.
@MainActor
final class RemovedAppMonitor: ObservableObject {
    static let shared = RemovedAppMonitor()

    private enum UDKeys {
        static let isEnabled = "removedApps.offerLeftoverReview"
    }

    @Published private(set) var isEnabled: Bool
    /// True when the agent is registered but still waiting on Login Items approval.
    @Published private(set) var needsApproval = false
    /// True when the last register/unregister attempt failed.
    @Published private(set) var lastRegistrationFailed = false

    private enum Phase {
        case idle
        case preparing
        case reviewing
        case cleaning
    }

    private let ud: UserDefaults
    private weak var store: PurgeStore?
    private var queue: [InstalledApp] = []
    private var phase: Phase = .idle
    /// True when no Purge window was on screen before the first review in a run.
    private var openedWindowForReview = false
    private var retryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private var agentService: SMAppService {
        SMAppService.agent(plistName: RemovedAppHandoff.agentPlistName)
    }

    init(userDefaults: UserDefaults = .standard) {
        ud = userDefaults
        isEnabled = userDefaults.bool(forKey: UDKeys.isEnabled)
    }

    func attach(store: PurgeStore) {
        self.store = store
        cancellables.removeAll()
        // `@Published` emits before the property changes, so each handler reads the
        // store on the next turn, by which point a confirm has also started its clean.
        store.$removedAppLeftoverPlan
            .map { $0 != nil }
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                onNextRunloopTurn { self?.reviewSheetClosed() }
            }
            .store(in: &cancellables)
        store.$manualDeletionSession
            .map { $0 != nil }
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                onNextRunloopTurn { self?.cleanupSummaryClosed() }
            }
            .store(in: &cancellables)

        if isEnabled {
            reconcileAgentRegistration()
            drainPendingRemovals()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        ud.set(enabled, forKey: UDKeys.isEnabled)
        if enabled {
            reconcileAgentRegistration()
        } else {
            unregisterAgent()
            queue.removeAll()
            if phase == .preparing { phase = .idle }
        }
    }

    /// Re-reads the agent's Login Items status. Call when Settings appears and when
    /// the app becomes active, so an approval made in System Settings shows up here.
    func refreshAgentStatus() {
        guard isEnabled else {
            needsApproval = false
            return
        }
        let status = agentService.status
        needsApproval = status == .requiresApproval
        if status == .enabled { lastRegistrationFailed = false }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Called by Purge's uninstaller before it moves bundles, so the agent does not
    /// open a second review of an app the user has just reviewed.
    func noteRemovalByPurge(of bundleURLs: [URL]) {
        RemovedAppHandoff.ignore(paths: bundleURLs.map { $0.standardizedFileURL.path })
    }

    /// Handles `purge://removed-apps` from the background agent.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "purge" else { return }
        let host = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard host == "removed-apps" else { return }
        drainPendingRemovals()
    }

    // MARK: Agent

    private func reconcileAgentRegistration() {
        do {
            try agentService.register()
            lastRegistrationFailed = false
        } catch {
            // Already registered throws harmlessly; only treat as failure when the
            // agent is still not enabled and not merely waiting for approval.
            if agentService.status != .enabled && agentService.status != .requiresApproval {
                lastRegistrationFailed = true
            }
        }
        refreshAgentStatus()
    }

    private func unregisterAgent() {
        Task {
            do {
                try await agentService.unregister()
                lastRegistrationFailed = false
            } catch {
                lastRegistrationFailed = true
            }
            needsApproval = false
        }
    }

    // MARK: Queue

    private func drainPendingRemovals() {
        guard isEnabled else { return }
        let records = RemovedAppHandoff.drain()
        for record in records {
            enqueue(record)
        }
        processQueue()
    }

    private func enqueue(_ record: RemovedAppHandoff.Record) {
        let app = InstalledApp(
            name: record.name,
            bundleURL: URL(fileURLWithPath: record.path, isDirectory: true),
            bundleID: record.bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )
        guard !queue.contains(where: { $0.id == app.id }) else { return }
        // Drop if another copy with the same id is still installed (moved, not deleted).
        let survivors = ApplicationsFolderWatcher.snapshot(
            roots: RemovedAppWatchPolicy.installedAppRoots(),
            reusing: [:]
        )
        let installedIDs = Set(survivors.values.compactMap { $0.bundleID?.lowercased() })
        guard RemovedAppWatchPolicy.shouldOfferReview(
            for: app,
            bundleStillExists: FileManager.default.fileExists(atPath: app.bundleURL.path),
            installedBundleIDs: installedIDs,
            removedByPurge: RemovedAppHandoff.isIgnored(path: app.id)
        ) else { return }
        queue.append(app)
    }

    private func processQueue() {
        guard phase == .idle, let store, !queue.isEmpty else { return }
        store.refreshPermission()
        guard FirstRunGate.hasCompletedOnboarding, store.hasFullDiskAccess else {
            queue.removeAll()
            return
        }
        guard !store.isShowingReviewOrCleaning else {
            scheduleRetry()
            return
        }

        let app = queue.removeFirst()
        phase = .preparing
        let survivors = Array(
            ApplicationsFolderWatcher.snapshot(
                roots: RemovedAppWatchPolicy.installedAppRoots(),
                reusing: [:]
            ).values
        )
        Task {
            let plan = await store.removedAppLeftoverPlan(for: app, survivors: survivors)
            guard phase == .preparing else { return }
            guard let plan else {
                phase = .idle
                if queue.isEmpty { closeWindowIfOpenedForReview() } else { processQueue() }
                return
            }
            guard !store.isShowingReviewOrCleaning else {
                phase = .idle
                queue.insert(app, at: 0)
                scheduleRetry()
                return
            }
            present(plan, in: store)
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.retryTask = nil
            self?.processQueue()
        }
    }

    private func present(_ plan: RemovedAppLeftoverPlan, in store: PurgeStore) {
        if !openedWindowForReview {
            let window = MainWindowLocator.appWindow(in: NSApp.windows)
            let windowOnScreen = window.map { $0.isVisible || $0.isMiniaturized } ?? false
            openedWindowForReview = !windowOnScreen
        }
        phase = .reviewing
        AppWindowPresenter.reveal()
        onNextRunloopTurn {
            store.removedAppLeftoverPlan = plan
        }
    }

    // MARK: Ending a review

    private func reviewSheetClosed() {
        guard phase == .reviewing, let store else { return }
        if store.manualDeletionSession != nil {
            phase = .cleaning
        } else {
            finishReview()
        }
    }

    private func cleanupSummaryClosed() {
        guard phase == .cleaning else { return }
        finishReview()
    }

    private func finishReview() {
        phase = .idle
        if queue.isEmpty {
            closeWindowIfOpenedForReview()
        } else {
            processQueue()
        }
    }

    private func closeWindowIfOpenedForReview() {
        defer { openedWindowForReview = false }
        guard openedWindowForReview, let store, store.errorMessage == nil else { return }
        MainWindowLocator.appWindow(in: NSApp.windows)?.close()
        NSApp.hide(nil)
    }
}
