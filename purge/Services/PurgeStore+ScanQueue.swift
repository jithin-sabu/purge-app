import Foundation

/// Runs scans one at a time. Every scan the Overview, a tab or Scan Everything asks
/// for goes through here, so two heavy walks never run side by side.
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
    func startLaunchScans(now: Date = Date()) {
        refreshPermission()
        let steps = LaunchScanPlan.steps(
            hasCacheResults: hasSessionResults(for: .cachesAndDevTools),
            hasFullDiskAccess: hasFullDiskAccess,
            loadedThisSession: Set(ScanStep.allCases.filter { hasSessionResults(for: $0) }),
            records: scanRecords,
            now: now
        )
        scanQueue.enqueue(steps)
        startScanQueueIfIdle()
    }

    /// Full Disk Access just landed. App Caches and Dev Tools already have results,
    /// but limited ones, so they rescan first; then the steps access unlocks queue
    /// as they would at launch.
    func scanAfterAccessGranted() {
        requestScan(.cachesAndDevTools)
        startLaunchScans()
    }

    /// A tab's own Scan button: rescan these next, ahead of anything waiting.
    func requestScan(_ steps: ScanStep...) {
        let allowed = steps.filter { !$0.needsFullDiskAccess || hasFullDiskAccess }
        scanQueueForcedSteps.formUnion(allowed)
        scanQueue.prioritize(allowed)
        startScanQueueIfIdle()
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
        guard scanQueueTask == nil, !scanQueue.pending.isEmpty else { return }
        scanQueueRunID += 1
        let runID = scanQueueRunID
        scanQueueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let step = self.scanQueue.startNext() {
                let forced = self.scanQueueForcedSteps.remove(step) != nil
                // Mirrors `runScanStep`: only when a new full scan will actually run.
                if step == .cachesAndDevTools, !self.isScanningAll,
                   forced || !self.hasSessionResults(for: .cachesAndDevTools) {
                    self.markCacheScanStarting()
                }
                let stepTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.runScanStep(step, forced: forced)
                }
                self.scanQueueStepTask = stepTask
                await Self.waitForStep(stepTask, patience: Self.scanStepPatience)
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

    /// How long one step may hold up the rest. A scan can stall with no fault of its
    /// own (a folder macOS holds open until someone answers a privacy prompt), and one
    /// stalled step must not keep every later scan, and every tab waiting on one, from
    /// ever running. The stalled scan carries on; the queue just stops waiting for it.
    static let scanStepPatience: TimeInterval = 180

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

    private func runScanStep(_ step: ScanStep, forced: Bool) async {
        switch step {
        case .cachesAndDevTools:
            if isScanningAll {
                await awaitInFlightFullScan()
            } else if forced || !hasSessionResults(for: .cachesAndDevTools) {
                await scanAll()
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
