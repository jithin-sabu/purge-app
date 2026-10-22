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
    /// reviews are done, leaving the Mac as the user had it. A due scheduled clean
    /// waits while this is true, since the quit would cut it off (#173).
    private(set) var quitsWhenDone = RemovedAppMonitor.startsWindowless
    /// A review's quit that waits for a clean the user started beside it. Set by
    /// `closeWindowIfOpenedForReview`, acted on when `isDeleting` clears (#173).
    private var quitsOnceCleanEnds = false
    /// Runs the queue again when the store changes while a review waits for the
    /// window. Replaces a poll that ran every two seconds for as long as the
    /// window stayed busy (#177).
    private var windowWaiter: AnyCancellable?
    /// True once the window was shown for a summary or alert left in it, so a
    /// review blocked by it is not shown twice.
    private var revealedForBlockedReview = false
    /// Register and unregister run one after another: turning the watcher off
    /// and on again quickly used to register it, then let the earlier unregister
    /// land on top, with Health still saying Running (#177).
    private var agentTask: Task<Void, Never>?
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
        // A review's quit can wait for a clean the user started beside it (#173).
        store.$isDeleting
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                onNextRunloopTurn { self?.quitIfHeldForClean() }
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
            stopWatchingWhileOff()
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
            // Shown until the registration runs; it may wait for an unregister
            // that is still in flight.
            watcherHealth = .checking
            runAgentWork { [weak self] in
                guard let self, self.isEnabled else { return }
                self.reconcileAgentRegistration()
                // macOS asks for approval in System Settings; take the user there
                // rather than leave them to find the reason in a caption.
                if self.watcherHealth == .needsApproval {
                    self.openLoginItemsSettings()
                }
            }
        } else {
            probeTask?.cancel()
            probeTask = nil
            agentAnswered = nil
            isRestartingWatcher = false
            updateHealth()
            unregisterAgent()
            queue.removeAll()
            stopWaitingForWindow()
            RemovedAppHandoff.clearPending()
            if phase == .preparing {
                phase = .idle
                current = nil
            }
            updatePresenceWatch()
        }
    }

    /// Off means off. An agent macOS still lists while the setting is off (an
    /// unregister that failed, or defaults reset under it) kept starting Purge
    /// windowless after every removal, and that Purge never quit: with the setting
    /// off nothing drained the records, so nothing closed the window either, while
    /// Settings said Off (#177). The agent is unregistered, its records dropped,
    /// and a Purge it started goes away again.
    private func stopWatchingWhileOff() {
        guard !isEnabled, managesLiveAgent else { return }
        RemovedAppHandoff.clearPending()
        runAgentWork { [weak self] in
            guard let self, !self.isEnabled else { return }
            // Read here rather than on the launch path: the status is a call out
            // to launchd, and most launches have nothing to undo.
            guard Self.shouldUnregisterAgent(isEnabled: self.isEnabled, status: self.agentService.status) else { return }
            try? await self.agentService.unregister()
        }
        // Once launch has finished: the quit must not run inside
        // `applicationDidFinishLaunching`.
        onNextRunloopTurn { [weak self] in self?.closeWindowIfOpenedForReview() }
    }

    /// Whether an agent macOS lists should be unregistered: only while the setting
    /// is off. One awaiting approval counts, since approving it later would start
    /// a watcher nobody asked for.
    nonisolated static func shouldUnregisterAgent(isEnabled: Bool, status: SMAppService.Status) -> Bool {
        guard !isEnabled else { return false }
        switch status {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        @unknown default: return false
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
        runAgentWork { [weak self] in
            guard let self else { return }
            try? await self.agentService.unregister()
            guard self.isEnabled else {
                self.isRestartingWatcher = false
                return
            }
            self.agentAnswered = nil
            self.reconcileAgentRegistration()
            if self.watcherHealth == .needsApproval {
                self.isRestartingWatcher = false
                self.openLoginItemsSettings()
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
        quitsOnceCleanEnds = false
    }

    /// Handles `purge://removed-apps` from the background agent. The URL carries
    /// nothing; it only says a record is waiting.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "purge" else { return }
        let host = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard host == "removed-apps" else { return }
        guard isEnabled else {
            // Opened by an agent that should not be running.
            stopWatchingWhileOff()
            return
        }
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
        runAgentWork { [weak self] in
            // Turned on again before this ran: the agent stays as it is, and the
            // registration queued behind this finds it already there.
            guard let self, !self.isEnabled else { return }
            do {
                try await self.agentService.unregister()
                self.lastRegistrationFailed = false
            } catch {
                self.lastRegistrationFailed = true
            }
            self.updateHealth()
        }
    }

    /// Runs `work` once every register or unregister asked for before it is done.
    private func runAgentWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = agentTask
        agentTask = Task { @MainActor in
            await previous?.value
            await work()
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
    /// thread. A record stays on disk until its review has been dismissed or its
    /// clean is done (`finishReview`), or until it is decided not to be a removal,
    /// so quitting before then does not lose it.
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
                // Read again here, on the main actor: a review dismissed while
                // the check ran has discarded its record, and the check's copy of
                // it must not open that review a second time.
                let stillPending = Set(RemovedAppHandoff.pending().map(\.path))
                for entry in checked where stillPending.contains(entry.record.path) {
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
        // A new removal is a new reason to show what blocks its review.
        revealedForBlockedReview = false
        updatePresenceWatch()
    }

    private func processQueue() {
        defer { updatePresenceWatch() }
        guard phase == .idle, let store, !queue.isEmpty else {
            stopWaitingForWindow()
            return
        }
        // Keep the queue. Onboarding finishing or Full Disk Access being granted
        // calls back into here.
        guard FirstRunGate.hasCompletedOnboarding else { return }
        // Closing it runs the queue again (see `attach`).
        guard !store.isLookDeeperPresented else { return }
        guard !store.isShowingReviewOrCleaning else {
            waitForWindow(in: store)
            return
        }
        if !store.hasFullDiskAccess {
            store.refreshPermission()
            guard store.hasFullDiskAccess else {
                showWindowForAccess()
                return
            }
        }

        stopWaitingForWindow()
        let next = queue.removeFirst()
        // Its record stays on disk until the review is over (`finishReview`), so
        // a Purge quit while the review waits for the window, or while it is up,
        // shows it again at the next launch.
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
                waitForWindow(in: store)
                return
            }
            present(plan, in: store)
        }
    }

    /// Waits for the window to be free. The store's next change runs the queue
    /// again, at most once a second, and nothing runs while nothing changes. A
    /// summary or alert left in a closed window never changes on its own, so the
    /// window is shown once for it: the user dismisses it, and the review follows.
    /// A clean with no window (scheduled, or from the menu bar) is waited out
    /// instead; its end is a change. A poll used to run every two seconds for as
    /// long as the window stayed busy, and never showed the window (#177).
    private func waitForWindow(in store: PurgeStore) {
        if windowWaiter == nil {
            windowWaiter = store.objectWillChange
                .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in
                    // `objectWillChange` fires before the value changes.
                    onNextRunloopTurn { self?.processQueue() }
                }
        }
        guard !revealedForBlockedReview, !store.isAnyCleanInProgress, !Self.appWindowIsOnScreen else { return }
        revealedForBlockedReview = true
        // Closed again with the review once it is over, like a window opened for
        // the review itself.
        openedWindowForReview = true
        AppWindowPresenter.reveal()
    }

    private func stopWaitingForWindow() {
        windowWaiter = nil
        revealedForBlockedReview = false
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
        } else if store.takeRemovedAppReviewHeldForAnotherClean(), let current {
            // Confirmed while another clean ran (#173). Back to the front of the
            // queue: `processQueue` waits for that clean and the alert, then shows
            // the review again with the leftovers as they are then.
            queue.insert(current, at: 0)
            finishReview(keepingRecord: true)
        } else {
            finishReview()
        }
    }

    private func cleanupSummaryClosed() {
        guard phase == .cleaning else { return }
        if store?.takeLeftoverCleanupFailure() == true, let current {
            // The clean failed as a whole, and its alert says to try again, which
            // only this monitor can offer: back to the front of the queue with
            // its record, to open again once the alert is dismissed. Dismissing
            // the review then is what ends it.
            queue.insert(current, at: 0)
            finishReview(keepingRecord: true)
            return
        }
        finishReview()
    }

    /// Ends the review of `current`. Its record goes here, once the review has
    /// been dismissed or cleaned, or decided against, and not before: a record
    /// discarded as the review was built was lost whenever Purge quit while the
    /// review still waited for the window (#177). A review put back in the queue
    /// keeps its record.
    private func finishReview(keepingRecord: Bool = false) {
        if !keepingRecord, let current {
            RemovedAppHandoff.discard(path: current.app.id)
        }
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
        // A review on screen, or its clean, keeps the window: `finishReview`
        // comes back here once it is over. A watcher URL arriving after the
        // setting was switched off must not quit under an open sheet.
        guard phase == .idle else { return }
        defer { openedWindowForReview = false }
        guard openedWindowForReview, let store else { return }
        guard store.errorMessage == nil else {
            // The alert needs the window, so both stay. The window is the user's
            // from here, as after `userOpenedWindow`: a quit kept for a later
            // review would end a Purge they went on using (#177).
            quitsWhenDone = false
            quitsOnceCleanEnds = false
            return
        }
        if let window = MainWindowLocator.appWindow(in: NSApp.windows) {
            WindowCloseQuitter.closeWithoutQuitting(window)
        }
        // In on-demand mode there is no menu bar icon to come back to, so a
        // windowless Purge left running would only be a Dock icon.
        switch RemovedAppWatchPolicy.reviewWindowExit(
            quitsWhenDone: quitsWhenDone,
            showsMenuBarIcon: StartupPreferenceStore.persistedShowsMenuBarIcon(),
            cleanInProgress: store.isAnyCleanInProgress
        ) {
        case .quit:
            quitsWhenDone = false
            NSApp.terminate(nil)
        case .quitAfterClean:
            quitsWhenDone = false
            quitsOnceCleanEnds = true
        case .hide:
            NSApp.hide(nil)
        }
    }

    /// Runs when `isDeleting` clears. The quit a finished review wanted waits here
    /// while a clean the user started runs beside it, so the quit guard never
    /// asks about a quit nobody started. A window the user brought back in the
    /// meantime means Purge is in use, and the quit is dropped.
    private func quitIfHeldForClean() {
        guard quitsOnceCleanEnds, let store, !store.isAnyCleanInProgress else { return }
        quitsOnceCleanEnds = false
        guard !Self.appWindowIsOnScreen else { return }
        NSApp.terminate(nil)
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

    static let problemTitle = String(localized: "Deleted-app reviews paused")

    var problemMessage: String? {
        switch self {
        case .needsApproval:
            return String(localized: "macOS is stopping Purge from running in the background. In System Settings, open Login Items and switch Purge on.")
        case .notRunning:
            return String(localized: "Purge's background watcher isn't running, so deleted apps go unnoticed.")
        case .failedToStart:
            return String(localized: "Purge couldn't start its background watcher, so deleted apps go unnoticed.")
        case .off, .checking, .running:
            return nil
        }
    }

    /// The same problem in a line, for the sidebar notice.
    var shortMessage: String? {
        switch self {
        case .needsApproval: return String(localized: "macOS is blocking Purge's background watcher, so deleted apps go unnoticed.")
        case .notRunning: return String(localized: "The background watcher isn't running, so deleted apps go unnoticed.")
        case .failedToStart: return String(localized: "The background watcher couldn't start, so deleted apps go unnoticed.")
        case .off, .checking, .running: return nil
        }
    }

    var fixTitle: String? {
        switch self {
        case .needsApproval: return String(localized: "Open System Settings")
        case .notRunning: return String(localized: "Restart Watcher")
        case .failedToStart: return String(localized: "Try Again")
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
        let appGroupClaims = AppGroupClaims.gather(for: survivors, leftovers: plan.items)
        var checked = plan
        checked.items = plan.items.filter { item in
            AppUninstallScanPolicy.claimant(
                forLeftoverName: item.path.lastPathComponent,
                category: item.category,
                ownerID: plan.app.id,
                among: survivors,
                appGroupClaims: appGroupClaims
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
