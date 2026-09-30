import Combine
import Foundation

/// Runs scans one at a time. Every scan the Overview, a tab, Scan Everything, the
/// menu bar or Settings asks for goes through here, and a scheduled clean holds the
/// queue while it rescans, so two heavy walks never run side by side. Onboarding
/// calls `scanAll` itself, which replaces any cache scan in flight rather than
/// running beside it.
extension PurgeStore {
    /// Scan Everything: every category, whether or not it has recent results.
    func scanEverything() {
        refreshPermission()
        let steps = ScanStep.allCases.filter { !$0.needsFullDiskAccess || hasFullDiskAccess }
        scanQueueForcedSteps.formUnion(steps)
        scanQueue.enqueue(steps)
        startScanQueueIfIdle()
    }

    /// The window opened: scan what has no results yet, one step after another,
    /// in the order App Caches and Dev Tools, Large Files, apps, leftovers.
    func startLaunchScans() {
        refreshPermission()
        let steps = LaunchScanPlan.steps(
            hasFullDiskAccess: hasFullDiskAccess,
            loadedThisSession: Set(ScanStep.allCases.filter { hasSessionResults(for: $0) })
        )
        scanQueue.enqueue(steps)
        startScanQueueIfIdle()
    }

    /// Full Disk Access just landed. App Caches and Dev Tools already have results,
    /// but limited ones, so they rescan first; then the steps access unlocks queue
    /// as they would at launch. A limited scan still running stops rather than
    /// finishing results that are already out of date, and the rescan runs after it.
    func scanAfterAccessGranted() {
        interruptLimitedCacheScan()
        requestScan(.cachesAndDevTools)
        startLaunchScans()
    }

    /// A Scan button: rescan these next, ahead of anything waiting. A step that is
    /// running now runs again once it ends, since the click asked for a fresh scan.
    func requestScan(_ steps: ScanStep...) {
        requestScans(steps)
    }

    private func requestScans(_ steps: [ScanStep]) {
        let allowed = steps.filter { !$0.needsFullDiskAccess || hasFullDiskAccess }
        scanQueueForcedSteps.formUnion(allowed)
        scanQueue.prioritize(allowed, requeueingActive: true)
        startScanQueueIfIdle()
    }

    /// For callers outside the window (the menu bar, Settings) that need a scan and
    /// its results: asks the queue and returns once the step has run, was stopped,
    /// or was never allowed to run. `forced` rescans even when this session already
    /// has results; otherwise results already here are enough.
    func scanThroughQueue(_ step: ScanStep, forced: Bool) async {
        if forced {
            requestScans([step])
        } else {
            requestScanIfNeeded(step)
        }
        for await state in $scanQueue.values where state.active != step && !state.isQueued(step) {
            return
        }
    }

    /// Runs `work` with the queue idle and held: a running step finishes first, and
    /// nothing queued starts until `work` returns. For a scheduled clean, whose own
    /// rescan would otherwise walk the disk beside a queued scan or cut a queued
    /// full scan short.
    func withScanQueueHeld<T>(_ work: () async -> T) async -> T {
        while scanQueueTask != nil || isScanQueueHeld, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let wasHeld = isScanQueueHeld
        isScanQueueHeld = true
        let result = await work()
        // A cancelled wait can reach here while another holder still runs; that
        // holder releases the queue, not this one.
        if !wasHeld {
            isScanQueueHeld = false
            startScanQueueIfIdle()
        }
        return result
    }

    /// A tab was opened: if it has nothing to show yet, scan it next.
    func requestScanIfNeeded(_ steps: ScanStep...) {
        refreshPermission()
        let needed = steps.filter { step in
            (!step.needsFullDiskAccess || hasFullDiskAccess)
                && !hasSessionResults(for: step)
                && scanQueue.active != step
        }
        guard !needed.isEmpty else { return }
        scanQueue.prioritize(needed)
        // A rescan someone asked for stays ahead of a tab that merely opened: after
        // a grant, the limited App Caches results must be redone before a long
        // Large Files or apps walk starts.
        scanQueue.prioritize(scanQueue.pending.filter { scanQueueForcedSteps.contains($0) })
        startScanQueueIfIdle()
    }

    /// Stop drops everything still waiting and stops the running step. A running App
    /// Caches and Dev Tools step is left to finish: it takes seconds, and the menu bar
    /// and sidebar both track that scan to its end.
    func stopScans() {
        scanQueue.clearPending()
        scanQueueForcedSteps.removeAll()
        guard let active = scanQueue.active, active != .cachesAndDevTools else { return }
        scanQueueStepTask?.cancel()
        scanQueueStepTask = nil
        scanQueueTask?.cancel()
        scanQueueTask = nil
        // The cancelled runner is still unwinding; a new ID stops it from touching
        // the queue state of a runner started after this.
        scanQueueRunID += 1
        if active == .apps {
            cancelRemovableTotals()
        }
        scanQueue.finishActive()
    }

    func isScanQueued(_ step: ScanStep) -> Bool {
        scanQueue.isQueued(step)
    }

    private func startScanQueueIfIdle() {
        guard scanQueueTask == nil, !isScanQueueHeld, !scanQueue.pending.isEmpty else { return }
        scanQueueRunID += 1
        let runID = scanQueueRunID
        scanQueueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let step = self.scanQueue.startNext() {
                let forced = self.scanQueueForcedSteps.remove(step) != nil
                if step == .cachesAndDevTools, self.cacheStepStartsNewScan(forced: forced) {
                    self.markCacheScanStarting()
                }
                let stepTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.runScanStep(step, forced: forced)
                }
                self.scanQueueStepTask = stepTask
                if step == .cachesAndDevTools {
                    await Self.waitForStep(stepTask, patience: self.cacheStepPatience)
                } else {
                    await stepTask.value
                }
                guard self.scanQueueRunID == runID else { return }
                self.scanQueueStepTask = nil
                self.scanQueue.finishActive()
            }
            guard self.scanQueueRunID == runID else { return }
            self.scanQueueTask = nil
            // A request that arrived while the last step was finishing.
            self.startScanQueueIfIdle()
        }
    }

    /// Returns when the step finishes or its patience runs out, whichever comes first.
    private static func waitForStep(_ task: Task<Void, Never>, patience: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = StepWaitGate(continuation)
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(patience * 1_000_000_000))
                gate.resume()
            }
            Task { @MainActor in
                await task.value
                timeout.cancel()
                gate.resume()
            }
        }
    }

    /// Whether the App Caches and Dev Tools step starts a scan of its own. A full scan
    /// someone else started is waited on instead, unless it runs with less access
    /// than Purge has now: then its results would be out of date as they land.
    private func cacheStepStartsNewScan(forced: Bool) -> Bool {
        if isScanningAll, !cacheResultsNeedAccessRescan { return false }
        return forced || !hasSessionResults(for: .cachesAndDevTools)
    }

    private func runScanStep(_ step: ScanStep, forced: Bool) async {
        if step != .cachesAndDevTools, let fullAccessStep = scanSources.fullAccessStep {
            await fullAccessStep(step, forced)
            return
        }
        switch step {
        case .cachesAndDevTools:
            if cacheStepStartsNewScan(forced: forced) {
                await scanAll()
            } else if isScanningAll {
                await awaitInFlightFullScan()
            }
            await awaitProjectDiscovery()
        case .largeFiles:
            if forced {
                await scanLargeFiles()
            } else {
                await scanLargeFilesIfNeeded()
            }
        case .apps:
            if forced {
                await scanInstalledApps()
            } else {
                await scanInstalledAppsIfNeeded()
            }
            await awaitRemovableTotals()
        case .leftovers:
            if forced {
                await scanOrphanLeftovers()
            } else {
                await scanOrphanLeftoversIfNeeded()
            }
        }
    }
}

/// Resumes a continuation once, from whichever of the step or its timeout ends first.
@MainActor
private final class StepWaitGate {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
