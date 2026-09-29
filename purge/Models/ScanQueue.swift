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
    /// that is already running is left alone.
    mutating func prioritize(_ steps: [ScanStep]) {
        let front = steps.filter { $0 != active }
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

/// Which steps run when the window opens.
///
/// App Caches and Dev Tools are quick and cleaning depends on fresh results, so they
/// scan whenever there are none yet. Large Files and the app scans walk far more of
/// the disk; in on-demand mode Purge launches every time it is opened, so they are
/// skipped when a recent result is on record and the Overview shows that instead.
/// Scan Everything ignores this and rescans all of them.
nonisolated enum LaunchScanPlan {
    static let freshness: TimeInterval = 24 * 60 * 60

    static func steps(
        hasCacheResults: Bool,
        hasFullDiskAccess: Bool,
        loadedThisSession: Set<ScanStep>,
        records: [OverviewCategory: ScanRecord],
        now: Date,
        freshness: TimeInterval = LaunchScanPlan.freshness
    ) -> [ScanStep] {
        var steps: [ScanStep] = []
        if !hasCacheResults {
            steps.append(.cachesAndDevTools)
        }
        guard hasFullDiskAccess else { return steps }
        for step in [ScanStep.largeFiles, .apps, .leftovers] {
            guard !loadedThisSession.contains(step) else { continue }
            let isFresh = step.categories.allSatisfy { category in
                guard let completedAt = records[category]?.completedAt else { return false }
                let age = now.timeIntervalSince(completedAt)
                return age >= 0 && age < freshness
            }
            if !isFresh {
                steps.append(step)
            }
        }
        return steps
    }
}
