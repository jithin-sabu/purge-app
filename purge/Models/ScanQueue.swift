import Foundation

/// One unit of work in the scan queue. App Caches and Dev Tools stay one step
/// because `scanAll` already runs them back to back and they share a generation
/// and cancellation; splitting them would mean two scan pipelines for no gain.
nonisolated enum ScanStep: String, CaseIterable, Sendable {
    case cachesAndDevTools
    case largeFiles
    case apps
    case leftovers

    /// The Overview categories whose figures this step refreshes.
    var categories: [OverviewCategory] {
        switch self {
        case .cachesAndDevTools: return [.appCaches, .devTools]
        case .largeFiles: return [.largeFiles]
        case .apps: return [.apps]
        case .leftovers: return [.leftovers]
        }
    }

    /// Large Files, the uninstaller and orphan leftovers read places a limited
    /// scan must never touch, so they only run with Full Disk Access.
    var needsFullDiskAccess: Bool {
        self != .cachesAndDevTools
    }
}

/// Which half of the App Caches and Dev Tools step is running, or neither.
nonisolated enum CacheScanStage: Equatable, Sendable {
    case idle
    case appCaches
    case devTools
}

/// The categories the Overview breaks the disk into, in the order each byte is
/// claimed: a file found by an earlier category is never counted again by a later one.
nonisolated enum OverviewCategory: String, CaseIterable, Sendable {
    case appCaches
    case devTools
    case largeFiles
    case apps
    case leftovers

    var step: ScanStep {
        switch self {
        case .appCaches, .devTools: return .cachesAndDevTools
        case .largeFiles: return .largeFiles
        case .apps: return .apps
        case .leftovers: return .leftovers
        }
    }
}

/// What is running and what is waiting. Scans run strictly one at a time: two
/// walks of the same disk slow each other down, and the cache scan already fans
/// out across the cooperative pool, so a second heavy scan beside it risks
/// starving that pool.
nonisolated struct ScanQueueState: Equatable, Sendable {
    private(set) var active: ScanStep?
    private(set) var pending: [ScanStep] = []

    var isRunning: Bool { active != nil || !pending.isEmpty }

    func isQueued(_ step: ScanStep) -> Bool {
        pending.contains(step)
    }

    /// Adds steps to the back in the order given, skipping any already running or waiting.
    mutating func enqueue(_ steps: [ScanStep]) {
        for step in steps where step != active && !pending.contains(step) {
            pending.append(step)
        }
    }

    /// Moves steps to the front, keeping their relative order, so a tab the user
    /// opens runs next instead of waiting behind the rest of a launch scan. A step
    /// that is already running is left alone, unless `requeueingActive` asks for it
    /// to run again once it ends: a Scan button, or access that changed mid-scan.
    mutating func prioritize(_ steps: [ScanStep], requeueingActive: Bool = false) {
        let front = requeueingActive ? steps : steps.filter { $0 != active }
        pending.removeAll { front.contains($0) }
        var seen = Set<ScanStep>()
        pending.insert(contentsOf: front.filter { seen.insert($0).inserted }, at: 0)
    }

    /// Makes the next waiting step the active one and returns it.
    mutating func startNext() -> ScanStep? {
        guard !pending.isEmpty else {
            active = nil
            return nil
        }
        let next = pending.removeFirst()
        active = next
        return next
    }

    mutating func finishActive() {
        active = nil
    }

    /// Drops everything still waiting. The running step is the caller's to stop.
    mutating func clearPending() {
        pending.removeAll()
    }

    mutating func reset() {
        active = nil
        pending.removeAll()
    }
}

/// Which steps run when the window opens: every one that has no results in this
/// session, in order.
///
/// A saved record is not a reason to skip a step. It only holds totals, so a skipped
/// step would look finished on the Overview and then scan anyway the moment its tab
/// opened. Scanning everything at launch means each tab is ready once its row is.
nonisolated enum LaunchScanPlan {
    static func steps(
        hasFullDiskAccess: Bool,
        loadedThisSession: Set<ScanStep>
    ) -> [ScanStep] {
        ScanStep.allCases.filter { step in
            !loadedThisSession.contains(step) && (!step.needsFullDiskAccess || hasFullDiskAccess)
        }
    }
}
