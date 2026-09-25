import AppKit
import Combine
import Foundation
import ServiceManagement

/// Offers a leftovers review when an app leaves the Applications folders outside
/// Purge, usually a Finder drag to the Trash (issue #65).
///
/// Opt-in from Settings, never from onboarding. Watching is done by a background
/// Launch Agent (`io.getpurge.watch`) so removals are caught even when Purge is
/// quit. The agent records the removal and opens Purge with `purge://removed-apps`
/// at once; this type checks that record, drains it, and presents the review
/// sheet. Nothing is removed without the sheet. When the review ends, a window
/// Purge opened for it closes again, so the whole thing reads as one interruption.
///
/// There is no waiting period, so an update that briefly takes a bundle away can
/// reach this type. Three checks keep that from costing the user data: the app
/// must still be gone when the review is built, a live watch withdraws the review
/// the moment the app comes back, and `PurgeStore.confirmRemovedAppLeftovers`
/// checks once more before anything moves.
@MainActor
final class RemovedAppMonitor: ObservableObject {
    static let shared = RemovedAppMonitor()

    private enum UDKeys {
        static let isEnabled = "removedApps.offerLeftoverReview"
        /// Launch argument `-removedApps.allowDevAgent YES` lets a build run from
        /// Xcode register the agent and act on records while testing this feature.
        static let allowDevAgent = "removedApps.allowDevAgent"
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

    private struct Pending {
        let app: InstalledApp
        let fileNumber: UInt64?
    }

    private let ud: UserDefaults
    private weak var store: PurgeStore?
    private var queue: [Pending] = []
    private var phase: Phase = .idle
    /// The removal being prepared, shown, or cleaned.
    private var current: Pending?
    /// True when no Purge window was on screen before the first review in a run.
    private var openedWindowForReview = false
    private var retryTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var needsAnotherDrain = false
    /// Runs only while a review is queued or open, to withdraw it if the app returns.
    private var presenceWatcher: ApplicationsFolderWatcher?
    private var cancellables = Set<AnyCancellable>()

    private var agentService: SMAppService {
        SMAppService.agent(plistName: RemovedAppHandoff.agentPlistName)
    }

    init(userDefaults: UserDefaults = .standard) {
        ud = userDefaults
        isEnabled = userDefaults.bool(forKey: UDKeys.isEnabled)
    }

    /// False in the unit-test host and in builds run from Xcode. Those share the
    /// installed app's defaults, so without this every test run and debug launch
    /// would re-point the login item at a build folder and act on real records.
    private var managesLiveAgent: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return false
        }
        let path = Bundle.main.bundleURL.path
        let isBuildFolder = path.contains("/DerivedData/") || path.contains("/Build/Products/")
        return !isBuildFolder || ud.bool(forKey: UDKeys.allowDevAgent)
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
        // A removal that arrived before Full Disk Access, or before onboarding
        // finished, stays queued. These are the two moments that becomes possible.
        store.$hasFullDiskAccess
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in onNextRunloopTurn { self?.processQueue() } }
            .store(in: &cancellables)
        UserDefaults.standard.publisher(for: \.hasCompletedOnboarding)
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.processQueue() }
            .store(in: &cancellables)

        if isEnabled, managesLiveAgent {
            reconcileAgentRegistration()
            drainPendingRemovals()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        ud.set(enabled, forKey: UDKeys.isEnabled)
        guard managesLiveAgent else { return }
        if enabled {
            reconcileAgentRegistration()
        } else {
            unregisterAgent()
            queue.removeAll()
            RemovedAppHandoff.clearPending()
            if phase == .preparing {
                phase = .idle
                current = nil
            }
            updatePresenceWatch()
        }
    }

    /// Re-reads the agent's Login Items status. Call when Settings appears and when
    /// the app becomes active, so an approval made in System Settings shows up here.
    func refreshAgentStatus() {
        guard isEnabled, managesLiveAgent else {
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

    /// Handles `purge://removed-apps` from the background agent. The URL carries
    /// nothing; it only says a record is waiting.
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

    /// Reads waiting records without deleting them and checks each off the main
    /// thread. A record stays on disk until its review starts, or until it is
    /// decided not to be a removal, so quitting here does not lose it.
    private func drainPendingRemovals() {
        guard isEnabled, managesLiveAgent else { return }
        guard drainTask == nil else {
            needsAnotherDrain = true
            return
        }
        drainTask = Task { [weak self] in
            let checked = await RemovedAppPresence.checkPendingRecords()
            guard let self else { return }
            self.drainTask = nil
            if self.isEnabled {
                for entry in checked {
                    if entry.stillRemoved {
                        self.enqueue(entry.record)
                    } else {
                        RemovedAppHandoff.discard(path: entry.record.path)
                    }
                }
                self.processQueue()
            }
            if self.needsAnotherDrain {
                self.needsAnotherDrain = false
                self.drainPendingRemovals()
            }
        }
    }

    private func enqueue(_ record: RemovedAppHandoff.Record) {
        let app = record.app
        // The bundle is gone, so the uninstaller must stop offering it even if the
        // review itself has to wait.
        store?.forgetRemovedApp(at: app.bundleURL)
        guard !queue.contains(where: { $0.app.id == app.id }), current?.app.id != app.id else { return }
        queue.append(Pending(app: app, fileNumber: record.fileNumber))
        updatePresenceWatch()
    }

    private func processQueue() {
        defer { updatePresenceWatch() }
        guard phase == .idle, let store, !queue.isEmpty else { return }
        // Keep the queue. Onboarding finishing or Full Disk Access being granted
        // calls back into here.
        guard FirstRunGate.hasCompletedOnboarding else { return }
        guard !store.isShowingReviewOrCleaning else {
            scheduleRetry()
            return
        }
        if !store.hasFullDiskAccess {
            store.refreshPermission()
            guard store.hasFullDiskAccess else { return }
        }

        let next = queue.removeFirst()
        RemovedAppHandoff.discard(path: next.app.id)
        phase = .preparing
        current = next
        Task {
            let context = await RemovedAppPresence.reviewContext(for: next.app, fileNumber: next.fileNumber)
            guard phase == .preparing, current?.app.id == next.app.id else { return }
            guard context.stillRemoved,
                  let plan = await store.removedAppLeftoverPlan(
                      for: next.app,
                      survivors: context.survivors,
                      trashedBundleURL: context.trashedBundleURL
                  )
            else {
                guard phase == .preparing, current?.app.id == next.app.id else { return }
                finishReview()
                return
            }
            guard phase == .preparing, current?.app.id == next.app.id else { return }
            guard !store.isShowingReviewOrCleaning else {
                phase = .idle
                current = nil
                queue.insert(next, at: 0)
                scheduleRetry()
                return
            }
            present(plan, in: store)
        }
    }

    /// Waits out another sheet or clean. Cheap: `processQueue` only reads flags
    /// until the window is free.
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

    // MARK: Withdrawing a review

    /// Keeps a watcher running exactly while something is queued, being prepared,
    /// or on screen.
    private func updatePresenceWatch() {
        let needed = isEnabled && (!queue.isEmpty || phase == .preparing || phase == .reviewing)
        if needed, presenceWatcher == nil {
            let watcher = ApplicationsFolderWatcher()
            watcher.onChange = { [weak self] index in
                self?.withdrawReturnedApps(installedBundleIDs: index.bundleIDs)
            }
            watcher.start()
            presenceWatcher = watcher
        } else if !needed, let watcher = presenceWatcher {
            watcher.stop()
            presenceWatcher = nil
        }
    }

    /// Drops every queued or open review whose app is back: an update finished, or
    /// the app was put back from the Trash or moved in from elsewhere.
    private func withdrawReturnedApps(installedBundleIDs: Set<String>) {
        var candidates = queue.map(\.app)
        if let current, phase == .preparing || phase == .reviewing {
            candidates.append(current.app)
        }
        guard !candidates.isEmpty else { return }
        Task {
            let returned = await RemovedAppPresence.returnedApps(
                among: candidates,
                installedBundleIDs: installedBundleIDs
            )
            guard !returned.isEmpty else { return }
            queue.removeAll { returned.contains($0.app.id) }
            returned.forEach { RemovedAppHandoff.discard(path: $0) }
            if let current, returned.contains(current.app.id) {
                switch phase {
                case .preparing:
                    finishReview()
                case .reviewing:
                    // Closing the sheet runs `reviewSheetClosed`, which ends the review.
                    store?.removedAppLeftoverPlan = nil
                case .idle, .cleaning:
                    break
                }
            }
            updatePresenceWatch()
        }
    }

    // MARK: Ending a review

    private func reviewSheetClosed() {
        guard phase == .reviewing, let store else { return }
        if store.manualDeletionSession != nil {
            phase = .cleaning
            updatePresenceWatch()
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
        current = nil
        if queue.isEmpty {
            closeWindowIfOpenedForReview()
            updatePresenceWatch()
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

// MARK: - Presence checks

/// The checks that decide whether an app is still gone, run off the main thread:
/// each one lists the app roots and asks Launch Services about other copies.
nonisolated enum RemovedAppPresence {
    struct CheckedRecord: Sendable {
        let record: RemovedAppHandoff.Record
        let stillRemoved: Bool
    }

    struct ReviewContext: Sendable {
        let stillRemoved: Bool
        let survivors: [InstalledApp]
        let trashedBundleURL: URL?
    }

    /// Every waiting record, each marked with whether it still describes a removal.
    /// A record that fails `RemovedAppWatchPolicy.isValidRecord` never does.
    @concurrent static func checkPendingRecords() async -> [CheckedRecord] {
        let records = RemovedAppHandoff.pending()
        guard !records.isEmpty else { return [] }
        let roots = RemovedAppWatchPolicy.installedAppRoots()
            .map { RemovedAppWatchPolicy.normalizedPath($0.standardizedFileURL.path) }
        let installedIDs = currentIndex().bundleIDs
        return records.map { record in
            let valid = RemovedAppWatchPolicy.isValidRecord(
                path: record.path,
                bundleID: record.bundleID,
                name: record.name,
                roots: roots
            )
            return CheckedRecord(
                record: record,
                stillRemoved: valid && isStillRemoved(record.app, installedBundleIDs: installedIDs)
            )
        }
    }

    /// Everything the review needs, read fresh just before it is built.
    @concurrent static func reviewContext(for app: InstalledApp, fileNumber: UInt64?) async -> ReviewContext {
        let index = currentIndex()
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        return ReviewContext(
            stillRemoved: isStillRemoved(app, installedBundleIDs: index.bundleIDs),
            survivors: Array(index.apps.values),
            trashedBundleURL: RemovedAppWatchPolicy.trashedCopy(fileNumber: fileNumber, in: trash)
        )
    }

    /// Identifiers (bundle paths) of the apps in `candidates` that are back.
    @concurrent static func returnedApps(
        among candidates: [InstalledApp],
        installedBundleIDs: Set<String>
    ) async -> Set<String> {
        Set(candidates.filter { !isStillRemoved($0, installedBundleIDs: installedBundleIDs) }.map(\.id))
    }

    /// The plan as it should be confirmed now, or `nil` when the app is back. Rows
    /// an app installed since the review opened also claims are dropped.
    @concurrent static func revalidate(_ plan: RemovedAppLeftoverPlan) async -> RemovedAppLeftoverPlan? {
        let index = currentIndex()
        guard isStillRemoved(plan.app, installedBundleIDs: index.bundleIDs) else { return nil }
        let survivors = Array(index.apps.values)
        var checked = plan
        checked.items = plan.items.filter { item in
            AppUninstallScanPolicy.claimant(
                forLeftoverName: item.path.lastPathComponent,
                category: item.category,
                ownerID: plan.app.id,
                among: survivors
            ) == nil
        }
        return checked
    }

    private static func currentIndex() -> ApplicationsFolderWatcher.Index {
        ApplicationsFolderWatcher.index(
            roots: RemovedAppWatchPolicy.installedAppRoots(),
            reusing: ApplicationsFolderWatcher.Index()
        )
    }

    private static func isStillRemoved(_ app: InstalledApp, installedBundleIDs: Set<String>) -> Bool {
        RemovedAppWatchPolicy.shouldOfferReview(
            for: app,
            bundleStillExists: FileManager.default.fileExists(atPath: app.bundleURL.path),
            installedBundleIDs: installedBundleIDs,
            otherCopyExists: RemovedAppWatchPolicy.otherCopyExists(of: app),
            removedByPurge: RemovedAppHandoff.isIgnored(path: app.id)
        )
    }
}

private extension RemovedAppHandoff.Record {
    nonisolated var app: InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            bundleID: bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )
    }
}

private extension UserDefaults {
    /// Named after `FirstRunGate.onboardingCompletedKey` so key-value observing
    /// reports that one key, rather than every defaults write in the app.
    @objc nonisolated dynamic var hasCompletedOnboarding: Bool {
        bool(forKey: FirstRunGate.onboardingCompletedKey)
    }
}
