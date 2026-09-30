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
    }

    @Published private(set) var isEnabled: Bool
    /// Whether the background watcher is really running, for Settings and the
    /// sidebar notice. A blocked or stopped watcher misses every removal without a
    /// sound, so this is the only way the user learns reviews have stopped.
    @Published private(set) var watcherHealth: WatcherHealth = .off
    /// True from "Restart Watcher" until the check after it ends.
    @Published private(set) var isRestartingWatcher = false

    /// True when the last register/unregister attempt failed.
    private var lastRegistrationFailed = false
    /// Whether the agent answered the last check. Nil until a check ends.
    private var agentAnswered: Bool?
    /// Whether the agent has answered the check that is running now.
    private var answeredDuringProbe = false
    private var probeTask: Task<Void, Never>?

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
    /// Cleared when the user opens the window themselves (`userOpenedWindow`).
    private var openedWindowForReview = RemovedAppMonitor.startsWindowless
    /// True when the watcher started Purge for this: it quits again once the
    /// reviews are done, leaving the Mac as the user had it.
    private var quitsWhenDone = RemovedAppMonitor.startsWindowless
    private var retryTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var needsAnotherDrain = false
    /// Runs only while a review is queued or open, to withdraw it if the app returns.
    private var presenceWatcher: ApplicationsFolderWatcher?
    private var cancellables = Set<AnyCancellable>()

    private var agentService: SMAppService {
        SMAppService.agent(plistName: RemovedAppHandoff.agentPlistName)
    }

    /// The watcher started Purge to review a removal (`openPurge` in the agent).
    static let launchedForReview = UserDefaults.standard.bool(forKey: RemovedAppHandoff.launchedForReviewKey)

    /// Such a launch starts without its window, unless onboarding still needs it.
    static let startsWindowless = launchedForReview && FirstRunGate.hasCompletedOnboarding

    init(userDefaults: UserDefaults = .standard) {
        ud = userDefaults
        isEnabled = userDefaults.bool(forKey: UDKeys.isEnabled)
    }

    private var managesLiveAgent: Bool {
        Self.managesLiveAgent(environment: ProcessInfo.processInfo.environment)
    }

    /// False only in the unit-test host. It shares the real defaults, so without
    /// this every test run would register the login item from a build folder and
    /// act on real removal records. A build run from Xcode is a real launch and
    /// works like an installed one; that is how this feature is tried before a
    /// signed release carries it.
    nonisolated static func managesLiveAgent(environment: [String: String]) -> Bool {
        !TestHost.isActive(environment: environment)
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
        // Access usually lands while the look-deeper sheet is up, which closes when
        // it does. The review waits for that sheet to close so there is only ever
        // one on screen. Closing it without access leaves the queue alone, or
        // the sheet would come straight back.
        store.$isLookDeeperPresented
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                onNextRunloopTurn {
                    guard let self, self.store?.hasFullDiskAccess == true else { return }
                    self.processQueue()
                }
            }
            .store(in: &cancellables)
        UserDefaults.standard.publisher(for: \.hasCompletedOnboarding)
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.processQueue() }
            .store(in: &cancellables)
        // An approval made in System Settings, or a watcher that stopped while
        // Purge was in the background, shows up the next time Purge comes forward.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshAgentStatus() }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: RemovedAppHandoff.agentPongNotification)
            .compactMap { $0.object as? String }
            .receive(on: RunLoop.main)
            .sink { [weak self] path in self?.agentAnswered(from: path) }
            .store(in: &cancellables)

        if isEnabled, managesLiveAgent {
            reconcileAgentRegistration()
            drainPendingRemovals()
        } else {
            updateHealth()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        ud.set(enabled, forKey: UDKeys.isEnabled)
        guard managesLiveAgent else {
            updateHealth()
            return
        }
        if enabled {
            agentAnswered = nil
            reconcileAgentRegistration()
            // macOS asks for approval in System Settings; take the user there
            // rather than leave them to find the reason in a caption.
            if watcherHealth == .needsApproval {
                openLoginItemsSettings()
            }
        } else {
            probeTask?.cancel()
            probeTask = nil
            agentAnswered = nil
            isRestartingWatcher = false
            updateHealth()
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

    /// Re-reads the agent's Login Items status and checks the agent answers.
    /// Runs when Purge comes forward and when Settings appears.
    func refreshAgentStatus() {
        guard isEnabled, managesLiveAgent else {
            updateHealth()
            return
        }
        let status = agentService.status
        if status == .enabled { lastRegistrationFailed = false }
        // Switched off in System Settings: an answer from before says nothing now.
        if status == .requiresApproval { agentAnswered = nil }
        updateHealth()
        probeAgent()
    }

    /// Registers the agent again from scratch: the fix offered when it is not
    /// running. A watcher launchd stopped restarting starts again this way.
    func restartWatcher() {
        guard isEnabled, managesLiveAgent, !isRestartingWatcher else { return }
        isRestartingWatcher = true
        probeTask?.cancel()
        probeTask = nil
        Task {
            try? await agentService.unregister()
            guard isEnabled else {
                isRestartingWatcher = false
                return
            }
            agentAnswered = nil
            reconcileAgentRegistration()
            if watcherHealth == .needsApproval {
                isRestartingWatcher = false
                openLoginItemsSettings()
            }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Called by Purge's uninstaller before it moves bundles, so the agent does not
    /// open a second review of an app the user has just reviewed.
    func noteRemovalByPurge(of bundleURLs: [URL]) {
        RemovedAppHandoff.ignore(paths: bundleURLs.map { $0.standardizedFileURL.path })
    }

    /// The user opened Purge's window themselves: from the Dock, Finder, Spotlight,
    /// or the menu bar. The window is theirs now, so ending a review leaves it open
    /// and does not quit.
    func userOpenedWindow() {
        openedWindowForReview = false
        quitsWhenDone = false
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
        announceAgentOwner()
        refreshAgentStatus()
    }

    /// Tells an agent started from another copy of Purge to exit, so launchd
    /// starts this one's. See `RemovedAppHandoff.agentOwnerNotification`.
    private func announceAgentOwner() {
        let agent = RemovedAppHandoff.agentExecutable(inApp: Bundle.main.bundleURL)
        DistributedNotificationCenter.default().postNotificationName(
            RemovedAppHandoff.agentOwnerNotification,
            object: agent.resolvingSymlinksInPath().path,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func unregisterAgent() {
        Task {
            do {
                try await agentService.unregister()
                lastRegistrationFailed = false
            } catch {
                lastRegistrationFailed = true
            }
            updateHealth()
        }
    }

    // MARK: Watcher health

    /// Checks attempted before the agent counts as not running. After an update
    /// the old agent needs two of its 10-second checks to see it was replaced,
    /// then launchd starts the new one, so this allows 45 seconds.
    private static let probeAttempts = 15
    private static let probeInterval: Duration = .seconds(3)

    /// Asks the agent to answer, repeating until it does or the attempts run out.
    /// The last known answer stands while a check runs, so nothing flickers.
    private func probeAgent() {
        guard isEnabled, managesLiveAgent, probeTask == nil else { return }
        answeredDuringProbe = false
        probeTask = Task { [weak self] in
            for _ in 0..<Self.probeAttempts {
                guard let self, !Task.isCancelled else { return }
                if self.answeredDuringProbe || !self.isEnabled { break }
                DistributedNotificationCenter.default().postNotificationName(
                    RemovedAppHandoff.agentPingNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                try? await Task.sleep(for: Self.probeInterval)
            }
            guard let self, !Task.isCancelled else { return }
            self.probeTask = nil
            self.isRestartingWatcher = false
            if self.isEnabled, !self.answeredDuringProbe {
                self.agentAnswered = false
            }
            self.updateHealth()
        }
    }

    /// An answer from an agent in another copy of Purge does not count: that one
    /// exits once it hears which copy owns the agent.
    private func agentAnswered(from path: String) {
        let ownAgent = RemovedAppHandoff.agentExecutable(inApp: Bundle.main.bundleURL).path
        // The agent reports `realpath`, which keeps `/private` on `/tmp` and `/var`
        // paths; `resolvingSymlinksInPath` drops it, so both sides go through `realpath`.
        guard isEnabled, Self.realPath(path) == Self.realPath(ownAgent) else { return }
        answeredDuringProbe = true
        agentAnswered = true
        isRestartingWatcher = false
        updateHealth()
    }

    private nonisolated static func realPath(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    private func updateHealth() {
        let live = isEnabled && managesLiveAgent
        watcherHealth = Self.watcherHealth(
            isEnabled: live,
            status: live ? agentService.status : .notRegistered,
            registrationFailed: lastRegistrationFailed,
            agentAnswered: agentAnswered
        )
    }

    /// Reads the watcher's state from what macOS reports and whether the agent
    /// answered. An answer means it is watching, whatever else is reported;
    /// silence only counts once a whole check has gone unanswered.
    nonisolated static func watcherHealth(
        isEnabled: Bool,
        status: SMAppService.Status,
        registrationFailed: Bool,
        agentAnswered: Bool?
    ) -> WatcherHealth {
        guard isEnabled else { return .off }
        if agentAnswered == true { return .running }
        if status == .requiresApproval { return .needsApproval }
        if registrationFailed || status == .notRegistered || status == .notFound { return .failedToStart }
        return agentAnswered == false ? .notRunning : .checking
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
            } else if self.queue.isEmpty, self.phase == .idle {
                // Nothing to review after all: the app came back, or the record
                // was not a removal. A Purge started for it goes away again.
                self.closeWindowIfOpenedForReview()
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
        // Closing it runs the queue again (see `attach`).
        guard !store.isLookDeeperPresented else { return }
        guard !store.isShowingReviewOrCleaning else {
            scheduleRetry()
            return
        }
        if !store.hasFullDiskAccess {
            store.refreshPermission()
            guard store.hasFullDiskAccess else {
                showWindowForAccess()
                return
            }
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
            guard !store.isShowingReviewOrCleaning, !store.isLookDeeperPresented else {
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
            openedWindowForReview = !Self.appWindowIsOnScreen
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

    /// A Purge with no window on screen (started by the watcher, or at login in
    /// menu-bar-only mode) cannot show a review without Full Disk Access. Showing
    /// the window puts the access prompt in front of the user instead of leaving
    /// an invisible app holding the removal; it stays open.
    /// Leftovers live in folders only Full Disk Access can see, so the review waits
    /// in the queue and the window asks. Granting access runs the queue.
    private func showWindowForAccess() {
        openedWindowForReview = false
        quitsWhenDone = false
        store?.isLookDeeperPresented = true
        guard !Self.appWindowIsOnScreen else { return }
        AppWindowPresenter.reveal()
    }

    private static var appWindowIsOnScreen: Bool {
        let window = MainWindowLocator.appWindow(in: NSApp.windows)
        return window.map { $0.isVisible || $0.isMiniaturized } ?? false
    }

    private func closeWindowIfOpenedForReview() {
        defer { openedWindowForReview = false }
        guard openedWindowForReview, let store, store.errorMessage == nil else { return }
        if let window = MainWindowLocator.appWindow(in: NSApp.windows) {
            WindowCloseQuitter.closeWithoutQuitting(window)
        }
        // In on-demand mode there is no menu bar icon to come back to, so a
        // windowless Purge left running would only be a Dock icon.
        if quitsWhenDone || !StartupPreferenceStore.persistedShowsMenuBarIcon() {
            quitsWhenDone = false
            NSApp.terminate(nil)
        } else {
            NSApp.hide(nil)
        }
    }
}

// MARK: - Watcher health

/// The background watcher's state, as Settings and the sidebar describe it.
nonisolated enum WatcherHealth: Equatable, Sendable {
    /// Deleted-app reviews are turned off.
    case off
    /// Turned on, and the first check has not ended yet.
    case checking
    /// The watcher answered: removals are being noticed.
    case running
    /// Switched off under Login Items in System Settings, or never approved there.
    case needsApproval
    /// Allowed, but the watcher did not answer: crashed, or launchd stopped
    /// restarting it.
    case notRunning
    /// macOS did not register the watcher.
    case failedToStart

    /// Removals are being missed, and the user can do something about it.
    var needsAttention: Bool {
        switch self {
        case .needsApproval, .notRunning, .failedToStart: return true
        case .off, .checking, .running: return false
        }
    }

    static let problemTitle = "Deleted-app reviews paused"

    var problemMessage: String? {
        switch self {
        case .needsApproval:
            return "macOS is stopping Purge from running in the background. In System Settings, open Login Items and switch Purge on."
        case .notRunning:
            return "Purge's background watcher isn't running, so deleted apps go unnoticed."
        case .failedToStart:
            return "Purge couldn't start its background watcher, so deleted apps go unnoticed."
        case .off, .checking, .running:
            return nil
        }
    }

    /// The same problem in a line, for the sidebar notice.
    var shortMessage: String? {
        switch self {
        case .needsApproval: return "macOS is blocking Purge's background watcher, so deleted apps go unnoticed."
        case .notRunning: return "The background watcher isn't running, so deleted apps go unnoticed."
        case .failedToStart: return "The background watcher couldn't start, so deleted apps go unnoticed."
        case .off, .checking, .running: return nil
        }
    }

    var fixTitle: String? {
        switch self {
        case .needsApproval: return "Open System Settings"
        case .notRunning: return "Restart Watcher"
        case .failedToStart: return "Try Again"
        case .off, .checking, .running: return nil
        }
    }
}

extension RemovedAppMonitor {
    /// The one action that fixes the current problem.
    func fixWatcher() {
        switch watcherHealth {
        case .needsApproval: openLoginItemsSettings()
        case .notRunning, .failedToStart: restartWatcher()
        case .off, .checking, .running: break
        }
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
