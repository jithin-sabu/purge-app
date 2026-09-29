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
                await self.runScanStep(step, forced: forced)
                guard self.scanQueueRunID == runID else { return }
                self.scanQueue.finishActive()
            }
            guard self.scanQueueRunID == runID else { return }
            self.scanQueueTask = nil
            // A request that arrived while the last step was finishing.
            self.startScanQueueIfIdle()
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
