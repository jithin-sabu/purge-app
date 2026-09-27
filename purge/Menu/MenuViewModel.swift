import AppKit
import Combine
import Foundation
import SwiftUI

/// Live state for the menu bar dropdown. Never render `clear` or `ready`
/// without a backing scan: the cold/default state is `checking`.
enum MenuState: Equatable {
    case checking
    case clear(lastScanned: Date)
    case ready(bytes: Int64, lastScanned: Date)
    case cleaning(cleaned: Int64, total: Int64)
    case cleaned(bytes: Int64)
}

/// Owns the menu's live state and timing. Reuses `PurgeStore`'s existing scan
/// and clean entry points; it never reimplements scanning or deletion, so the
/// `DeletionSafetyPolicy` allowlist and trash-by-default path stay intact.
@MainActor
final class MenuViewModel: ObservableObject {
    /// Single source of truth for how long a cached scan stays fresh. Opening
    /// the menu always shows the cached result; past this age it also kicks off
    /// a silent background refresh that updates the number in place.
    static let stalenessWindow: TimeInterval = 60 * 60
    /// How long the "cleaned" hero dwells before settling back to "all clear".
    private static let cleanedDwellNanoseconds: UInt64 = 1_800_000_000
    /// One spring for every hero state swap (and the checking word cycle) so
    /// the whole menu moves with the same soft, non-bouncy feel.
    static let swapAnimation = Animation.spring(response: 0.4, dampingFraction: 0.9)

    @Published private(set) var state: MenuState = .checking

    /// The dropdown panel window, handed over by `MenuOpenDetector`. When a
    /// menu-initiated scan or notification-initiated clean resolves while the
    /// panel is closed, the outcome is surfaced as a notification instead.
    weak var panelWindow: NSWindow?
    /// True between a menu "Scan now" click and its resolution.
    private var menuScanArmed = false
    /// True between the notification Clean action and the cleaned state.
    private var cleanFromNotification = false

    private weak var store: PurgeStore?
    private var hasAttached = false
    private var wakeObserver: NSObjectProtocol?
    /// The in-flight scan or clean. Cancelled when superseded.
    private var activeWorkTask: Task<Void, Never>?
    /// Silent rescan that never leaves the ready/clear state. Cancelled when a
    /// forced scan or clean supersedes it.
    private var backgroundRefreshTask: Task<Void, Never>?
    /// `lastScanCompletedAt` is persisted across launches but scan results are
    /// not, so a cached number is only renderable after a scan this session.
    private var hasSessionScan = false
    private var cancellables = Set<AnyCancellable>()
    /// True once `isScanningAll` has been observed high, so the subscription
    /// only settles state on real completions, not on the initial `false`.
    private var storeScanWasInFlight = false

    /// True while a scan or clean is in flight; gates re-entrant scans/cleans.
    var isBusy: Bool {
        switch state {
        case .checking, .cleaning, .cleaned: return true
        case .clear, .ready: return store?.isDeleting ?? false
        }
    }

    /// Wires up the store and performs the one-time launch scan + wake observer.
    /// Idempotent: safe to call from multiple lifecycle hooks.
    func attach(store: PurgeStore) {
        guard !hasAttached else { return }
        hasAttached = true
        self.store = store
        registerWakeObserver()
        observeStoreScans(store)
        // Scan on app launch.
        runScan(forced: true)
    }

    /// `PurgeStore.scanAll` cancels-and-restarts any in-flight scan, so the
    /// menu's own `await` can return early with partial data when another
    /// caller (main window, onboarding) supersedes its scan — resolving there
    /// would render "all clear" off an empty snapshot. Completion is derived
    /// from the store's published flag instead: the menu only settles on
    /// numbers from a scan that actually finished, whoever started it.
    private func observeStoreScans(_ store: PurgeStore) {
        store.$isScanningAll
            // A supersession dips the flag false for one beat between the
            // cancelled scan's teardown and the new scan's start; debouncing
            // rides over the dip so only a settled completion resolves state.
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] isScanning in
                guard let self else { return }
                if isScanning {
                    storeScanWasInFlight = true
                    return
                }
                guard storeScanWasInFlight else { return }
                storeScanWasInFlight = false
                // Cleaning owns its own state flow; everything else settles
                // to the fresh numbers (including the first `.checking`).
                switch state {
                case .checking, .ready, .clear: resolveAfterScan()
                case .cleaning, .cleaned: break
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func registerWakeObserver() {
        // Refresh on wake, but only when the cached scan has gone stale.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAfterWake() }
        }
    }

    /// Wake is opportunistic, not user-initiated: keep the cached number and
    /// only refresh silently when it is stale, so repeated lid-opens never turn
    /// into repeated full disk scans. Skipped entirely in Low Power Mode — the
    /// next menu open still refreshes, so the user never sees stale data.
    private func refreshAfterWake() {
        guard let store, hasSessionScan, !isBusy else { return }
        guard let scannedAt = store.lastScanCompletedAt,
              Date().timeIntervalSince(scannedAt) > Self.stalenessWindow else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        startBackgroundRefresh()
    }

    /// Called whenever the menu panel becomes visible/key.
    /// Always shows the cached result immediately; when the cache is stale it
    /// additionally refreshes in the background, updating the number in place.
    /// Only falls back to a blocking scan when there is nothing to show yet.
    func menuDidOpen() {
        guard let store else { return }
        // A finished scan can be invisible here: completion arrives via a
        // debounced sink on RunLoop.main, and menu tracking stalls the main
        // queue — opening the menu inside that window (or holding it open
        // through completion) leaves state stuck at `.checking` even though
        // the store already has results. Resolve synchronously off the store
        // so opening always shows a finished scan immediately.
        if case .checking = state,
           !store.isScanningAll,
           activeWorkTask == nil, backgroundRefreshTask == nil,
           store.lastScanCompletedAt != nil {
            resolveAfterScan(animated: false)
        }
        guard !isBusy else { return }
        guard hasSessionScan, let scannedAt = store.lastScanCompletedAt else {
            runScan(forced: false)
            return
        }
        // Never animate at open time: this fires before the panel is laid out,
        // and an animated transaction would capture the initial layout pass and
        // scale the whole panel in from a corner. Animations are only for
        // changes that happen while the panel is already visible.
        resolveFromCache(animated: false)
        if Date().timeIntervalSince(scannedAt) > Self.stalenessWindow {
            startBackgroundRefresh()
        }
    }

    /// Manual "scan now": always rescans, ignoring the staleness window.
    func scanNow() {
        menuScanArmed = true
        runScan(forced: true)
    }

    /// Entry point for the notification's Clean action. Routes through the same
    /// guarded, trash-by-default clean the menu uses.
    func performCleanFromNotification() {
        cleanFromNotification = true
        clean()
    }

    private var isPanelVisible: Bool {
        panelWindow?.isVisible ?? false
    }

    private func resolveFromCache(animated: Bool = true) {
        guard let store, let date = store.lastScanCompletedAt else {
            runScan(forced: false)
            return
        }
        let bytes = store.safeRecoverableBytes
        setState(
            bytes > 0 ? .ready(bytes: bytes, lastScanned: date) : .clear(lastScanned: date),
            animated: animated
        )
    }

    /// Animates only genuine state changes: identical writes are dropped so the
    /// `withAnimation` transaction never captures unrelated pending layout
    /// (such as the panel's first layout pass, or a reopen).
    private func setState(_ newState: MenuState, animated: Bool = true) {
        guard newState != state else { return }
        guard animated else {
            state = newState
            return
        }
        withAnimation(Self.swapAnimation) { state = newState }
    }

    /// Rescans without leaving the ready/clear state: the menu keeps showing
    /// the cached number and it updates in place when the scan lands.
    private func startBackgroundRefresh() {
        // `isScanningAll` covers scans owned by the main window: `scanAll`
        // cancels-and-restarts any in-flight scan, so piling on here would
        // throw away that scan's progress just to redo the same work.
        guard let store, backgroundRefreshTask == nil, !store.isDeleting,
              !store.isScanningAll else { return }
        backgroundRefreshTask = Task { @MainActor [weak self] in
            // The store-scan subscription settles the visible state.
            await store.scanAll()
            guard let self, !Task.isCancelled else { return }
            self.backgroundRefreshTask = nil
        }
    }

    private func cancelBackgroundRefresh() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
    }

    private func runScan(forced: Bool) {
        guard let store else { return }
        // Block re-scan while checking or cleaning.
        if case .cleaning = state { return }
        if store.isDeleting { return }
        if isBusy, !forced { return }

        cancelBackgroundRefresh()
        activeWorkTask?.cancel()
        // Only animate a real change. Wrapping the cold `.checking -> .checking`
        // write in `withAnimation` lets the transaction capture the panel's
        // first layout pass, which shows as a scale-in from the corner.
        setState(.checking)
        activeWorkTask = Task { @MainActor [weak self] in
            // The store-scan subscription settles the visible state once the
            // scan (ours, or whichever superseded it) actually completes.
            await store.scanAll()
            guard let self, !Task.isCancelled else { return }
            self.activeWorkTask = nil
        }
    }

    private func resolveAfterScan(animated: Bool = true) {
        guard let store else { return }
        hasSessionScan = true
        let date = store.lastScanCompletedAt ?? Date()
        let bytes = store.safeRecoverableBytes
        setState(
            bytes > 0 ? .ready(bytes: bytes, lastScanned: date) : .clear(lastScanned: date),
            animated: animated
        )
        if menuScanArmed {
            menuScanArmed = false
            // The user asked for this scan from the panel; if they've since
            // clicked away and the panel is gone, deliver the result anyway.
            if !isPanelVisible {
                Task { await MenuScanNotifier.notifyScanResult(readyBytes: bytes) }
            }
        }
    }

    /// Cleans via the existing safe-clean entry point. Pins the candidates from
    /// the current scan so the store does not re-scan, then routes the deletion
    /// through `performManualSafeCleanNow` (allowlist + trash-by-default).
    func clean() {
        guard let store, case .ready = state, !store.isDeleting else { return }

        let candidates = store.manualSafeCleanupCandidates()
        let total = candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard total > 0 else {
            resolveAfterScan()
            return
        }

        cancelBackgroundRefresh()
        activeWorkTask?.cancel()
        setState(.cleaning(cleaned: 0, total: total))

        activeWorkTask = Task { @MainActor [weak self] in
            await self?.runClean(candidates: candidates)
            self?.activeWorkTask = nil
        }
    }

    private func runClean(candidates: [PurgeStore.DeletionCandidate]) async {
        guard let store else { return }

        // Determinate visual ramp while the (fast) trash operation runs.
        let ramp = Task { @MainActor [weak self] in
            await self?.rampCleaningProgress()
        }

        let summary = await store.performManualSafeCleanNow(pinnedCandidates: candidates)
        ramp.cancel()
        guard !Task.isCancelled else { return }

        setState(.cleaned(bytes: summary.bytesMovedToTrash))
        if cleanFromNotification {
            cleanFromNotification = false
            if !isPanelVisible {
                Task { await MenuScanNotifier.notifyCleaned(bytesMovedToTrash: summary.bytesMovedToTrash) }
            }
        }

        // Settle to "all clear" and let the all-time total tick up.
        try? await Task.sleep(nanoseconds: Self.cleanedDwellNanoseconds)
        guard !Task.isCancelled else { return }
        let date = store.lastScanCompletedAt ?? Date()
        setState(.clear(lastScanned: date))
    }

    private func rampCleaningProgress() async {
        let steps = 16
        for step in 1 ..< steps {
            try? await Task.sleep(nanoseconds: 45_000_000)
            guard !Task.isCancelled, case .cleaning(_, let total) = state else { return }
            let moved = Int64(Double(total) * Double(step) / Double(steps))
            state = .cleaning(cleaned: moved, total: total)
        }
    }
}
