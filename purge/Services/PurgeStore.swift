import AppKit
import Foundation
import SwiftUI
import Combine

/// Holds large-file selection separately from the `largeFiles` array so a toggle
/// only re-renders the views observing this object (rows, select-all bar, delete
/// button) — never the results List container, whose re-render reverts scroll.
@MainActor
final class LargeFileSelection: ObservableObject {
    @Published var ids: Set<String> = []
}

/// Duplicate groups found among the Large Files results, kept in its own
/// observable for the same reason as `LargeFileSelection`: rows and chips can
/// observe it without the results List container re-rendering.
///
/// `index` is assigned exactly once per pass, when the whole pass finishes,
/// rather than streamed group by group. That keeps the number of re-renders of
/// `LargeFilesView` (which owns the chip counts) to one, and `isChecking` covers
/// the wait in the meantime.
@MainActor
final class LargeFileDuplicateIndex: ObservableObject {
    @Published private(set) var index = DuplicateIndex.empty
    @Published private(set) var isChecking = false

    /// Exposed so `LargeFilesView` can mirror the index into `@State` and
    /// re-render on the one assignment per pass, rather than observing the whole
    /// object and re-rendering the results List on every `isChecking` flip too.
    var indexPublisher: AnyPublisher<DuplicateIndex, Never> {
        $index.eraseToAnyPublisher()
    }

    func beginChecking() {
        index = .empty
        isChecking = true
    }

    func finish(with index: DuplicateIndex) {
        self.index = index
        isChecking = false
    }

    func cancelChecking() {
        isChecking = false
    }

    func reset() {
        index = .empty
        isChecking = false
    }

    /// Drops rows a delete removed, and any group left with a single copy.
    func removeFiles(ids removed: Set<String>) {
        guard !removed.isEmpty, !index.isEmpty else { return }
        index = index.removing(fileIDs: removed)
    }
}

/// One duplicate set in the cleanup review: its copies and the keeper suggested
/// for them. `id` is the group id, so the sheet can key its per-set keeper choice.
nonisolated struct DuplicateCopySet: Identifiable {
    let id: String
    let copies: [LargeFile]
    let suggestedKeeperID: String
}

/// A pending "keep one of each, delete the rest" review across every duplicate
/// set. `id` is derived from the sets so `.sheet(item:)` doesn't re-present the
/// same review, but changes when the sets do (a scan or an earlier delete).
nonisolated struct DuplicateCleanupRequest: Identifiable {
    let sets: [DuplicateCopySet]
    var id: String { sets.map(\.id).joined(separator: "|") }
}

/// Scan-tab selection (app caches, dev tools, simulators, project artifacts) kept in
/// its own observable, held as a plain `let` on the store (NOT @Published), so a
/// toggle re-renders only the views that display selection — never the results List
/// container, whose re-render reverts the scroll position. Keyed by stable id so it
/// survives the metadata-update passes that rebuild the item structs.
@MainActor
final class ScanSelection: ObservableObject {
    @Published var cacheIDs: Set<String> = []
    @Published var devToolIDs: Set<String> = []
    @Published var simulatorIDs: Set<UUID> = []
    @Published var artifactIDs: Set<String> = []

    func removeAll() {
        cacheIDs.removeAll()
        devToolIDs.removeAll()
        simulatorIDs.removeAll()
        artifactIDs.removeAll()
    }
}

@MainActor
final class PurgeStore: ObservableObject {
    private enum StorageKeys {
        /// Key name predates the trash-pending model and is load-bearing for
        /// `FirstRunGate`'s reset list; the value it holds is bytes moved to trash.
        static let totalMovedToTrashBytes = "totalRecoveredBytes"
        static let lastScanCompletedAt = "lastScanCompletedAt"
        static let lastScanSafeRecoverableBytes = "lastScanSafeRecoverableBytes"
    }

    enum Tab: String, CaseIterable, Identifiable {
        case appCaches = "App Caches"
        case devTools = "Dev Tools"
        case largeFiles = "Large Files"
        case uninstaller = "App Uninstaller"
        case settings = "Settings"
        case about = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appCaches: return "internaldrive"
            case .devTools: return "hammer"
            case .largeFiles: return "tray.full"
            case .uninstaller: return "trash"
            case .settings: return "gearshape"
            case .about: return "info.circle"
            }
        }
    }

    enum ScanPhase: Equatable {
        case idle
        case scanning
        case cancelling
        case completed
    }

    struct DeletionCandidate: Identifiable, Hashable {
        var id: String { path.path }
        let title: String
        let path: URL
        let sizeBytes: Int64
        let safetyInfo: SafetyInfo
        let reinstallCommand: String?
        let subtitle: String?
        var reinstallSafety: ReinstallSafetyStatus
        var gitStatus: GitWorktreeStatus

        var formattedSize: String { formatBytes(sizeBytes) }

        var needsReinstallFriction: Bool { reinstallSafety == .missingLockfile }
        var needsUncommittedGitFriction: Bool { gitStatus == .dirty }

        static func deletionCandidates(forCache item: CacheItem) -> [DeletionCandidate] {
            item.locations.map { location in
                DeletionCandidate(
                    title: item.appName,
                    path: location.path,
                    sizeBytes: location.sizeBytes,
                    safetyInfo: item.safetyInfo,
                    reinstallCommand: item.safetyInfo.reinstallCommand,
                    subtitle: location.folderName,
                    reinstallSafety: cacheReinstallStatus(forPath: location.path),
                    gitStatus: item.gitStatus
                )
            }
        }

        private static func cacheReinstallStatus(forPath url: URL) -> ReinstallSafetyStatus {
            let name = url.lastPathComponent.lowercased()
            if name == "deriveddata" { return .notApplicable }
            return ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: url)
        }
    }

    struct UnknownDeletionPayload: Identifiable {
        let id = UUID()
        let candidates: [DeletionCandidate]
    }

    @Published var selectedTab: Tab = .appCaches
    @Published var cacheItems: [CacheItem] = [] {
        didSet {
            invalidateSafeCleanupSummary()
            cacheItemsRevision &+= 1
        }
    }
    /// Cheap stand-in for "the set of cache rows changed", for use as an
    /// `.animation(_:value:)` key — see `largeFilesRevision` for the same pattern.
    @Published private(set) var cacheItemsRevision = 0
    @Published var devTools: [DevTool] = [] {
        didSet {
            invalidateSafeCleanupSummary()
            devToolsRevision &+= 1
        }
    }
    @Published private(set) var devToolsRevision = 0
    @Published var simulatorDevices: [SimulatorDevice] = []
    @Published var projectGroups: [ProjectGroup] = [] {
        didSet { invalidateSafeCleanupSummary() }
    }
    @Published var largeFiles: [LargeFile] = [] {
        didSet { largeFilesRevision &+= 1 }
    }
    /// Cheap stand-in for "the set of large-file rows changed", for use as an
    /// `.animation(_:value:)` key. The list previously animated on
    /// `largeFiles.map(\.id)`, which allocated and then compared an array of every
    /// row's path string on each body evaluation; this is O(1) and, being driven from
    /// `didSet`, also catches in-place edits that an id list would miss.
    @Published private(set) var largeFilesRevision = 0
    /// Large-file selection lives in its own observable object (NOT @Published on the
    /// store) so toggling a row does not fire the store's objectWillChange and thus
    /// does not re-render the results List container — a List re-render reverts the
    /// scroll position. Only views that display selection (rows, select-all bar,
    /// delete button) observe this object directly.
    let largeFileSelection = LargeFileSelection()
    /// Duplicate groups among `largeFiles`, likewise in its own observable so the
    /// badges and the Duplicates chip can update without re-rendering the List.
    let largeFileDuplicates = LargeFileDuplicateIndex()
    /// See `ScanSelection` — decoupled selection for the App Caches / Dev Tools tabs.
    let scanSelection = ScanSelection()
    @Published var isScanningLargeFiles = false
    @Published var showLargeFileDeletionSheet = false
    /// The duplicate-cleanup review awaiting confirmation, or nil when closed.
    /// Drives a `.sheet(item:)`.
    @Published var pendingDuplicateCleanup: DuplicateCleanupRequest?

    // MARK: Uninstaller (issue #45)

    /// Apps the picker offers, as selectable tiles. Sorted largest-first once
    /// sizes resolve.
    @Published var installedApps: [InstalledApp] = []
    @Published var isScanningInstalledApps = false
    @Published private(set) var hasCompletedInstalledAppsScan = false
    /// Bundle-plus-safe-leftover total per app id, filled in the background after
    /// the list loads. Absent until measured; callers fall back to bundle size.
    @Published private(set) var removableBytesByAppID: [String: Int64] = [:]
    /// Apps the user has ticked in the picker, keyed by `InstalledApp.id`.
    @Published var selectedAppIDs: Set<String> = []
    /// True while leftovers for the selected apps are being gathered ahead of the
    /// review sheet.
    @Published var isBuildingUninstallPlan = false
    /// The reviewed removal, one entry per selected app, awaiting confirmation.
    /// Drives the review sheet via `.sheet(item:)`; nil when closed.
    @Published var uninstallPlan: UninstallPlan?

    // MARK: Orphan leftovers (issue #26)

    /// Leftovers whose owning app is no longer installed, shown as a section under
    /// the App Uninstaller tab. Always "Check First", never preselected.
    @Published var orphanLeftovers: [UninstallItem] = []
    @Published var isScanningOrphans = false
    @Published private(set) var hasCompletedOrphanScan = false
    /// Orphan rows the user has ticked, keyed by `UninstallItem.id` (its path).
    @Published var orphanSelectedIDs: Set<String> = []
    /// The reviewed orphan removal awaiting confirmation. Drives the review sheet
    /// via `.sheet(item:)`; nil when closed.
    @Published var orphanCleanupPlan: OrphanCleanupPlan?
    /// Best-effort git status keyed by standardized tool path (`URL.path`).
    @Published private(set) var devToolRepoStatusByPath: [String: GitWorktreeStatus] = [:] {
        didSet { invalidateSafeCleanupSummary() }
    }
    @Published var isScanningGeneral = false
    @Published var isScanningDeveloper = false
    @Published private(set) var isScanningProjects = false
    @Published private(set) var isScanningAll = false
    @Published private(set) var isEnrichingGeneral = false
    @Published private(set) var isEnrichingDeveloper = false
    @Published private(set) var scanPhase: ScanPhase = .idle
    @Published private(set) var scanStatusLine = ""
    @Published private(set) var pendingCacheSizePaths: Set<String> = []
    @Published private(set) var pendingDevToolSizeIDs: Set<String> = []
    @Published private(set) var pendingProjectArtifactPaths: Set<String> = []
    @Published var isDeleting = false
    @Published var errorMessage: String?
    @Published var showDeletionSheet = false
    /// When set (e.g. tab-scoped cleanup), the confirmation sheet lists these instead of `deletionCandidates`.
    @Published var deletionSheetCandidates: [DeletionCandidate]?
    @Published var pendingUnknownDeletion: UnknownDeletionPayload?
    @Published var lastDeletionReport: DeletionReport?
    /// Live session behind the cleanup overlay for manual "Clean Selected" runs.
    /// Presented in `.cleaning` when deletion starts; flips to `.complete` in place.
    @Published private(set) var manualDeletionSession: DeletionSession?
    /// Already-complete session for the sidebar safe cleanup celebration.
    @Published private(set) var interactiveSafeCleanupSession: DeletionSession?
    /// When set, `ContentView` shows the onboarding celebration overlay instead of the standard deletion summary.
    @Published var onboardingCelebrationMovedToTrashBytes: Int64?
    @Published private(set) var interactiveSafeCleanupTargetPaths: Set<String> = []
    @Published private(set) var interactiveSafeCleanupRemovedPaths: Set<String> = []
    @Published private(set) var interactiveSafeCleanupMovedToTrashBytes: Int64?
    @Published var hasFullDiskAccess = PermissionChecker().hasFullDiskAccess()
    /// Lifetime bytes Purge has moved to the trash. Not a reclaim figure: most of it
    /// only becomes free space once the user empties the trash.
    @Published var totalMovedToTrashBytes: Int64 = 0
    @Published private(set) var lastScanCompletedAt: Date?
    @Published private(set) var lastScanSafeRecoverableBytes: Int64?

    @Published var showMissingLockfileFriction = false
    @Published var showUncommittedGitFriction = false
    /// Second-step confirmation after the primary deletion sheet when the batch includes Not Sure items.
    @Published var showHighRiskDeletionSecondConfirm = false

    /// Standardized paths with manual user categorizations. Mirrors `user_overrides.json`.
    @Published private(set) var userOverridePaths: Set<String> = UserOverridesStore.allOverriddenPaths()
    /// Paths the user excluded from scans. Purely subtractive: the scanner drops these
    /// after the allowlist gate, so nothing new ever becomes scannable or cleanable.
    @Published private(set) var excludedPaths: Set<String> = ExcludedPathsStore.allExcludedPaths()

    private let cacheScanner = CacheScanner()
    private let devScanner = DevScanner()
    private let largeFileScanner = LargeFileScanner()
    private let aiModelScanner = AIModelScanner()
    private let uninstallScanner = AppUninstallScanner()
    private let orphanScanner = OrphanLeftoverScanner()
    private let duplicateDetector = DuplicateFileDetector()
    private let fileDeleter = FileDeleter()
    private let defaults = UserDefaults.standard
    private let gitChecker = GitStatusChecker()

    private enum ScanCoalesce {
        /// One publish every ~8 frames. Fast enough that the count reads as live,
        /// slow enough that each tick's `.numericText()` roll finishes before the
        /// next value lands rather than being retargeted mid-flight.
        static let flushInterval: Duration = .milliseconds(140)
        static let flushThreshold = 100
    }

    /// The scan-flush cadence in seconds, derived from `ScanCoalesce.flushInterval`.
    ///
    /// The sidebar hero rolls its digits with a linear animation matched to this beat so
    /// each tick hands off to the next instead of being retargeted mid-curve. Derived
    /// rather than restated so retuning the interval cannot silently desynchronise the
    /// animation from the publish rate.
    static let scanFlushIntervalSeconds: Double = {
        let components = ScanCoalesce.flushInterval.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }()

    /// Cancels stale async simulator sizing when a new dev scan starts.
    private var simulatorSizingGeneration = 0
    private var scanGeneration = 0
    private var largeFileScanGeneration = 0
    private var hasCompletedLargeFileScan = false
    private var installedAppsScanGeneration = 0
    private var orphanScanGeneration = 0
    /// The in-flight duplicate pass, so a new scan can abandon gigabytes of
    /// hashing nobody is waiting for any more.
    private var duplicateScanTask: Task<Void, Never>?
    /// All cache items discovered so far in the current scan, including rows whose
    /// sizes are still unresolved. Only rows with a resolved non-zero size are
    /// published to `cacheItems`, so visible sections grow monotonically during a scan.
    private var stagedGeneralCacheItems: [CacheItem] = []
    /// Dev tools discovered but not yet sized; published to `devTools` once their size resolves.
    private var stagedDevToolsByID: [String: DevTool] = [:]
    /// Simulators discovered but not yet sized; published once their size resolves.
    private var stagedSimulatorsByID: [UUID: SimulatorDevice] = [:]
    private var scanTask: Task<Void, Never>?
    private var projectDiscoveryTask: Task<Void, Never>?
    private var scanCompletionHideTask: Task<Void, Never>?
    private var interactiveSafeCleanupRemovalTask: Task<Void, Never>?
    /// Set while an interactive safe cleanup tracks a live engine run, so
    /// `performSafeCleanup` can stream per-item progress into the overlay.
    private var interactiveSafeCleanupProgressBuffer: DeletionProgressBuffer?
    private var interactiveSafeCleanupProgressPoller: Task<Void, Never>?
    private var interactiveCleanupStartedAt: Date?

    /// After the primary confirm sheet runs, extra warnings may enqueue here.
    private var stagedDeletionCandidates: [DeletionCandidate]?
    private var stagedDeletionTrigger: CleanupTrigger = .manual
    /// Holds candidates between the primary sheet and the second high-risk alert.
    private var highRiskDeletionStagingCandidates: [DeletionCandidate]?

    /// A single clean reporting more than this is a bad size measurement, not a real recovery.
    private static let maxReasonableSingleCleanBytes: Int64 = 2_000_000_000_000
    /// Anything past this in defaults is corruption; the lifetime total itself is unbounded.
    private static let maxStorableLifetimeMovedBytes: Int64 = 1_000_000_000_000_000

    var hasDisplayableLifetimeStats: Bool {
        totalMovedToTrashBytes > 0
    }

    init() {
        var moved = Int64(defaults.integer(forKey: StorageKeys.totalMovedToTrashBytes))
        if moved > Self.maxStorableLifetimeMovedBytes {
            moved = 0
            defaults.set(0, forKey: StorageKeys.totalMovedToTrashBytes)
        }
        totalMovedToTrashBytes = moved
        lastScanCompletedAt = defaults.object(forKey: StorageKeys.lastScanCompletedAt) as? Date
        if defaults.object(forKey: StorageKeys.lastScanSafeRecoverableBytes) != nil {
            lastScanSafeRecoverableBytes = Int64(defaults.integer(forKey: StorageKeys.lastScanSafeRecoverableBytes))
        }
    }

    var selectedTotalBytes: Int64 {
        let selectedCaches = cacheItems.filter { scanSelection.cacheIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let selectedTools = devTools.filter { scanSelection.devToolIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let simSelected = simulatorDevices.filter { scanSelection.simulatorIDs.contains($0.id) }.reduce(Int64(0)) { $0 + ($1.sizeOnDisk ?? 0) }
        let projectSelected = projectGroups.flatMap(\.artifacts).filter { scanSelection.artifactIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return selectedCaches + selectedTools + simSelected + projectSelected
    }

    /// Byte totals for one-click safe cleanup, grouped by tab so sidebar and filter totals stay aligned.
    struct SafeCleanupSummary {
        var appCacheBytes: Int64 = 0
        var devToolBytes: Int64 = 0
        var projectArtifactBytes: Int64 = 0

        var totalBytes: Int64 {
            appCacheBytes + devToolBytes + projectArtifactBytes
        }
    }

    /// Memoised `safeCleanupSummary`, cleared by `didSet` on each of the four inputs it
    /// reads. Invalidating from `didSet` rather than at the call sites means subscript
    /// writes (`cacheItems[i].safetyInfo = …`) invalidate too, so no mutation path can
    /// silently leave a stale total behind.
    private var cachedSafeCleanupSummary: SafeCleanupSummary?

    fileprivate func invalidateSafeCleanupSummary() {
        cachedSafeCleanupSummary = nil
    }

    /// The sidebar hero, the Clean button title, and the footnote all read this, several
    /// times each per render, and the render re-runs on every scan flush. Recomputing was
    /// a full sweep of every cache item, dev tool, and project artifact each time —
    /// including a `standardizedFileURL` per dev-tool path, which is the expensive part.
    var safeCleanupSummary: SafeCleanupSummary {
        if let cached = cachedSafeCleanupSummary {
            return cached
        }
        let summary = computeSafeCleanupSummary()
        cachedSafeCleanupSummary = summary
        return summary
    }

    private func computeSafeCleanupSummary() -> SafeCleanupSummary {
        var summary = SafeCleanupSummary()
        summary.appCacheBytes = cacheItems.reduce(Int64(0)) { total, item in
            guard item.safetyInfo.level == .safe,
                  item.reinstallSafety != .missingLockfile,
                  item.gitStatus == .clean else { return total }
            return total + item.sizeBytes
        }
        summary.devToolBytes = devTools.reduce(Int64(0)) { total, tool in
            guard tool.isDetected,
                  tool.safetyInfo.level == .safe,
                  tool.reinstallSafety != .missingLockfile,
                  !tool.paths.contains(where: { devToolRepoStatusByPath[$0.standardizedFileURL.path] == .dirty }) else {
                return total
            }
            return total + tool.sizeBytes
        }
        summary.projectArtifactBytes = projectGroups.flatMap(\.artifacts).reduce(Int64(0)) { total, artifact in
            guard artifact.safetyInfo.level == .safe,
                  artifact.reinstallSafety != .missingLockfile,
                  artifact.gitStatus == .clean else { return total }
            return total + artifact.sizeBytes
        }
        return summary
    }

    var safeRecoverableBytes: Int64 {
        safeCleanupSummary.totalBytes
    }

    var isInteractiveSafeCleanupInProgress: Bool {
        !interactiveSafeCleanupTargetPaths.isEmpty && interactiveSafeCleanupMovedToTrashBytes == nil
    }

    // MARK: - Interactive safe-cleanup row hiding

    /// Whether a row should be hidden because an interactive safe cleanup already
    /// removed everything it targeted.
    ///
    /// The leading `isEmpty` check is the important part. These helpers are called once
    /// per item inside the views' `visibleIndices`, which SwiftUI re-evaluates many times
    /// per render — and the old per-view copies standardized every row path first, which
    /// stats the filesystem. Profiling attributed a large share of the tab-switch stall
    /// to exactly that. No cleanup is running for the overwhelming majority of renders,
    /// and when the target set is empty the answer is `false` for every row, so the
    /// guard skips the whole scan.
    func isVisuallyRemovedBySafeCleanup(paths: [String]) -> Bool {
        guard !interactiveSafeCleanupTargetPaths.isEmpty else { return false }
        var sawTarget = false
        for path in paths where interactiveSafeCleanupTargetPaths.contains(path) {
            sawTarget = true
            if !interactiveSafeCleanupRemovedPaths.contains(path) { return false }
        }
        return sawTarget
    }

    func isVisuallyRemovedBySafeCleanup(_ item: CacheItem) -> Bool {
        isVisuallyRemovedBySafeCleanup(paths: item.standardizedPaths)
    }

    func isVisuallyRemovedBySafeCleanup(_ tool: DevTool) -> Bool {
        isVisuallyRemovedBySafeCleanup(paths: tool.standardizedPaths)
    }

    func isVisuallyRemovedBySafeCleanup(_ artifact: ProjectCacheArtifact) -> Bool {
        guard !interactiveSafeCleanupTargetPaths.isEmpty else { return false }
        let path = artifact.path.standardizedFileURL.path
        return interactiveSafeCleanupTargetPaths.contains(path)
            && interactiveSafeCleanupRemovedPaths.contains(path)
    }

    /// `true` while the cleanup overlay is in its cleaning phase — used to gate
    /// navigation, window close, and app quit.
    var isManualCleaningInProgress: Bool {
        manualDeletionSession?.phase == .cleaning
            || interactiveSafeCleanupSession?.phase == .cleaning
    }

    /// Paths that match the safety, git, and lockfile rules used by safe cleanup
    /// (manual and scheduled — both clean the same set).
    func manualSafeCleanupCandidates() -> [DeletionCandidate] {
        var candidates: [DeletionCandidate] = []

        for artifact in projectGroups.flatMap(\.artifacts) {
            guard artifact.safetyInfo.level == .safe else { continue }
            guard artifact.reinstallSafety != .missingLockfile else { continue }
            guard artifact.gitStatus == .clean else { continue }
            candidates.append(artifactDeletionCandidate(artifact))
        }

        for tool in devTools where tool.isDetected && tool.safetyInfo.level == .safe {
            guard tool.reinstallSafety != .missingLockfile else { continue }
            for url in tool.paths {
                let candidate = devToolDeletionCandidate(tool, path: url)
                guard candidate.gitStatus == .clean else { continue }
                candidates.append(candidate)
            }
        }

        for item in cacheItems where item.safetyInfo.level == .safe {
            guard item.reinstallSafety != .missingLockfile else { continue }
            guard item.gitStatus == .clean else { continue }
            for location in item.locations {
                let path = location.path.standardizedFileURL
                guard DeletionSafetyPolicy.isOfferedForCleanup(path) else { continue }
                candidates.append(
                    DeletionCandidate(
                        title: item.appName,
                        path: path,
                        sizeBytes: location.sizeBytes,
                        safetyInfo: item.safetyInfo,
                        reinstallCommand: item.safetyInfo.reinstallCommand,
                        subtitle: location.folderName,
                        reinstallSafety: Self.cacheReinstallStatus(forPath: path),
                        gitStatus: item.gitStatus
                    )
                )
            }
        }

        var seenPaths = Set<String>()
        return candidates
            .filter { candidate in
                let path = candidate.path.standardizedFileURL.path
                guard !seenPaths.contains(path) else { return false }
                seenPaths.insert(path)
                return true
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    var selectedCount: Int {
        let selectedCaches = cacheItems.filter { scanSelection.cacheIDs.contains($0.id) }.count
        let selectedTools = devTools.filter { scanSelection.devToolIDs.contains($0.id) }.count
        let selectedSims = simulatorDevices.filter { scanSelection.simulatorIDs.contains($0.id) }.count
        let selectedProjects = projectGroups.flatMap(\.artifacts).filter { scanSelection.artifactIDs.contains($0.id) }.count
        return selectedCaches + selectedTools + selectedSims + selectedProjects
    }

    private func isManualDeletionCandidateEligible(_ safetyInfo: SafetyInfo) -> Bool {
        true
    }

    /// Selected caches eligible for manual delete (includes Not Sure when selected).
    var selectedGeneralDeletionCandidates: [DeletionCandidate] {
        cacheItems.filter { scanSelection.cacheIDs.contains($0.id) && isManualDeletionCandidateEligible($0.safetyInfo) }
            .flatMap { DeletionCandidate.deletionCandidates(forCache: $0) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Selected Dev Tools paths (standard caches + grouped project artifacts).
    var selectedDeveloperDeletionCandidates: [DeletionCandidate] {
        let tools = devTools.filter { scanSelection.devToolIDs.contains($0.id) }.filter(\.isDetected)
            .flatMap { tool in
                tool.paths.map { path in
                    devToolDeletionCandidate(tool, path: path)
                }
            }
            .filter { isManualDeletionCandidateEligible($0.safetyInfo) }

        let sims = simulatorDevices.filter { scanSelection.simulatorIDs.contains($0.id) }
            .map(simulatorDeletionCandidate)
            .filter { isManualDeletionCandidateEligible($0.safetyInfo) }

        let artifacts = projectGroups.flatMap(\.artifacts)
            .filter { scanSelection.artifactIDs.contains($0.id) && isManualDeletionCandidateEligible($0.safetyInfo) }
            .map(artifactDeletionCandidate)

        let merged = tools + sims + artifacts
        let unique = Dictionary(grouping: merged, by: { $0.path }).compactMap { $0.value.first }
        return unique.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    var deletionCandidates: [DeletionCandidate] {
        let caches = cacheItems.filter { scanSelection.cacheIDs.contains($0.id) && isManualDeletionCandidateEligible($0.safetyInfo) }
            .flatMap { DeletionCandidate.deletionCandidates(forCache: $0) }

        let tools = devTools.filter { scanSelection.devToolIDs.contains($0.id) }.filter(\.isDetected)
            .flatMap { tool in tool.paths.map { devToolDeletionCandidate(tool, path: $0) } }
            .filter { isManualDeletionCandidateEligible($0.safetyInfo) }

        let sims = simulatorDevices.filter { scanSelection.simulatorIDs.contains($0.id) }
            .map(simulatorDeletionCandidate)
            .filter { isManualDeletionCandidateEligible($0.safetyInfo) }

        let artifacts = projectGroups.flatMap(\.artifacts)
            .filter { scanSelection.artifactIDs.contains($0.id) && isManualDeletionCandidateEligible($0.safetyInfo) }
            .map(artifactDeletionCandidate)

        let unique = Dictionary(grouping: caches + tools + sims + artifacts, by: { $0.path }).compactMap { $0.value.first }
        return unique.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    var deletionCandidatesForSheet: [DeletionCandidate] {
        deletionSheetCandidates ?? deletionCandidates
    }

    func presentDeletionSheet(candidates: [DeletionCandidate]) {
        deletionSheetCandidates = candidates
        showDeletionSheet = true
    }

    func dismissDeletionSheet() {
        showDeletionSheet = false
        deletionSheetCandidates = nil
    }

    func presentDeletionSheetResolvingGit(candidates: [DeletionCandidate]) async {
        var resolved = candidates
        for index in resolved.indices where resolved[index].gitStatus == .unknown {
            resolved[index].gitStatus = await gitChecker.cleanupStatus(for: resolved[index].path)
        }
        presentDeletionSheet(candidates: resolved)
    }

    func userConfirmedDeletionFromPrimarySheet() {
        let picks = deletionSheetCandidates ?? deletionCandidates
        guard !picks.isEmpty else {
            dismissDeletionSheet()
            return
        }
        dismissDeletionSheet()
        if picks.contains(where: { $0.safetyInfo.level == .unknown }) {
            highRiskDeletionStagingCandidates = picks
            showHighRiskDeletionSecondConfirm = true
            return
        }
        beginManualDeletionPipeline(with: picks)
    }

    func confirmHighRiskDeletionSecondStep() {
        showHighRiskDeletionSecondConfirm = false
        guard let picks = highRiskDeletionStagingCandidates, !picks.isEmpty else {
            highRiskDeletionStagingCandidates = nil
            return
        }
        highRiskDeletionStagingCandidates = nil
        beginManualDeletionPipeline(with: picks)
    }

    func cancelHighRiskDeletionSecondStep() {
        showHighRiskDeletionSecondConfirm = false
        highRiskDeletionStagingCandidates = nil
    }

    private func beginManualDeletionPipeline(with picks: [DeletionCandidate]) {
        stagedDeletionCandidates = picks
        stagedDeletionTrigger = .manual
        runPostConfirmationFrictionPipeline()
    }

    func cancelDeletionFrictionFlow() {
        stagedDeletionCandidates = nil
        showMissingLockfileFriction = false
        showUncommittedGitFriction = false
    }

    func acknowledgeMissingLockfileRisk() {
        showMissingLockfileFriction = false
        continueAfterLockfileFriction()
    }

    func acknowledgeUncommittedGitRisk() {
        showUncommittedGitFriction = false
        Task { await executeStagedDeletion(trigger: stagedDeletionTrigger) }
    }

    private func runPostConfirmationFrictionPipeline() {
        guard let staged = stagedDeletionCandidates else { return }
        if staged.contains(where: \.needsReinstallFriction) {
            showMissingLockfileFriction = true
            return
        }
        continueAfterLockfileFriction()
    }

    private func continueAfterLockfileFriction() {
        guard let staged = stagedDeletionCandidates else { return }
        if staged.contains(where: \.needsUncommittedGitFriction) {
            showUncommittedGitFriction = true
            return
        }
        Task { await executeStagedDeletion(trigger: stagedDeletionTrigger) }
    }

    private func executeStagedDeletion(trigger: CleanupTrigger) async {
        guard let candidates = stagedDeletionCandidates else { return }
        stagedDeletionCandidates = nil
        let urls = candidates.map(\.path).map(\.standardizedFileURL)
        guard !urls.isEmpty else { return }

        var pathToDisplayName: [String: String] = [:]
        var pathToExpectedSizeBytes: [String: Int64] = [:]
        for candidate in candidates {
            let key = candidate.path.standardizedFileURL.path
            pathToDisplayName[key] = candidate.title
            pathToExpectedSizeBytes[key] = candidate.sizeBytes
        }

        // Present the cleanup overlay in its cleaning phase for interactive runs.
        // Totals come from the selected items, before the engine starts.
        let presentsSession = trigger == .manual
            && !defaults.bool(forKey: Self.pendingOnboardingCelebrationKey)
        let progressBuffer = DeletionProgressBuffer()
        var session: DeletionSession?
        var progressPoller: Task<Void, Never>?
        if presentsSession {
            let totalBytes = candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let liveSession = DeletionSession(totalBytes: totalBytes, totalItems: urls.count)
            manualDeletionSession = liveSession
            session = liveSession
            progressPoller = Task { @MainActor [weak liveSession] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard let liveSession, liveSession.phase == .cleaning else { return }
                    liveSession.applyProgress(progressBuffer.snapshot())
                }
            }
        }

        isDeleting = true
        errorMessage = nil
        defer {
            isDeleting = false
            progressPoller?.cancel()
        }
        let engineStart = Date()
        do {
            var onProgress: (@Sendable (DeletionProgressEvent) -> Void)?
            if presentsSession {
                onProgress = { @Sendable event in progressBuffer.ingest(event) }
            }
            let report = try await fileDeleter.deleteItems(
                at: urls,
                pathToDisplayName: pathToDisplayName,
                pathToExpectedSizeBytes: pathToExpectedSizeBytes,
                onProgress: onProgress
            )
            let elapsedSeconds = Date().timeIntervalSince(engineStart)
            let movedBytes = report.bytesMovedToTrash
            incrementMovedToTrashTotal(by: movedBytes)
            deselectSkippedItems(report.skippedItems)
            reflectDeletionReportInScanState(report)
            clearAllSelections()
            if defaults.bool(forKey: Self.pendingOnboardingCelebrationKey) {
                publishOnboardingCelebrationIfNeeded(movedToTrashBytes: movedBytes)
            } else {
                lastDeletionReport = report
            }
            progressPoller?.cancel()
            session?.completeRun(
                bytesMovedToTrash: movedBytes,
                elapsedSeconds: elapsedSeconds,
                failedItems: report.userVisibleFailures,
                movedToTrashCount: report.movedToTrashCount
            )
            CleanupHistoryStore.shared.append(trigger: trigger, report: report)
        } catch {
            if session != nil {
                manualDeletionSession = nil
            }
            errorMessage = trigger == .scheduled
                ? "Scheduled cleaning couldn’t finish. Open the app to try manually."
                : "Unable to clean selected items. Please try again."
        }
    }

    func dismissManualDeletionSession() {
        manualDeletionSession = nil
    }

    /// Retries deletion for a single failed item from the completion overlay.
    func retryCleanFailure(_ item: CleanFailureItem, session: DeletionSession) async -> Int64? {
        let url = URL(fileURLWithPath: item.path)

        // A `.needsAdministrator` item is a whole app held back because its bundle is
        // locked. Removing it goes through the helper and takes the bundle *and* the
        // leftovers we deferred with it, so nothing is stripped until the app can go.
        if item.reason == .needsAdministrator {
            return await completeLockedUninstall(for: item, session: session)
        }

        let result = await fileDeleter.retryDeleteItem(
            at: url,
            displayName: item.displayName,
            expectedSizeBytes: item.sizeBytes
        )
        switch result {
        case .success(let movedBytes):
            resolveRetriedFailure(item: item, movedBytes: movedBytes, session: session)
            return movedBytes
        case .failure:
            return nil
        }
    }

    /// Shared bookkeeping once a retried failure finally lands in the Trash: clear it
    /// from the overlay, credit the moved bytes, and drop it from the scan results.
    private func resolveRetriedFailure(item: CleanFailureItem, movedBytes: Int64, session: DeletionSession) {
        session.removeResolvedFailure(id: item.id, additionalMovedBytes: movedBytes)
        incrementMovedToTrashTotal(by: movedBytes)
        let deleted = DeletedItem(
            path: item.path,
            sizeBytes: movedBytes,
            displayName: item.displayName
        )
        reflectDeletionReportInScanState(
            DeletionReport(
                bytesMovedToTrash: movedBytes,
                bytesRemovedDirectly: 0,
                deletedItems: [deleted],
                failedItems: [],
                skippedItems: [],
                capacityBefore: nil,
                capacityAfter: nil,
                timestamp: Date()
            )
        )
    }

    /// Finishes a deferred locked-app uninstall once the helper is set up. Removes the
    /// bundle first; only if it actually moves are the leftovers held with it trashed,
    /// so an app is never gutted while it stays put. If the helper isn't enabled yet,
    /// this tap is the setup step and the app stays pending until the user approves it;
    /// if the bundle still won't move, the whole pending unit is left untouched.
    private func completeLockedUninstall(for item: CleanFailureItem, session: DeletionSession) async -> Int64? {
        guard PrivilegedHelperPreferenceStore.shared.isEnabled else {
            PrivilegedHelperPreferenceStore.shared.setEnabled(true)
            return nil
        }

        let bundleKey = URL(fileURLWithPath: item.path).standardizedFileURL.path
        let pending = pendingLockedUninstalls.first { $0.bundlePath == bundleKey }
        let leftovers = pending?.items.filter { $0.category != .bundle } ?? []

        // Pass 1 — the bundle, on its own. It is always helper-eligible: the validated
        // .app the user chose to remove, which a managed installer can protect even in
        // a writable /Applications. Not one leftover is touched until the bundle moves.
        let bundleURL = pending?.app.bundleURL ?? URL(fileURLWithPath: item.path)
        let bundleName = pending?.app.name ?? item.displayName
        let bundleSize = pending?.items.first(where: { $0.category == .bundle })?.sizeBytes ?? item.sizeBytes
        guard let bundleReport = try? await fileDeleter.deleteUserSelectedFiles(
            at: [bundleURL],
            pathToDisplayName: [bundleKey: bundleName],
            pathToExpectedSizeBytes: [bundleKey: bundleSize],
            privilegedEligiblePaths: [bundleKey]
        ) else { return nil }

        let bundleMoved = bundleReport.deletedItems.contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == bundleKey
        }
        guard bundleMoved else {
            // Still can't move the bundle — helper not enabled yet, or a move that
            // failed. Leave the whole pending unit intact so no leftover is trashed
            // while the app stays put, and keep the "needs your OK" row as it is.
            return nil
        }

        installedApps.removeAll { $0.bundleURL.standardizedFileURL.path == bundleKey }
        pendingLockedUninstalls.removeAll { $0.bundlePath == bundleKey }

        // A leftover that another still-installed app also claims is held back, so
        // finishing this app's removal never strips files a surviving copy needs.
        // The removed app is already out of `installedApps` above.
        var keptSharedFailures: [CleanFailureItem] = []
        let deletableLeftovers: [UninstallItem]
        if let owner = pending?.app {
            deletableLeftovers = leftovers.filter { leftover in
                if let otherApp = appStillUsing(leftover: leftover, excludingOwner: owner, among: installedApps) {
                    keptSharedFailures.append(keptSharedFailure(item: leftover, otherApp: otherApp))
                    return false
                }
                return true
            }
        } else {
            deletableLeftovers = leftovers
        }

        // Pass 2 — the leftovers, now that the app is actually gone. Each escalates
        // only when its own parent directory is not writable.
        var leftoverReport: DeletionReport?
        if !deletableLeftovers.isEmpty {
            var names: [String: String] = [:]
            var sizes: [String: Int64] = [:]
            var eligible = Set<String>()
            for leftover in deletableLeftovers {
                let key = leftover.path.standardizedFileURL.path
                names[key] = "\(bundleName) \(leftover.category.displayName)"
                sizes[key] = leftover.sizeBytes
                if pathNeedsPrivilege(leftover.path) { eligible.insert(key) }
            }
            leftoverReport = try? await fileDeleter.deleteUserSelectedFiles(
                at: deletableLeftovers.map(\.path),
                pathToDisplayName: names,
                pathToExpectedSizeBytes: sizes,
                privilegedEligiblePaths: eligible
            )
        }

        let movedBytes = bundleReport.bytesMovedToTrash + (leftoverReport?.bytesMovedToTrash ?? 0)
        if movedBytes > 0 {
            session.addRetriedMovedBytes(movedBytes)
            incrementMovedToTrashTotal(by: movedBytes)
        }
        if !bundleReport.ownershipWarningPaths.isEmpty
            || !(leftoverReport?.ownershipWarningPaths.isEmpty ?? true) {
            session.noteTrashOwnershipWarning()
        }
        reflectDeletionReportInScanState(
            DeletionReport(
                bytesMovedToTrash: movedBytes,
                bytesRemovedDirectly: 0,
                deletedItems: bundleReport.deletedItems + (leftoverReport?.deletedItems ?? []),
                failedItems: leftoverReport?.failedItems ?? [],
                skippedItems: [],
                capacityBefore: nil,
                capacityAfter: nil,
                timestamp: Date()
            )
        )

        // The app is gone. Any leftover that still failed becomes its own plain row,
        // no longer described as a locked application.
        let movedLeftoverPaths = Set((leftoverReport?.deletedItems ?? []).map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        })
        let failedLeftovers = deletableLeftovers.filter {
            !movedLeftoverPaths.contains($0.path.standardizedFileURL.path)
        }
        let reportReasons = (leftoverReport?.failedItems ?? []).reduce(into: [String: CleanFailureReason]()) {
            reasons, failure in
            reasons[URL(fileURLWithPath: failure.path).standardizedFileURL.path] = failure.reason
        }
        let failedReplacements = failedLeftovers.map { leftover -> CleanFailureItem in
            let key = leftover.path.standardizedFileURL.path
            let reported = reportReasons[key] ?? .unknown
            let reason: CleanFailureReason = reported == .needsAdministrator ? .unknown : reported
            return CleanFailureItem(
                path: leftover.path.path,
                displayName: "\(bundleName) \(leftover.category.displayName)",
                reason: reason,
                sizeBytes: leftover.sizeBytes
            )
        }
        // Both the leftovers that failed and the ones kept for another app remain as
        // rows; when neither exists, the whole "needs your OK" row is resolved.
        let replacements = failedReplacements + keptSharedFailures
        if replacements.isEmpty {
            session.removeResolvedFailure(id: item.id, additionalMovedBytes: 0)
        } else {
            session.replaceFailure(id: item.id, with: replacements)
        }

        return movedBytes > 0 ? movedBytes : nil
    }

    /// Updates in-memory scan results so removed folders disappear without requiring a full rescan
    /// (e.g. after **Done** on the summary sheet, which no longer triggers `scanAll()`).
    private func reflectDeletionReportInScanState(_ report: DeletionReport) {
        let deletedPaths = Set(report.deletedItems.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        guard !deletedPaths.isEmpty else { return }

        stagedGeneralCacheItems = stagedGeneralCacheItems.compactMap { item in
            let remaining = item.locations.filter {
                !deletedPaths.contains($0.path.standardizedFileURL.path)
            }
            guard !remaining.isEmpty else { return nil }
            guard remaining.count != item.locations.count else { return item }
            return item.withLocations(remaining)
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            cacheItems = cacheItems.compactMap { item in
                let remaining = item.locations.filter {
                    !deletedPaths.contains($0.path.standardizedFileURL.path)
                }
                guard !remaining.isEmpty else { return nil }
                guard remaining.count != item.locations.count else { return item }
                return item.withLocations(remaining)
            }

            devTools = devTools.map { tool in
                let remainingPaths = tool.paths.filter {
                    !deletedPaths.contains($0.standardizedFileURL.path)
                }
                let pathSizes = tool.pathSizeBytesByPath.filter { key, _ in
                    remainingPaths.contains { $0.standardizedFileURL.path == key }
                }
                let newSize = pathSizes.values.reduce(Int64(0), +)
                let stillDetected = !remainingPaths.isEmpty && newSize > 0
                if newSize == tool.sizeBytes, stillDetected == tool.isDetected {
                    return tool
                }
                return DevTool(
                    definitionKey: tool.definitionKey,
                    toolName: tool.toolName,
                    paths: remainingPaths,
                    sizeBytes: newSize,
                    pathSizeBytesByPath: pathSizes,
                    lastModified: tool.lastModified,
                    isSelected: false,
                    isDetected: stillDetected,
                    safetyInfo: tool.safetyInfo,
                    reinstallSafety: tool.reinstallSafety
                )
            }
            // Selection is id-keyed and separate; drop any tool that's no longer detected.
            let detectedToolIDs = Set(devTools.filter(\.isDetected).map(\.id))
            scanSelection.devToolIDs.formIntersection(detectedToolIDs)

            simulatorDevices.removeAll { deletedPaths.contains($0.folderURL.standardizedFileURL.path) }

            var groups = projectGroups
            for gi in groups.indices {
                groups[gi].artifacts.removeAll { deletedPaths.contains($0.path.standardizedFileURL.path) }
            }
            projectGroups = groups.filter { !$0.artifacts.isEmpty }
        }

        for path in deletedPaths {
            devToolRepoStatusByPath.removeValue(forKey: path)
        }

        if lastScanCompletedAt != nil {
            persistLastScanSafeRecoverableBytes()
        }
    }

    private func clearAllSelections() {
        scanSelection.removeAll()
    }

    /// Drop any selections that the safety policy rejected so they don't keep
    /// reappearing in the staged set on the next confirmation.
    private func deselectSkippedItems(_ skipped: [SkippedDeletionItem]) {
        guard !skipped.isEmpty else { return }
        let skippedPaths = Set(skipped.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        guard !skippedPaths.isEmpty else { return }

        for item in cacheItems where item.locations.contains(where: { skippedPaths.contains($0.path.standardizedFileURL.path) }) {
            scanSelection.cacheIDs.remove(item.id)
        }

        for tool in devTools where tool.paths.contains(where: { skippedPaths.contains($0.standardizedFileURL.path) }) {
            scanSelection.devToolIDs.remove(tool.id)
        }

        for device in simulatorDevices where skippedPaths.contains(device.folderURL.standardizedFileURL.path) {
            scanSelection.simulatorIDs.remove(device.id)
        }

        for artifact in projectGroups.flatMap(\.artifacts)
        where skippedPaths.contains(artifact.path.standardizedFileURL.path) {
            scanSelection.artifactIDs.remove(artifact.id)
        }
    }

    func requestUnknownDeletion(_ candidate: DeletionCandidate) {
        requestUnknownDeletion(candidates: [candidate])
    }

    func requestUnknownDeletion(candidates: [DeletionCandidate]) {
        guard !candidates.isEmpty else { return }
        pendingUnknownDeletion = UnknownDeletionPayload(candidates: candidates)
    }

    /// Unknown dev tool rows map to multiple paths; deleting confirms all paths together.
    func unknownDeletionCandidates(forDevTool tool: DevTool) -> [DeletionCandidate] {
        tool.paths.map { devToolDeletionCandidate(tool, path: $0) }
    }

    func unknownDeletionCandidates(forArtifact artifact: ProjectCacheArtifact) -> [DeletionCandidate] {
        [artifactDeletionCandidate(artifact)]
    }

    func dismissUnknownDeletionRequest() {
        pendingUnknownDeletion = nil
    }

    func userConfirmedUnknownDeletionFlow() async {
        guard let payload = pendingUnknownDeletion else { return }
        pendingUnknownDeletion = nil
        var resolved = payload.candidates
        for idx in resolved.indices where resolved[idx].gitStatus == .unknown {
            resolved[idx].gitStatus = await gitChecker.cleanupStatus(for: resolved[idx].path)
        }
        if resolved.contains(where: { $0.safetyInfo.level == .unknown }) {
            highRiskDeletionStagingCandidates = resolved
            showHighRiskDeletionSecondConfirm = true
            return
        }
        beginManualDeletionPipeline(with: resolved)
    }

    // MARK: - Large & Old Files

    var selectedLargeFiles: [LargeFile] {
        let ids = largeFileSelection.ids
        return largeFiles.filter { ids.contains($0.id) }
    }

    var selectedLargeFileCount: Int {
        selectedLargeFiles.count
    }

    var selectedLargeFileBytes: Int64 {
        selectedLargeFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    /// Duplicate groups the current selection would wipe out completely — every
    /// copy checked, nothing left behind.
    ///
    /// Purge does not choose which copy survives (issue #17 is explicit that
    /// picking which user document dies is not the app's judgement to make), so
    /// this exists only to say plainly what the selection does before it happens.
    var duplicateGroupsFullyConsumedBySelection: [DuplicateGroup] {
        let index = largeFileDuplicates.index
        guard !index.isEmpty else { return [] }
        let selected = largeFileSelection.ids
        guard !selected.isEmpty else { return [] }
        return index.groups.filter { group in
            group.fileIDs.allSatisfy { selected.contains($0) }
        }
    }

    func scanLargeFilesIfNeeded() async {
        refreshPermission()
        guard hasFullDiskAccess else { return }
        guard !isScanningLargeFiles, !hasCompletedLargeFileScan else { return }
        await scanLargeFiles()
    }

    func scanLargeFiles() async {
        refreshPermission()
        guard hasFullDiskAccess else { return }
        largeFileScanGeneration += 1
        let generation = largeFileScanGeneration
        isScanningLargeFiles = true
        largeFiles = []
        largeFileSelection.ids.removeAll()
        duplicateScanTask?.cancel()
        duplicateScanTask = nil
        largeFileDuplicates.reset()
        defer {
            if largeFileScanGeneration == generation {
                isScanningLargeFiles = false
            }
        }

        let minBytes = LargeFileSizeThreshold.current().bytes
        let staleDays = LargeFileAgeThreshold.currentThresholdDays()
        var collected: [LargeFile] = []

        // Models resolve from a handful of manifests, so they land almost
        // instantly — running them ahead of the file walk puts the biggest
        // items on screen first instead of after a full home-directory sweep.
        for await model in aiModelScanner.scanStream(minBytes: minBytes, staleDays: staleDays) {
            guard largeFileScanGeneration == generation, !Task.isCancelled else { return }
            collected.append(model)
        }
        largeFiles = collected.sorted { $0.sizeBytes > $1.sizeBytes }

        for await file in largeFileScanner.scanStream(minBytes: minBytes, staleDays: staleDays) {
            guard largeFileScanGeneration == generation, !Task.isCancelled else { return }
            collected.append(file)
            if collected.count % 25 == 0 {
                largeFiles = collected.sorted { $0.sizeBytes > $1.sizeBytes }
            }
        }
        guard largeFileScanGeneration == generation else { return }
        largeFiles = collected.sorted { $0.sizeBytes > $1.sizeBytes }
        hasCompletedLargeFileScan = true
        startDuplicateScan(for: largeFiles, generation: generation)
    }

    /// Looks for byte-identical copies among the finished scan results.
    ///
    /// Deliberately *after* the scan rather than inside it: hashing a pair of
    /// 4 GB videos takes real time, and holding "Scanning…" open for it would
    /// make every scan feel slower to pay for insight the user can wait a beat
    /// for. The list is complete and usable while this runs.
    private func startDuplicateScan(for files: [LargeFile], generation: Int) {
        guard !files.isEmpty else { return }
        largeFileDuplicates.beginChecking()
        duplicateScanTask = Task { [duplicateDetector, largeFileDuplicates] in
            let index = await duplicateDetector.findDuplicates(in: files)
            // A superseded pass returns without touching the index at all: by the
            // time it gets here a newer scan has already called `beginChecking()`,
            // and clearing the flag would strand the newer pass with no
            // "Checking for duplicates…" status while it is still running.
            guard self.largeFileScanGeneration == generation else { return }
            guard !Task.isCancelled else {
                largeFileDuplicates.cancelChecking()
                return
            }
            // Rows deleted while the pass was running must not come back as
            // badges on rows that no longer exist.
            let live = Set(self.largeFiles.map(\.id))
            let vanished = Set(index.groupIDByFileID.keys.filter { !live.contains($0) })
            largeFileDuplicates.finish(
                with: index
                    .removing(fileIDs: vanished)
                    .withDisplaySizes(from: self.largeFiles)
            )
        }
    }

    func setLargeFileSelected(id: String, isSelected: Bool) {
        if isSelected {
            largeFileSelection.ids.insert(id)
        } else {
            largeFileSelection.ids.remove(id)
        }
    }

    func setAllLargeFilesSelected(_ selected: Bool, ids: [String]) {
        if selected {
            largeFileSelection.ids.formUnion(ids)
        } else {
            largeFileSelection.ids.subtract(ids)
        }
    }

    func presentLargeFileDeletionSheet() {
        guard !selectedLargeFiles.isEmpty else { return }
        showLargeFileDeletionSheet = true
    }

    func dismissLargeFileDeletionSheet() {
        showLargeFileDeletionSheet = false
    }

    /// Opens the duplicate-cleanup review: one keeper suggested per set, every
    /// other copy bound for Trash. Nothing deletes here — the review names the rule
    /// and shows the kept copy against the trashed ones, and the keeper is
    /// changeable, so the app never removes a copy the user hasn't seen and agreed
    /// to (issue #17).
    func requestDuplicateCleanup() {
        let index = largeFileDuplicates.index
        guard !index.isEmpty else { return }
        let byID = Dictionary(largeFiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sets: [DuplicateCopySet] = index.groups.compactMap { group in
            let copies = group.fileIDs.compactMap { byID[$0] }
            guard copies.count > 1 else { return nil }
            let keeper = DuplicateKeeper.suggestedKeeperID(among: copies) ?? copies[0].id
            return DuplicateCopySet(id: group.id, copies: copies, suggestedKeeperID: keeper)
        }
        guard !sets.isEmpty else { return }
        pendingDuplicateCleanup = DuplicateCleanupRequest(sets: sets)
    }

    func dismissDuplicateCleanup() {
        pendingDuplicateCleanup = nil
    }

    /// Trashes every copy except the chosen keeper in each set. `keeperByGroupID`
    /// carries the user's final pick per set (defaulting to the suggestion). Runs
    /// through the same delete path as the selection flow, so it gets the same
    /// Trash safety, progress overlay, and history entry.
    func confirmDuplicateCleanup(keeperByGroupID: [String: String]) async {
        guard let request = pendingDuplicateCleanup else { return }
        pendingDuplicateCleanup = nil
        var targets: [LargeFile] = []
        for copySet in request.sets {
            let keeper = keeperByGroupID[copySet.id] ?? copySet.suggestedKeeperID
            targets.append(contentsOf: copySet.copies.filter { $0.id != keeper })
        }
        await performLargeFileDeletion(targets: targets)
    }

    func confirmLargeFileDeletion() async {
        showLargeFileDeletionSheet = false
        await performLargeFileDeletion(targets: selectedLargeFiles)
    }

    private func performLargeFileDeletion(targets: [LargeFile]) async {
        guard !targets.isEmpty, !isDeleting else { return }

        // A row can stand for several files (an AI model is a manifest plus its
        // blobs), so expand to components here. Component order matters: the
        // manifest goes first, so an interrupted delete leaves orphaned blobs
        // rather than a model Ollama still lists but can no longer run.
        var urls: [URL] = []
        var pathToDisplayName: [String: String] = [:]
        var pathToExpectedSizeBytes: [String: Int64] = [:]
        for file in targets {
            for component in file.componentPaths {
                urls.append(component)
                pathToDisplayName[component.path] = file.displayName
            }
            // Only single-file rows can claim a known size up front; for
            // multi-part rows each component is measured as it goes so the
            // total doesn't count the row's bytes once per component.
            if file.componentPaths.count == 1, let only = file.componentPaths.first {
                pathToExpectedSizeBytes[only.path] = file.sizeBytes
            }
        }

        // Present the cleanup overlay in its cleaning phase and poll per-item
        // progress, mirroring the caches / dev-tools manual deletion flow so
        // large-file deletions get the same progress + completion screen.
        let progressBuffer = DeletionProgressBuffer()
        let totalBytes = targets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let liveSession = DeletionSession(totalBytes: totalBytes, totalItems: urls.count)
        manualDeletionSession = liveSession
        let progressPoller = Task { @MainActor [weak liveSession] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let liveSession, liveSession.phase == .cleaning else { return }
                liveSession.applyProgress(progressBuffer.snapshot())
            }
        }

        isDeleting = true
        errorMessage = nil
        defer {
            isDeleting = false
            progressPoller.cancel()
        }

        let engineStart = Date()
        do {
            let report = try await fileDeleter.deleteUserSelectedFiles(
                at: urls,
                pathToDisplayName: pathToDisplayName,
                pathToExpectedSizeBytes: pathToExpectedSizeBytes,
                onProgress: { @Sendable event in progressBuffer.ingest(event) }
            )
            let elapsedSeconds = Date().timeIntervalSince(engineStart)
            incrementMovedToTrashTotal(by: report.bytesMovedToTrash)
            lastDeletionReport = report
            let deletedPaths = Set(report.deletedItems.map {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
            })
            // A row is gone only when every path it stood for is gone. Matching
            // on `id` alone would drop a model as soon as its manifest trashed,
            // even if a multi-gigabyte blob failed and still occupies the disk —
            // and since blobs are only ever discovered through their manifest, a
            // later scan could never surface it again. Rows that deleted
            // partially stay listed and stay selected, so a retry can finish the
            // job (the already-trashed manifest is skipped as non-existent).
            let clearedRowIDs = Set(
                largeFiles.filter { $0.isFullyRemoved(byDeleting: deletedPaths) }.map(\.id)
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                largeFiles.removeAll { clearedRowIDs.contains($0.id) }
            }
            largeFileSelection.ids.subtract(clearedRowIDs)
            // A group of two that just lost a member is no longer a duplicate;
            // leaving the survivor badged "2 copies" would misdescribe the disk.
            largeFileDuplicates.removeFiles(ids: clearedRowIDs)
            progressPoller.cancel()
            liveSession.completeRun(
                bytesMovedToTrash: report.bytesMovedToTrash,
                elapsedSeconds: elapsedSeconds,
                failedItems: report.userVisibleFailures,
                movedToTrashCount: report.movedToTrashCount
            )
            if !report.ownershipWarningPaths.isEmpty { liveSession.noteTrashOwnershipWarning() }
            CleanupHistoryStore.shared.append(trigger: .manual, report: report)
        } catch {
            manualDeletionSession = nil
            errorMessage = "Unable to delete the selected files. Please try again."
        }
    }

    // MARK: - Uninstaller (issue #45)

    func scanInstalledAppsIfNeeded() async {
        refreshPermission()
        guard hasFullDiskAccess else { return }
        guard !isScanningInstalledApps, !hasCompletedInstalledAppsScan else { return }
        await scanInstalledApps()
    }

    /// Populates the app picker. Apps stream in and are re-sorted largest-first as
    /// their sizes land, the same progressive fill the other scans use.
    func scanInstalledApps() async {
        refreshPermission()
        guard hasFullDiskAccess else { return }
        installedAppsScanGeneration += 1
        let generation = installedAppsScanGeneration
        isScanningInstalledApps = true
        hasCompletedInstalledAppsScan = false
        installedApps = []
        removableBytesByAppID = [:]
        defer {
            if installedAppsScanGeneration == generation {
                isScanningInstalledApps = false
            }
        }

        var collected: [InstalledApp] = []
        for await app in uninstallScanner.installedAppsStream() {
            guard installedAppsScanGeneration == generation, !Task.isCancelled else { return }
            collected.append(app)
            installedApps = collected.sorted { $0.bundleSizeBytes > $1.bundleSizeBytes }
        }
        // Only a stream that ran to completion counts as a finished scan. A
        // cancelled or superseded run leaves `hasCompletedInstalledAppsScan`
        // false so `scanInstalledAppsIfNeeded` will scan again rather than trust a
        // partial list.
        guard installedAppsScanGeneration == generation, !Task.isCancelled else { return }
        installedApps = collected.sorted { $0.bundleSizeBytes > $1.bundleSizeBytes }
        hasCompletedInstalledAppsScan = true

        // Fill in each tile's "total freed" (bundle + all matched leftovers) in
        // the background, so the list appears immediately and the numbers settle in.
        Task { await measureRemovableTotals(generation: generation) }
    }

    /// For each app, sums the bundle plus every leftover matched to it, so the
    /// tile shows the app's full footprint on disk rather than only the
    /// default-checked subset. Runs one app at a time so it never competes hard
    /// with a leftover scan the user triggers by selecting apps.
    private func measureRemovableTotals(generation: Int) async {
        // A path is sized once across the whole pass. Two installs that share a
        // bundle id resolve to the same bundle-id-keyed leftovers; without this the
        // shared bytes would land in both tiles and double the summed figure on the
        // Uninstall button (`selectedAppsRemovableBytes`).
        var sizedPaths = Set<String>()
        for app in installedApps {
            if installedAppsScanGeneration != generation || Task.isCancelled { return }
            var total: Int64 = 0
            for await item in uninstallScanner.leftoverStream(for: app) {
                guard sizedPaths.insert(item.path.standardizedFileURL.path).inserted else { continue }
                total += item.sizeBytes
            }
            guard installedAppsScanGeneration == generation else { return }
            removableBytesByAppID[app.id] = total
        }
    }

    /// Bundle-plus-all-leftovers total for an app once measured, else its bundle
    /// size. This is the figure the tiles and size sort use.
    func removableBytes(for app: InstalledApp) -> Int64 {
        removableBytesByAppID[app.id] ?? app.bundleSizeBytes
    }

    /// True once every listed app has a measured total, so the size sort can use
    /// the totals without reshuffling tiles while measurement is still in flight.
    var hasMeasuredAllRemovableTotals: Bool {
        !installedApps.isEmpty && removableBytesByAppID.count >= installedApps.count
    }

    // MARK: - Orphan leftovers (issue #26)

    func scanOrphanLeftoversIfNeeded() async {
        refreshPermission()
        guard hasFullDiskAccess else { return }
        guard !isScanningOrphans, !hasCompletedOrphanScan else { return }
        await scanOrphanLeftovers()
    }

    /// Populates the "Leftovers from removed apps" section. Rows stream in and are
    /// re-sorted largest-first as their sizes land, the same progressive fill the
    /// other scans use. Requires Full Disk Access: without it the Library roots
    /// are unreadable and the scan would wrongly read as empty.
    func scanOrphanLeftovers() async {
        refreshPermission()
        guard hasFullDiskAccess else { return }
        orphanScanGeneration += 1
        let generation = orphanScanGeneration
        isScanningOrphans = true
        hasCompletedOrphanScan = false
        orphanLeftovers = []
        orphanSelectedIDs = []
        defer {
            if orphanScanGeneration == generation {
                isScanningOrphans = false
            }
        }

        var collected: [UninstallItem] = []
        for await item in orphanScanner.orphanStream() {
            guard orphanScanGeneration == generation, !Task.isCancelled else { return }
            collected.append(item)
            orphanLeftovers = collected.sorted { $0.sizeBytes > $1.sizeBytes }
        }
        // Only a stream that ran to completion counts as a finished scan, so a
        // cancelled or superseded run scans again rather than trusting a partial
        // list.
        guard orphanScanGeneration == generation, !Task.isCancelled else { return }
        orphanLeftovers = collected.sorted { $0.sizeBytes > $1.sizeBytes }
        hasCompletedOrphanScan = true
    }

    func toggleOrphanSelected(id: String) {
        if orphanSelectedIDs.contains(id) {
            orphanSelectedIDs.remove(id)
        } else {
            orphanSelectedIDs.insert(id)
        }
    }

    func setAllOrphansSelected(_ selected: Bool, ids: [String]) {
        if selected {
            orphanSelectedIDs.formUnion(ids)
        } else {
            orphanSelectedIDs.subtract(ids)
        }
    }

    var selectedOrphanBytes: Int64 {
        orphanLeftovers
            .filter { orphanSelectedIDs.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    var selectedOrphanCount: Int {
        orphanLeftovers.filter { orphanSelectedIDs.contains($0.id) }.count
    }

    /// Opens the orphan review sheet with the ticked leftovers, each carried in
    /// pre-selected so the sheet's own checkboxes start where the list left off.
    func requestOrphanCleanup() {
        let items = orphanLeftovers
            .filter { orphanSelectedIDs.contains($0.id) }
            .map { item -> UninstallItem in
                var copy = item
                copy.isSelected = true
                return copy
            }
        guard !items.isEmpty, !isDeleting else { return }
        orphanCleanupPlan = OrphanCleanupPlan(items: items)
    }

    func cancelOrphanCleanup() {
        orphanCleanupPlan = nil
    }

    func confirmOrphanCleanup(_ plan: OrphanCleanupPlan) async {
        orphanCleanupPlan = nil
        await performOrphanCleanup(items: plan.selectedItems)
    }

    /// Trashes the chosen orphan leftovers, reusing the uninstaller's deletion
    /// primitive: those paths sit outside the cache allowlist, and
    /// `deleteUserSelectedFiles` accepts them through
    /// `AppUninstallScanPolicy.isEligibleForUninstallDeletion`, the same gate the
    /// scanner used to offer them. Shares the live-session overlay, progress
    /// poller, and history entry with the other manual flows.
    private func performOrphanCleanup(items: [UninstallItem]) async {
        guard !items.isEmpty, !isDeleting else { return }

        var urls: [URL] = []
        var pathToDisplayName: [String: String] = [:]
        var pathToExpectedSizeBytes: [String: Int64] = [:]
        for item in items {
            let key = item.path.standardizedFileURL.path
            urls.append(item.path)
            pathToDisplayName[key] = item.safetyInfo.headline
            pathToExpectedSizeBytes[key] = item.sizeBytes
        }

        let progressBuffer = DeletionProgressBuffer()
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let liveSession = DeletionSession(totalBytes: totalBytes, totalItems: urls.count)
        manualDeletionSession = liveSession
        let progressPoller = Task { @MainActor [weak liveSession] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let liveSession, liveSession.phase == .cleaning else { return }
                liveSession.applyProgress(progressBuffer.snapshot())
            }
        }

        isDeleting = true
        errorMessage = nil
        defer {
            isDeleting = false
            progressPoller.cancel()
        }

        let engineStart = Date()
        do {
            let report = try await fileDeleter.deleteUserSelectedFiles(
                at: urls,
                pathToDisplayName: pathToDisplayName,
                pathToExpectedSizeBytes: pathToExpectedSizeBytes,
                onProgress: { @Sendable event in progressBuffer.ingest(event) }
            )
            let elapsedSeconds = Date().timeIntervalSince(engineStart)
            incrementMovedToTrashTotal(by: report.bytesMovedToTrash)
            lastDeletionReport = report
            let deletedPaths = Set(report.deletedItems.map {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
            })
            let clearedIDs = Set(
                orphanLeftovers
                    .filter { deletedPaths.contains($0.path.standardizedFileURL.path) }
                    .map(\.id)
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                orphanLeftovers.removeAll { clearedIDs.contains($0.id) }
            }
            orphanSelectedIDs.subtract(clearedIDs)
            progressPoller.cancel()
            liveSession.completeRun(
                bytesMovedToTrash: report.bytesMovedToTrash,
                elapsedSeconds: elapsedSeconds,
                failedItems: report.userVisibleFailures,
                movedToTrashCount: report.movedToTrashCount
            )
            if !report.ownershipWarningPaths.isEmpty { liveSession.noteTrashOwnershipWarning() }
            CleanupHistoryStore.shared.append(trigger: .manual, report: report)
        } catch {
            manualDeletionSession = nil
            errorMessage = "Unable to remove the selected leftovers. Please try again."
        }
    }

    // MARK: App selection

    func toggleAppSelected(id: String) {
        if selectedAppIDs.contains(id) {
            selectedAppIDs.remove(id)
        } else {
            selectedAppIDs.insert(id)
        }
    }

    func setAllAppsSelected(_ selected: Bool, ids: [String]) {
        if selected {
            selectedAppIDs.formUnion(ids)
        } else {
            selectedAppIDs.subtract(ids)
        }
    }

    var selectedApps: [InstalledApp] {
        installedApps.filter { selectedAppIDs.contains($0.id) }
    }

    /// Total shown on the Uninstall button: bundle plus all matched leftovers per
    /// app where measured, bundle size otherwise. The review sheet then shows the
    /// exact, item-by-item figure for what stays ticked.
    var selectedAppsRemovableBytes: Int64 {
        selectedApps.reduce(Int64(0)) { $0 + removableBytes(for: $1) }
    }

    // MARK: Building the removal plan

    /// Gathers the bundle plus leftovers for every selected app and opens the
    /// review sheet. Every match arrives checked; the sharing pass below then
    /// unticks any leftover a kept app still claims, so the sheet shows upfront
    /// what the deletion pass would otherwise silently hold back.
    func requestUninstallSelectedApps() async {
        let apps = selectedApps
        guard !apps.isEmpty, !isBuildingUninstallPlan, !isDeleting else { return }
        isBuildingUninstallPlan = true
        defer { isBuildingUninstallPlan = false }

        var appPlans: [UninstallAppPlan] = []
        for app in apps {
            if Task.isCancelled { return }
            var items: [UninstallItem] = []
            for await item in uninstallScanner.leftoverStream(for: app) {
                items.append(item)
            }
            items.sort(by: uninstallItemOrder)
            appPlans.append(UninstallAppPlan(app: app, items: items))
        }

        markSharedWithSurvivors(in: &appPlans)

        let id = appPlans.map(\.app.id).sorted().joined(separator: "|")
        uninstallPlan = UninstallPlan(id: id, apps: appPlans)
    }

    /// Unticks and labels any leftover that an app the user is keeping also claims,
    /// so removing one app never proposes trashing a file a surviving app reads
    /// (the two-copies case, or one app of a suite that shares support). The bundle
    /// is never shared, and this reuses the deletion pass's `appStillUsing` matcher
    /// so the sheet and the actual removal agree on what is held back.
    private func markSharedWithSurvivors(in appPlans: inout [UninstallAppPlan]) {
        let removingIDs = Set(appPlans.map(\.app.id))
        let survivors = installedApps.filter { !removingIDs.contains($0.id) }
        guard !survivors.isEmpty else { return }

        for planIndex in appPlans.indices {
            let owner = appPlans[planIndex].app
            for itemIndex in appPlans[planIndex].items.indices {
                let item = appPlans[planIndex].items[itemIndex]
                guard item.category != .bundle else { continue }
                if let survivor = appStillUsing(
                    leftover: item,
                    excludingOwner: owner,
                    among: survivors
                ) {
                    appPlans[planIndex].items[itemIndex].isSelected = false
                    appPlans[planIndex].items[itemIndex].keptForApp = survivor.name
                }
            }
        }
    }

    func dismissUninstallPlan() {
        uninstallPlan = nil
    }

    /// Bundle first, then by category, then largest within a category.
    private func uninstallItemOrder(_ lhs: UninstallItem, _ rhs: UninstallItem) -> Bool {
        if lhs.category.sortOrder != rhs.category.sortOrder {
            return lhs.category.sortOrder < rhs.category.sortOrder
        }
        return lhs.sizeBytes > rhs.sizeBytes
    }

    /// Confirms the reviewed plan (the sheet passes back its edited copy) and
    /// trashes every checked item across every app.
    func confirmUninstallPlan(_ plan: UninstallPlan) async {
        uninstallPlan = nil
        await performUninstallPlan(plan)
    }

    /// An app whose bundle needs the helper, held whole (bundle + leftovers) until
    /// the helper is enabled. We never strip an app's leftovers while its bundle
    /// stays put: that would gut an app the user can still open.
    private struct PendingLockedUninstall {
        let app: InstalledApp
        let items: [UninstallItem]
        var bundlePath: String { app.bundleURL.standardizedFileURL.path }
    }

    private var pendingLockedUninstalls: [PendingLockedUninstall] = []

    /// Moving an item requires write access to the directory containing it. The
    /// item's own owner and mode do not matter for a rename, so checking the item
    /// itself would unnecessarily elevate files in a user-writable folder.
    private func pathNeedsPrivilege(_ url: URL) -> Bool {
        !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    /// The other still-installed app, if any, that a leftover also belongs to.
    /// Removing the chosen app must not take a file a second installed app still
    /// needs, which is what happens when two copies share bundle-id-keyed support.
    /// Matching reuses the scanner's strict identifier/name rules, so only a
    /// genuinely shared leftover is ever held back.
    private func appStillUsing(
        leftover item: UninstallItem,
        excludingOwner owner: InstalledApp,
        among remaining: [InstalledApp]
    ) -> InstalledApp? {
        AppUninstallScanPolicy.claimant(
            forLeftoverName: item.path.lastPathComponent,
            category: item.category,
            ownerID: owner.id,
            among: remaining
        )
    }

    /// Builds the "kept, still used by another app" notice shown for a shared leftover
    /// that Purge deliberately left in place.
    private func keptSharedFailure(item: UninstallItem, otherApp: InstalledApp) -> CleanFailureItem {
        CleanFailureItem(
            path: item.path.path,
            displayName: "\(otherApp.name) \(item.category.displayName)",
            reason: .keptForOtherApp,
            sizeBytes: item.sizeBytes
        )
    }

    /// Trashes the checked items across all apps in `plan`, reusing the same
    /// live-session overlay, progress poller, and history entry as the other
    /// manual flows. Kept separate from `performLargeFileDeletion`: they share
    /// structure but differ in what a row is and what happens after (apps leaving
    /// the picker), and the large-files path is on the shipping critical path.
    private func performUninstallPlan(_ plan: UninstallPlan) async {
        let selectedByApp = plan.apps.map { ($0.app, $0.selectedItems) }.filter { !$0.1.isEmpty }
        guard !selectedByApp.isEmpty, !isDeleting else { return }

        // Claim the deleting flag before the first suspension point below (the
        // quit wait). On the main actor an `await` is a chance for a second tap to
        // re-enter, and setting the flag only just before the engine call would
        // let two runs slip past the guard. The outer defer clears it on every
        // exit, including the early "nothing quit" return.
        isDeleting = true
        defer { isDeleting = false }

        // Quit any running app whose bundle is about to move. If one refuses to
        // quit — the user cancelled its save prompt, say — it is left installed
        // rather than trashed out from under a live process. Leftovers-only
        // selections don't need a quit: they are not the running binary.
        var toDelete: [(InstalledApp, [UninstallItem])] = []
        var stillOpen: [InstalledApp] = []
        for (app, items) in selectedByApp {
            let removesBundle = items.contains { $0.category == .bundle }
            if removesBundle {
                let quit = await quitRunningApp(app)
                if !quit { stillOpen.append(app); continue }
            }
            toDelete.append((app, items))
        }

        // Everything the user picked belongs to an app that would not quit.
        guard !toDelete.isEmpty else {
            manualDeletionSession = nil
            errorMessage = stillOpenMessage(stillOpen)
            return
        }

        // The invariant: an app's leftovers are never trashed while its bundle stays
        // put. Removing caches and containers now, while the .app itself can't move,
        // would gut an app the user can still open. So bundles go first, and only the
        // leftovers of apps whose bundle actually moved are trashed. An app whose
        // bundle can't be removed (helper not enabled, or a managed bundle the helper
        // still can't move) is held whole — bundle plus leftovers — as one pending
        // "needs your OK" unit, and nothing of it is touched.
        //
        // A selection where the user unticked the bundle and kept only leftovers is a
        // deliberate leftovers-only cleanup and removes right away.
        var bundleRemovingApps: [(app: InstalledApp, bundle: UninstallItem, leftovers: [UninstallItem])] = []
        var leftoverOnlyApps: [(InstalledApp, [UninstallItem])] = []
        for (app, items) in toDelete {
            if let bundle = items.first(where: { $0.category == .bundle }) {
                bundleRemovingApps.append((app, bundle, items.filter { $0.category != .bundle }))
            } else {
                leftoverOnlyApps.append((app, items))
            }
        }

        let progressBuffer = DeletionProgressBuffer()
        // Size and count each distinct path once. Two apps can resolve to the same
        // bundle-id-keyed leftover, and the delete pass trashes such a path a single
        // time (see the dedup in pass 2), so counting it twice here would leave the
        // progress total short of what is actually moved.
        var countedPaths = Set<String>()
        var totalBytes: Int64 = 0
        var totalItems = 0
        for (_, items) in toDelete {
            for item in items where countedPaths.insert(item.path.standardizedFileURL.path).inserted {
                totalBytes += item.sizeBytes
                totalItems += 1
            }
        }
        let liveSession = DeletionSession(totalBytes: totalBytes, totalItems: totalItems)
        manualDeletionSession = liveSession
        let progressPoller = Task { @MainActor [weak liveSession] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let liveSession, liveSession.phase == .cleaning else { return }
                liveSession.applyProgress(progressBuffer.snapshot())
            }
        }

        errorMessage = nil
        // `isDeleting` is already set and cleared by the outer defer above; here we
        // only need the poller torn down on exit.
        defer { progressPoller.cancel() }

        let engineStart = Date()

        // Pass 1 — bundles first. A validated .app the user picked is always eligible
        // for the administrator helper: a managed bundle needs authorization to move
        // even when its parent directory (/Applications) is writable, so parent-dir
        // writability is the wrong test for the bundle itself.
        var bundleReport: DeletionReport?
        var movedBundlePaths = Set<String>()
        if !bundleRemovingApps.isEmpty {
            var urls: [URL] = []
            var names: [String: String] = [:]
            var sizes: [String: Int64] = [:]
            var eligible = Set<String>()
            for entry in bundleRemovingApps {
                let key = entry.bundle.path.standardizedFileURL.path
                urls.append(entry.bundle.path)
                names[key] = entry.app.name
                sizes[key] = entry.bundle.sizeBytes
                eligible.insert(key)
            }
            do {
                let report = try await fileDeleter.deleteUserSelectedFiles(
                    at: urls,
                    pathToDisplayName: names,
                    pathToExpectedSizeBytes: sizes,
                    privilegedEligiblePaths: eligible,
                    onProgress: { @Sendable event in progressBuffer.ingest(event) }
                )
                bundleReport = report
                movedBundlePaths = Set(report.deletedItems.map {
                    URL(fileURLWithPath: $0.path).standardizedFileURL.path
                })
            } catch {
                manualDeletionSession = nil
                let names = bundleRemovingApps.map(\.app.name)
                let label = names.count == 1 ? names[0] : "the selected apps"
                errorMessage = "Unable to remove \(label). Please try again."
                return
            }
        }

        // Partition by whether the bundle actually left. A held app keeps every one
        // of its leftovers, deferred with the bundle. Leftovers of apps whose bundle
        // moved (and leftovers-only selections) go on to pass 2.
        var heldApps: [(InstalledApp, [UninstallItem])] = []
        var leftoverBatch: [(InstalledApp, [UninstallItem])] = leftoverOnlyApps
        for entry in bundleRemovingApps {
            if movedBundlePaths.contains(entry.bundle.path.standardizedFileURL.path) {
                if !entry.leftovers.isEmpty { leftoverBatch.append((entry.app, entry.leftovers)) }
            } else {
                heldApps.append((entry.app, [entry.bundle] + entry.leftovers))
            }
        }

        for (app, items) in heldApps {
            let key = app.bundleURL.standardizedFileURL.path
            pendingLockedUninstalls.removeAll { $0.bundlePath == key }
            pendingLockedUninstalls.append(PendingLockedUninstall(app: app, items: items))
        }

        // Pass 2 — leftovers, now that their apps are gone. A leftover escalates to
        // the helper only when its own parent directory is not writable, so ordinary
        // user-owned files never run as root.
        // Apps whose bundle did not move are still on this Mac, so a leftover one of
        // them also claims must be held back rather than swept away with the app being
        // removed. This is the two-copies case: removing one copy must not strip the
        // support files the surviving copy still reads.
        let remainingApps = installedApps.filter {
            !movedBundlePaths.contains($0.bundleURL.standardizedFileURL.path)
        }
        var keptSharedFailures: [CleanFailureItem] = []

        var leftoverReport: DeletionReport?
        if !leftoverBatch.isEmpty {
            var urls: [URL] = []
            var names: [String: String] = [:]
            var sizes: [String: Int64] = [:]
            var eligible = Set<String>()
            var seen = Set<String>()
            for (app, items) in leftoverBatch {
                for item in items {
                    // Two apps sharing a bundle id resolve to the same bundle-id-keyed
                    // leftover, so a path can appear under both. Trash and size it once.
                    let key = item.path.standardizedFileURL.path
                    guard seen.insert(key).inserted else { continue }
                    if let otherApp = appStillUsing(leftover: item, excludingOwner: app, among: remainingApps) {
                        keptSharedFailures.append(keptSharedFailure(item: item, otherApp: otherApp))
                        continue
                    }
                    urls.append(item.path)
                    names[key] = app.name
                    sizes[key] = item.sizeBytes
                    if pathNeedsPrivilege(item.path) { eligible.insert(key) }
                }
            }
            // Bundles already moved; a leftover failure here must not discard that.
            leftoverReport = try? await fileDeleter.deleteUserSelectedFiles(
                at: urls,
                pathToDisplayName: names,
                pathToExpectedSizeBytes: sizes,
                privilegedEligiblePaths: eligible,
                onProgress: { @Sendable event in progressBuffer.ingest(event) }
            )
        }

        let elapsedSeconds = Date().timeIntervalSince(engineStart)

        // A stuck bundle is always a held app, so its failure is represented by the
        // synthesized "needs your OK" row below — never also as a bundle failure here.
        let movedBytes = (bundleReport?.bytesMovedToTrash ?? 0) + (leftoverReport?.bytesMovedToTrash ?? 0)
        let report = DeletionReport(
            bytesMovedToTrash: movedBytes,
            bytesRemovedDirectly: 0,
            deletedItems: (bundleReport?.deletedItems ?? []) + (leftoverReport?.deletedItems ?? []),
            failedItems: leftoverReport?.failedItems ?? [],
            skippedItems: leftoverReport?.skippedItems ?? [],
            capacityBefore: bundleReport?.capacityBefore ?? leftoverReport?.capacityBefore,
            capacityAfter: leftoverReport?.capacityAfter ?? bundleReport?.capacityAfter,
            timestamp: Date(),
            ownershipWarningPaths: (bundleReport?.ownershipWarningPaths ?? [])
                + (leftoverReport?.ownershipWarningPaths ?? [])
        )
        incrementMovedToTrashTotal(by: report.bytesMovedToTrash)
        lastDeletionReport = report

        let deletedPaths = Set(report.deletedItems.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        })
        // An app leaves the picker once its bundle is trashed. Its selection clears
        // either way, so a partial failure doesn't leave a ghost tick.
        for (app, _) in toDelete {
            selectedAppIDs.remove(app.id)
            if deletedPaths.contains(app.bundleURL.standardizedFileURL.path) {
                installedApps.removeAll { $0.id == app.id }
            }
        }

        // Held apps moved nothing; surface each as one "needs your OK" row so the
        // panel can offer setup and then remove the whole app at once.
        let heldFailures = heldApps.map { app, items in
            CleanFailureItem(
                path: app.bundleURL.path,
                displayName: app.name,
                reason: .needsAdministrator,
                sizeBytes: items.reduce(0) { $0 + $1.sizeBytes }
            )
        }

        progressPoller.cancel()
        liveSession.completeRun(
            bytesMovedToTrash: report.bytesMovedToTrash,
            elapsedSeconds: elapsedSeconds,
            failedItems: report.userVisibleFailures + heldFailures + keptSharedFailures,
            movedToTrashCount: report.movedToTrashCount
        )
        if !report.ownershipWarningPaths.isEmpty { liveSession.noteTrashOwnershipWarning() }
        CleanupHistoryStore.shared.append(trigger: .manual, report: report)

        // Apps that declined to quit stay installed and selected, so the user can
        // quit them and retry. Surfaced after the success summary.
        if !stillOpen.isEmpty {
            errorMessage = stillOpenMessage(stillOpen)
        }
    }

    /// Asks a running app to quit and waits up to ~2s for it to close, returning
    /// whether it is no longer running. Graceful `terminate()`, never force: an app
    /// with unsaved work gets its own chance to prompt, and if the user cancels
    /// that prompt the app stays open and this returns false so the caller leaves
    /// it installed. An app with no bundle id was never reported running, so it is
    /// treated as clear to remove.
    private func quitRunningApp(_ app: InstalledApp) async -> Bool {
        guard let bundleID = app.bundleID else { return true }
        // Two installs can share one bundle id (Xcode and Xcode-beta), so match on
        // the bundle URL as well: quitting the copy being removed must not also
        // terminate the other copy the user is keeping.
        let targetURL = app.bundleURL.standardizedFileURL
        func instances() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.bundleURL?.standardizedFileURL == targetURL }
        }
        func isRunning() -> Bool { !instances().isEmpty }
        guard isRunning() else { return true }
        for instance in instances() {
            instance.terminate()
        }
        for _ in 0..<20 {
            if !isRunning() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !isRunning()
    }

    private func stillOpenMessage(_ apps: [InstalledApp]) -> String {
        let names = apps.map(\.name)
        if names.count == 1 {
            return "\(names[0]) is still open, so it was left installed. Quit it and try again."
        }
        let list = names.joined(separator: ", ")
        return "These apps are still open, so they were left installed: \(list). Quit them and try again."
    }

    /// Runs the access probe off the main actor.
    ///
    /// The probe lists `~/Library/Safari`, `~/Library/Containers`, and
    /// `~/Library/Application Support`; on a real machine those hold hundreds of
    /// entries, so it is genuine filesystem work. The onboarding permissions step polls
    /// it once a second while on screen, and running it inline on the main actor showed
    /// up in profiles as a periodic hitch during exactly the phase users described as
    /// laggy. Publishing the result is left to the caller so it can animate the change.
    nonisolated func probeFullDiskAccess() async -> Bool {
        await Task.detached(priority: .utility) {
            PermissionChecker().hasFullDiskAccess()
        }.value
    }

    func applyFullDiskAccess(_ granted: Bool) {
        guard hasFullDiskAccess != granted else { return }
        hasFullDiskAccess = granted
    }

    func refreshPermission() {
        hasFullDiskAccess = PermissionChecker().hasFullDiskAccess()
    }

    func scanGeneral() async {
        refreshPermission()
        guard hasFullDiskAccess else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanPhase = .scanning
        clearGeneralScanState()
        await runGeneralScan(generation: generation)
        await finishStandaloneScanIfCurrent(generation: generation)
    }

    func scanDeveloper() async {
        refreshPermission()
        guard hasFullDiskAccess else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanPhase = .scanning
        clearDeveloperScanState()
        await runDeveloperScan(generation: generation)
        await finishStandaloneScanIfCurrent(generation: generation)
    }

    func scanAll() async {
        // Every scan path funnels through here or the standalone variants; without
        // FDA the walk of user content folders would fire per-folder TCC prompts.
        refreshPermission()
        guard hasFullDiskAccess else { return }
        let previousTask = scanTask
        let previousGeneration = scanGeneration
        if let previousTask, !previousTask.isCancelled {
            previousTask.cancel()
            let cancellationIndicator = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self,
                      self.scanGeneration == previousGeneration,
                      self.scanTask != nil else { return }
                self.scanPhase = .cancelling
                self.scanStatusLine = "Cancelling..."
            }
            await previousTask.value
            cancellationIndicator.cancel()
        }

        scanGeneration += 1
        let generation = scanGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runFullScan(generation: generation)
        }
        scanTask = task
        await task.value
        if scanGeneration == generation {
            scanTask = nil
        }
    }

    private func runFullScan(generation: Int) async {
        let fullStart = Date()
        ScanPhaseTiming.log("runFullScan started")
        scanCompletionHideTask?.cancel()
        errorMessage = nil
        scanPhase = .scanning
        isScanningAll = true
        clearGeneralScanState()
        clearDeveloperScanState()
        defer {
            if scanGeneration == generation {
                isScanningAll = false
            }
            ScanPhaseTiming.finish("runFullScan total", since: fullStart)
        }

        await runGeneralScan(generation: generation)
        guard !Task.isCancelled, scanGeneration == generation else { return }
        await runDeveloperScan(generation: generation)
        guard !Task.isCancelled, scanGeneration == generation else { return }
        finishScan(generation: generation)
    }

    private func runGeneralScan(generation: Int) async {
        let generalStart = Date()
        scanCompletionHideTask?.cancel()
        errorMessage = nil
        isScanningGeneral = true
        await gitChecker.clearSessionCache()
        defer {
            if scanGeneration == generation {
                isScanningGeneral = false
            }
            ScanPhaseTiming.finish("runGeneralScan total", since: generalStart)
        }

        let streamStart = Date()
        var cacheItemsFound = 0
        var cacheSizesResolved = 0
        let coalesce = CacheScanCoalesceBuffers()
        defer { coalesce.debounceTask?.cancel() }

        for await event in cacheScanner.scanGeneralStream() {
            guard scanGeneration == generation, !Task.isCancelled else { return }
            switch event {
            case .status(let status):
                scanStatusLine = status
            case .found(let item):
                cacheItemsFound += 1
                coalesce.ingestFound(item)
                scheduleCacheScanFlush(coalesce: coalesce, generation: generation)
            case .sizeResolved(let path, let sizeBytes, let lastModified):
                cacheSizesResolved += 1
                coalesce.ingestSize(path: path, sizeBytes: sizeBytes, lastModified: lastModified)
                scheduleCacheScanFlush(coalesce: coalesce, generation: generation)
            }
        }
        coalesce.debounceTask?.cancel()
        flushCacheScanBuffers(coalesce: coalesce, animate: true)
        ScanPhaseTiming.finish(
            "runGeneralScan stream",
            since: streamStart,
            detail: "\(cacheItemsFound) items found, \(cacheSizesResolved) sizes resolved"
        )

        guard scanGeneration == generation, !Task.isCancelled else { return }
        let hydrateStart = Date()
        let hydrateCount = cacheItems.count
        await hydrateCacheSafetyMetadataParallel()
        ScanPhaseTiming.finish(
            "git enrichment (cache hydrate)",
            since: hydrateStart,
            detail: "\(hydrateCount) cache items"
        )
    }

    private func runDeveloperScan(generation: Int) async {
        let developerStart = Date()
        scanCompletionHideTask?.cancel()
        errorMessage = nil
        simulatorSizingGeneration += 1
        isScanningDeveloper = true
        await gitChecker.clearSessionCache()
        defer {
            if scanGeneration == generation {
                isScanningDeveloper = false
            }
            ScanPhaseTiming.finish("runDeveloperScan total", since: developerStart)
        }

        let streamStart = Date()
        var devToolsFound = 0
        var devToolSizesResolved = 0
        var simulatorsFound = 0
        var simulatorSizesResolved = 0
        let coalesce = DeveloperScanCoalesceBuffers()
        defer { coalesce.debounceTask?.cancel() }

        for await event in devScanner.scanDevToolsStream() {
            guard scanGeneration == generation, !Task.isCancelled else { return }
            switch event {
            case .status(let status):
                scanStatusLine = status
            case .devToolFound(let tool):
                devToolsFound += 1
                coalesce.ingestDevTool(tool)
                scheduleDeveloperScanFlush(coalesce: coalesce, generation: generation)
            case .devToolSizeResolved(let id, let pathSizes, let sizeBytes, let lastModified):
                devToolSizesResolved += 1
                coalesce.ingestDevToolSize(
                    id: id,
                    pathSizeBytesByPath: pathSizes,
                    sizeBytes: sizeBytes,
                    lastModified: lastModified
                )
                scheduleDeveloperScanFlush(coalesce: coalesce, generation: generation)
            case .projectGroupFound:
                break
            case .simulatorFound(let simulator):
                simulatorsFound += 1
                coalesce.ingestSimulator(simulator)
                scheduleDeveloperScanFlush(coalesce: coalesce, generation: generation)
            case .simulatorSizeResolved(let id, let sizeBytes):
                simulatorSizesResolved += 1
                coalesce.ingestSimulatorSize(id: id, sizeBytes: sizeBytes)
                scheduleDeveloperScanFlush(coalesce: coalesce, generation: generation)
            }
        }
        coalesce.debounceTask?.cancel()
        flushDeveloperScanBuffers(coalesce: coalesce, animate: false)
        ScanPhaseTiming.finish(
            "runDeveloperScan stream",
            since: streamStart,
            detail: "\(devToolsFound) dev tools, \(devToolSizesResolved) tool sizes, \(simulatorsFound) simulators, \(simulatorSizesResolved) sim sizes"
        )

        guard scanGeneration == generation, !Task.isCancelled else { return }
        let needsToolRepoHydration = devTools.contains { !$0.paths.isEmpty }
        if needsToolRepoHydration {
            isEnrichingDeveloper = true
            defer { isEnrichingDeveloper = false }
            let hydrateStart = Date()
            let pathCount = devTools.flatMap(\.paths).count
            await hydrateDeveloperToolRepoStatusesParallel()
            ScanPhaseTiming.finish(
                "git enrichment (dev tool repo hydrate)",
                since: hydrateStart,
                detail: "\(pathCount) dev tool paths"
            )
        }

        startProjectDiscovery(generation: generation)
    }

    private func startProjectDiscovery(generation: Int) {
        projectDiscoveryTask?.cancel()
        projectDiscoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let discoveryStart = Date()
            isScanningProjects = true
            defer {
                if self.scanGeneration == generation {
                    self.isScanningProjects = false
                    self.projectDiscoveryTask = nil
                }
                ScanPhaseTiming.finish("startProjectDiscovery total", since: discoveryStart)
            }

            let streamStart = Date()
            var projectGroupsFound = 0
            let coalesce = ProjectGroupCoalesceBuffers()
            defer { coalesce.debounceTask?.cancel() }

            for await event in devScanner.discoverProjectsStream() {
                guard scanGeneration == generation, !Task.isCancelled else { return }
                switch event {
                case .projectGroupFound(let group):
                    projectGroupsFound += 1
                    coalesce.ingest(group)
                    scheduleProjectGroupFlush(coalesce: coalesce, generation: generation)
                case .status:
                    break
                default:
                    break
                }
            }
            coalesce.debounceTask?.cancel()
            flushProjectGroupBuffers(coalesce: coalesce, animate: false)
            ScanPhaseTiming.finish(
                "discoverProjects stream",
                since: streamStart,
                detail: "\(projectGroupsFound) project groups published"
            )

            guard scanGeneration == generation, !Task.isCancelled else { return }
            guard !projectGroups.isEmpty else { return }
            isEnrichingDeveloper = true
            defer { isEnrichingDeveloper = false }
            let hydrateStart = Date()
            let artifactCount = projectGroups.flatMap(\.artifacts).count
            await hydrateDeveloperGitStatusesParallel()
            ScanPhaseTiming.finish(
                "git enrichment (project artifact hydrate)",
                since: hydrateStart,
                detail: "\(artifactCount) project artifacts"
            )
        }
    }

    private func finishStandaloneScanIfCurrent(generation: Int) async {
        guard scanGeneration == generation, !Task.isCancelled else { return }
        finishScan(generation: generation)
    }

    private func finishScan(generation: Int) {
        guard scanGeneration == generation else { return }
        let completedAt = Date()
        lastScanCompletedAt = completedAt
        defaults.set(completedAt, forKey: StorageKeys.lastScanCompletedAt)
        persistLastScanSafeRecoverableBytes()
        scanPhase = .completed
        scanStatusLine = "Scan complete"
        scanCompletionHideTask?.cancel()
        scanCompletionHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.scanGeneration == generation, self.scanPhase == .completed else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.scanPhase = .idle
                self.scanStatusLine = ""
            }
        }
    }

    private func persistLastScanSafeRecoverableBytes() {
        let bytes = safeRecoverableBytes
        lastScanSafeRecoverableBytes = bytes
        defaults.set(bytes, forKey: StorageKeys.lastScanSafeRecoverableBytes)
    }

    // MARK: - Scheduled cleaning

    struct ScheduledCleaningSummary {
        let deletedCount: Int
        /// Bytes moved to the trash, pending until the trash is emptied.
        let bytesMovedToTrash: Int64
        /// Real engine time for the deletion run, in seconds.
        var elapsedSeconds: Double = 0
        var movedToTrashCount: Int = 0
        var failedItems: [CleanFailureItem] = []

        var failedCount: Int { failedItems.count }
    }

    @discardableResult
    func performScheduledClean() async -> ScheduledCleaningSummary {
        refreshPermission()
        guard ScheduledCleaningPreferenceStore.shared.isEnabled, hasFullDiskAccess else {
            return ScheduledCleaningSummary(deletedCount: 0, bytesMovedToTrash: 0)
        }
        return await performSafeCleanup(
            historyTrigger: .scheduled,
            scheduledNotifications: true,
            clearSelectionsAfterCleanup: false
        )
    }

    /// Immediate safe cleanup from the menu bar (does not require scheduled cleaning to be enabled).
    @discardableResult
    func performManualSafeCleanNow(
        pinnedCandidates: [DeletionCandidate]? = nil
    ) async -> ScheduledCleaningSummary {
        var onProgress: (@Sendable (DeletionProgressEvent) -> Void)?
        if let buffer = interactiveSafeCleanupProgressBuffer {
            onProgress = { @Sendable event in buffer.ingest(event) }
        }
        let summary = await performSafeCleanup(
            historyTrigger: .manual,
            scheduledNotifications: false,
            clearSelectionsAfterCleanup: true,
            pinnedCandidates: pinnedCandidates,
            onProgress: onProgress
        )
        publishOnboardingCelebrationIfNeeded(movedToTrashBytes: summary.bytesMovedToTrash)
        return summary
    }

    func beginInteractiveSafeCleanup(
        candidates: [DeletionCandidate],
        reduceMotion: Bool,
        presentsLiveSession: Bool = false
    ) -> Bool {
        guard !isDeleting, interactiveSafeCleanupTargetPaths.isEmpty else { return false }
        let orderedPaths = Self.uniqueStandardizedPaths(for: candidates)
        guard !orderedPaths.isEmpty else { return false }

        errorMessage = nil
        interactiveSafeCleanupRemovalTask?.cancel()
        interactiveSafeCleanupMovedToTrashBytes = nil
        interactiveSafeCleanupTargetPaths = Set(orderedPaths)
        let startedAt = Date()
        interactiveCleanupStartedAt = startedAt

        if presentsLiveSession {
            // Same choreography as manual deletion: present the overlay in its
            // cleaning phase now and poll engine progress into it (~120ms).
            var seenPaths = Set<String>()
            var totalBytes: Int64 = 0
            for candidate in candidates {
                let path = candidate.path.standardizedFileURL.path
                guard !seenPaths.contains(path) else { continue }
                seenPaths.insert(path)
                totalBytes += candidate.sizeBytes
            }
            let liveSession = DeletionSession(
                totalBytes: totalBytes,
                totalItems: orderedPaths.count,
                startedAt: startedAt
            )
            interactiveSafeCleanupSession = liveSession
            let buffer = DeletionProgressBuffer()
            interactiveSafeCleanupProgressBuffer = buffer
            interactiveSafeCleanupProgressPoller = Task { @MainActor [weak liveSession] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard let liveSession, liveSession.phase == .cleaning else { return }
                    liveSession.applyProgress(buffer.snapshot())
                }
            }
        }

        if reduceMotion {
            interactiveSafeCleanupRemovedPaths = Set(orderedPaths)
        } else {
            interactiveSafeCleanupRemovedPaths = []
            interactiveSafeCleanupRemovalTask = Task { @MainActor [weak self] in
                for path in orderedPaths {
                    guard let self, !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        self.interactiveSafeCleanupRemovedPaths.insert(path)
                    }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }
        }

        return true
    }

    func completeInteractiveSafeCleanup(summary: ScheduledCleaningSummary) {
        // A pending onboarding celebration already owns the post-clean screen. Since no
        // live session was presented for this run, synthesizing a completed session here
        // would stack the standard summary beneath the celebration, surfacing a second
        // screen once the celebration is dismissed. Tear down the interactive state only.
        if defaults.bool(forKey: Self.pendingOnboardingCelebrationKey) {
            cancelInteractiveSafeCleanup()
            return
        }
        interactiveSafeCleanupMovedToTrashBytes = summary.bytesMovedToTrash
        interactiveSafeCleanupProgressPoller?.cancel()
        interactiveSafeCleanupProgressPoller = nil
        interactiveSafeCleanupProgressBuffer = nil
        if let liveSession = interactiveSafeCleanupSession, liveSession.isLiveRun {
            liveSession.completeRun(
                bytesMovedToTrash: summary.bytesMovedToTrash,
                elapsedSeconds: summary.elapsedSeconds,
                failedItems: summary.failedItems,
                movedToTrashCount: summary.movedToTrashCount
            )
        } else {
            let elapsedSeconds = interactiveCleanupStartedAt.map {
                Date().timeIntervalSince($0)
            } ?? summary.elapsedSeconds
            interactiveSafeCleanupSession = .completed(
                bytesMovedToTrash: summary.bytesMovedToTrash,
                elapsedSeconds: elapsedSeconds,
                movedToTrashCount: summary.movedToTrashCount,
                failedItems: summary.failedItems,
                startedAt: interactiveCleanupStartedAt
            )
        }
        interactiveCleanupStartedAt = nil
    }

    func cancelInteractiveSafeCleanup() {
        interactiveSafeCleanupRemovalTask?.cancel()
        interactiveSafeCleanupRemovalTask = nil
        interactiveSafeCleanupProgressPoller?.cancel()
        interactiveSafeCleanupProgressPoller = nil
        interactiveSafeCleanupProgressBuffer = nil
        interactiveCleanupStartedAt = nil
        interactiveSafeCleanupTargetPaths = []
        interactiveSafeCleanupRemovedPaths = []
        interactiveSafeCleanupMovedToTrashBytes = nil
        interactiveSafeCleanupSession = nil
    }

    func dismissInteractiveSafeCleanupCelebration() {
        cancelInteractiveSafeCleanup()
    }

    private static func uniqueStandardizedPaths(for candidates: [DeletionCandidate]) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for candidate in candidates {
            let path = candidate.path.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            paths.append(path)
        }
        return paths
    }

    static let pendingOnboardingCelebrationKey = "onboarding.pendingCelebration"

    private func publishOnboardingCelebrationIfNeeded(movedToTrashBytes: Int64) {
        guard defaults.bool(forKey: Self.pendingOnboardingCelebrationKey) else { return }
        onboardingCelebrationMovedToTrashBytes = movedToTrashBytes
    }

    private func performSafeCleanup(
        historyTrigger: CleanupTrigger,
        scheduledNotifications: Bool,
        clearSelectionsAfterCleanup: Bool,
        pinnedCandidates: [DeletionCandidate]? = nil,
        onProgress: (@Sendable (DeletionProgressEvent) -> Void)? = nil
    ) async -> ScheduledCleaningSummary {
        if pinnedCandidates == nil {
            await scanDeveloper()
            if cacheItems.isEmpty {
                await scanGeneral()
            } else {
                await hydrateCacheSafetyMetadataParallel()
            }
        }

        let syncCandidates = pinnedCandidates ?? manualSafeCleanupCandidates()

        var combined: [URL] = []
        var pathToDisplayName: [String: String] = [:]
        var pathToExpectedSizeBytes: [String: Int64] = [:]
        for candidate in syncCandidates {
            let git = await gitChecker.cleanupStatus(for: candidate.path)
            guard git == .clean else { continue }
            let std = candidate.path.standardizedFileURL
            combined.append(std)
            pathToDisplayName[std.path] = candidate.title
            pathToExpectedSizeBytes[std.path] = candidate.sizeBytes
        }

        guard !combined.isEmpty else {
            if scheduledNotifications {
                await ScheduledCleanupNotifier.notifyNothingEligible()
            }
            return ScheduledCleaningSummary(deletedCount: 0, bytesMovedToTrash: 0)
        }

        guard !isDeleting else {
            return ScheduledCleaningSummary(deletedCount: 0, bytesMovedToTrash: 0)
        }

        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        let engineStart = Date()
        do {
            let report = try await fileDeleter.deleteItems(
                at: combined,
                pathToDisplayName: pathToDisplayName,
                pathToExpectedSizeBytes: pathToExpectedSizeBytes,
                onProgress: onProgress
            )
            let elapsedSeconds = Date().timeIntervalSince(engineStart)
            let movedBytes = report.bytesMovedToTrash
            incrementMovedToTrashTotal(by: movedBytes)
            reflectDeletionReportInScanState(report)
            CleanupHistoryStore.shared.append(trigger: historyTrigger, report: report)
            if clearSelectionsAfterCleanup {
                clearAllSelections()
            }
            if scheduledNotifications {
                await ScheduledCleanupNotifier.notifyScheduledCleanFinished(
                    bytesMovedToTrash: movedBytes,
                    deletedCount: report.deletedItems.count
                )
            }
            return ScheduledCleaningSummary(
                deletedCount: report.deletedItems.count,
                bytesMovedToTrash: movedBytes,
                elapsedSeconds: elapsedSeconds,
                movedToTrashCount: report.movedToTrashCount,
                failedItems: report.userVisibleFailures
            )
        } catch {
            if scheduledNotifications {
                await ScheduledCleanupNotifier.notifyScheduledCleanFailed()
            } else {
                errorMessage = "Unable to clean safe items. Please try again."
            }
            return ScheduledCleaningSummary(deletedCount: 0, bytesMovedToTrash: 0)
        }
    }

    private func dedupeCacheItemsByPath(_ items: [CacheItem]) -> [CacheItem] {
        var seenPaths = Set<String>()
        return items.compactMap { item in
            let kept = item.locations.filter { location in
                let path = location.path.standardizedFileURL.path
                guard !seenPaths.contains(path) else { return false }
                seenPaths.insert(path)
                return true
            }
            guard !kept.isEmpty else { return nil }
            guard kept.count != item.locations.count else { return item }
            return item.withLocations(kept)
        }
    }

    private func clearGeneralScanState() {
        pendingCacheSizePaths = []
        cacheItems = []
        stagedGeneralCacheItems = []
        scanSelection.cacheIDs.removeAll()
        isEnrichingGeneral = false
    }

    private func clearDeveloperScanState() {
        projectDiscoveryTask?.cancel()
        projectDiscoveryTask = nil
        isScanningProjects = false
        pendingDevToolSizeIDs = []
        pendingProjectArtifactPaths = []
        devTools = []
        stagedDevToolsByID = [:]
        simulatorDevices = []
        stagedSimulatorsByID = [:]
        projectGroups = []
        scanSelection.devToolIDs.removeAll()
        scanSelection.simulatorIDs.removeAll()
        scanSelection.artifactIDs.removeAll()
        devToolRepoStatusByPath = [:]
        isEnrichingDeveloper = false
    }

    // MARK: - Scan stream coalescing

    /// Shared state for the scan flush throttle. See `scheduleFlush(_:generation:flush:)`.
    private protocol ScanCoalesceBuffer: AnyObject {
        var debounceTask: Task<Void, Never>? { get set }
        var lastFlushAt: ContinuousClock.Instant? { get set }
        var eventCount: Int { get }
    }

    private final class CacheScanCoalesceBuffers: ScanCoalesceBuffer {
        var pendingFound: [CacheItem] = []
        var pendingSizeUpdates: [String: (sizeBytes: Int64, lastModified: Date)] = [:]
        var debounceTask: Task<Void, Never>?
        var lastFlushAt: ContinuousClock.Instant?

        var eventCount: Int { pendingFound.count + pendingSizeUpdates.count }

        func ingestFound(_ item: CacheItem) {
            pendingFound.append(item)
        }

        func ingestSize(path: String, sizeBytes: Int64, lastModified: Date) {
            pendingSizeUpdates[path] = (sizeBytes, lastModified)
        }

        func takeSnapshot() -> (found: [CacheItem], sizes: [String: (sizeBytes: Int64, lastModified: Date)]) {
            let snapshot = (pendingFound, pendingSizeUpdates)
            pendingFound.removeAll(keepingCapacity: true)
            pendingSizeUpdates.removeAll(keepingCapacity: true)
            return snapshot
        }
    }

    private struct DevToolSizeUpdate {
        let pathSizeBytesByPath: [String: Int64]
        let sizeBytes: Int64
        let lastModified: Date
    }

    private final class DeveloperScanCoalesceBuffers: ScanCoalesceBuffer {
        var pendingTools: [String: DevTool] = [:]
        var pendingToolSizes: [String: DevToolSizeUpdate] = [:]
        var pendingSimulators: [UUID: SimulatorDevice] = [:]
        var pendingSimulatorSizes: [UUID: Int64] = [:]
        var debounceTask: Task<Void, Never>?
        var lastFlushAt: ContinuousClock.Instant?

        var eventCount: Int {
            pendingTools.count + pendingToolSizes.count + pendingSimulators.count + pendingSimulatorSizes.count
        }

        func ingestDevTool(_ tool: DevTool) {
            pendingTools[tool.id] = tool
        }

        func ingestDevToolSize(
            id: String,
            pathSizeBytesByPath: [String: Int64],
            sizeBytes: Int64,
            lastModified: Date
        ) {
            pendingToolSizes[id] = DevToolSizeUpdate(
                pathSizeBytesByPath: pathSizeBytesByPath,
                sizeBytes: sizeBytes,
                lastModified: lastModified
            )
        }

        func ingestSimulator(_ simulator: SimulatorDevice) {
            pendingSimulators[simulator.id] = simulator
        }

        func ingestSimulatorSize(id: UUID, sizeBytes: Int64) {
            pendingSimulatorSizes[id] = sizeBytes
        }

        func takeSnapshot() -> (
            tools: [String: DevTool],
            toolSizes: [String: DevToolSizeUpdate],
            simulators: [UUID: SimulatorDevice],
            simulatorSizes: [UUID: Int64]
        ) {
            let snapshot = (pendingTools, pendingToolSizes, pendingSimulators, pendingSimulatorSizes)
            pendingTools.removeAll(keepingCapacity: true)
            pendingToolSizes.removeAll(keepingCapacity: true)
            pendingSimulators.removeAll(keepingCapacity: true)
            pendingSimulatorSizes.removeAll(keepingCapacity: true)
            return snapshot
        }
    }

    private final class ProjectGroupCoalesceBuffers: ScanCoalesceBuffer {
        var pendingGroups: [String: ProjectGroup] = [:]
        var debounceTask: Task<Void, Never>?
        var lastFlushAt: ContinuousClock.Instant?

        var eventCount: Int { pendingGroups.count }

        func ingest(_ group: ProjectGroup) {
            pendingGroups[group.id] = group
        }

        func takeSnapshot() -> [ProjectGroup] {
            let snapshot = Array(pendingGroups.values)
            pendingGroups.removeAll(keepingCapacity: true)
            return snapshot
        }
    }

    /// Publishes buffered scan events on a steady cadence.
    ///
    /// This is a throttle, not a reset-debounce, and the distinction is the whole point.
    /// The previous version cancelled and re-armed the timer on every event, so a scan
    /// producing events faster than the interval never reached the deadline — the only
    /// thing that ever fired was the event-count threshold. Flushes therefore landed in
    /// irregular clumps (a burst of 100 events could publish in 20ms or in two seconds),
    /// and the sidebar total lurched and stuttered between them instead of counting up.
    ///
    /// Anchoring the next deadline to the *previous flush* rather than to the latest
    /// event keeps updates on a fixed beat whatever the event rate, which is what lets
    /// the hero figure animate smoothly.
    private func scheduleFlush<Buffer: ScanCoalesceBuffer>(
        _ coalesce: Buffer,
        generation: Int,
        flush: @escaping (Buffer) -> Void
    ) {
        // Backstop: a very fast producer still yields to the UI every `flushThreshold`
        // events rather than letting the buffer grow unbounded until the next tick.
        if coalesce.eventCount >= ScanCoalesce.flushThreshold {
            coalesce.debounceTask?.cancel()
            coalesce.debounceTask = nil
            coalesce.lastFlushAt = .now
            flush(coalesce)
            return
        }

        // A tick is already queued for this window — it will pick up everything
        // buffered since. Re-arming here is exactly the bug described above.
        guard coalesce.debounceTask == nil else { return }

        let earliest = (coalesce.lastFlushAt ?? .now) + ScanCoalesce.flushInterval
        let delay = max(.zero, ContinuousClock.Instant.now.duration(to: earliest))

        coalesce.debounceTask = Task { @MainActor [weak self, weak coalesce] in
            try? await Task.sleep(for: delay)
            guard let self, let coalesce, !Task.isCancelled else { return }
            coalesce.debounceTask = nil
            guard self.scanGeneration == generation else { return }
            coalesce.lastFlushAt = .now
            flush(coalesce)
        }
    }

    private func scheduleCacheScanFlush(coalesce: CacheScanCoalesceBuffers, generation: Int) {
        scheduleFlush(coalesce, generation: generation) { [weak self] buffer in
            self?.flushCacheScanBuffers(coalesce: buffer, animate: false)
        }
    }

    private func flushCacheScanBuffers(coalesce: CacheScanCoalesceBuffers, animate: Bool) {
        guard coalesce.eventCount > 0 else { return }
        let snapshot = coalesce.takeSnapshot()
        flushCacheScanBuffers(found: snapshot.found, sizes: snapshot.sizes, animate: animate)
    }

    private func flushCacheScanBuffers(
        found: [CacheItem],
        sizes: [String: (sizeBytes: Int64, lastModified: Date)],
        animate: Bool
    ) {
        guard !found.isEmpty || !sizes.isEmpty else { return }

        var items = stagedGeneralCacheItems
        if !found.isEmpty {
            items.append(contentsOf: found)
            for item in found {
                pendingCacheSizePaths.formUnion(
                    item.locations.map { $0.path.standardizedFileURL.path }
                )
            }
        }
        if !sizes.isEmpty {
            items = applyCacheSizeUpdates(items, updates: sizes)
            for path in sizes.keys {
                pendingCacheSizePaths.remove(path)
            }
        }

        items = DefinitionCacheGrouper.group(items)
        items = dedupeCacheItemsByPath(items)
        items = DeletionSafetyPolicy.filterCacheItems(items)
        stagedGeneralCacheItems = items

        let published = publishedCacheItems(from: items)
        if animate {
            withAnimation(.easeInOut(duration: 0.2)) {
                cacheItems = published
                reconcileCrossTabCacheDuplicates()
            }
        } else {
            cacheItems = published
            reconcileCrossTabCacheDuplicates()
        }
    }

    /// Projects staged scan results into the published list. Rows surface only once
    /// at least one location has a resolved non-zero size, so they never appear and
    /// then vanish. A row's safety level (and any mid-scan user override or selection)
    /// is pinned to what was already published, so rows never switch sections mid-scan.
    private func publishedCacheItems(from staged: [CacheItem]) -> [CacheItem] {
        let previousByID = Dictionary(cacheItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return staged.compactMap { item in
            let sized = item.locations.filter { $0.sizeBytes > 0 }
            guard !sized.isEmpty else { return nil }
            var published = sized.count == item.locations.count ? item : item.withLocations(sized)
            if let previous = previousByID[published.id] {
                if previous.safetyInfo.level != published.safetyInfo.level {
                    published.safetyInfo = previous.safetyInfo
                    published.appName = previous.appName
                }
            }
            // Hard safety net: only the two eligible risk tiers (safe / check
            // first) may surface. Anything else — an unclassified folder, or a
            // future allowlist/classification mistake — is dropped so it can
            // never leak into the UI.
            guard published.safetyInfo.level.canSurfaceInScanResults else {
                #if DEBUG
                for location in published.locations {
                    print("[Purge] Dropped ineligible scan result (\(published.safetyInfo.level.rawValue)): \(location.path.path)")
                }
                #endif
                return nil
            }
            return published
        }
    }

    private func applyCacheSizeUpdates(
        _ items: [CacheItem],
        updates: [String: (sizeBytes: Int64, lastModified: Date)]
    ) -> [CacheItem] {
        guard !updates.isEmpty else { return items }

        var updated: [CacheItem] = []
        updated.reserveCapacity(items.count)

        for item in items {
            let hasMatch = item.locations.contains { location in
                updates[location.path.standardizedFileURL.path] != nil
            }
            guard hasMatch else {
                updated.append(item)
                continue
            }

            let locations = item.locations.compactMap { location -> CacheLocation? in
                let pathKey = location.path.standardizedFileURL.path
                guard let update = updates[pathKey] else { return location }
                guard update.sizeBytes > 0 else { return nil }
                return CacheLocation(
                    path: location.path,
                    sizeBytes: update.sizeBytes,
                    lastModified: update.lastModified,
                    folderName: location.folderName
                )
            }
            guard !locations.isEmpty else { continue }
            updated.append(item.withLocations(locations))
        }
        return updated
    }

    private func scheduleDeveloperScanFlush(coalesce: DeveloperScanCoalesceBuffers, generation: Int) {
        scheduleFlush(coalesce, generation: generation) { [weak self] buffer in
            self?.flushDeveloperScanBuffers(coalesce: buffer, animate: false)
        }
    }

    private func flushDeveloperScanBuffers(coalesce: DeveloperScanCoalesceBuffers, animate: Bool) {
        guard coalesce.eventCount > 0 else { return }
        let snapshot = coalesce.takeSnapshot()
        flushDeveloperScanBuffers(
            tools: snapshot.tools,
            toolSizes: snapshot.toolSizes,
            simulators: snapshot.simulators,
            simulatorSizes: snapshot.simulatorSizes,
            animate: animate
        )
    }

    private func flushDeveloperScanBuffers(
        tools: [String: DevTool],
        toolSizes: [String: DevToolSizeUpdate],
        simulators: [UUID: SimulatorDevice],
        simulatorSizes: [UUID: Int64],
        animate: Bool
    ) {
        guard !tools.isEmpty || !toolSizes.isEmpty || !simulators.isEmpty || !simulatorSizes.isEmpty else {
            return
        }

        let apply = {
            // Discovered tools are staged until their size resolves, so the visible
            // list only ever gains rows during a scan and never loses them.
            for tool in tools.values {
                guard let offered = DeletionSafetyPolicy.devToolFilteredToOfferedCleanup(tool) else { continue }
                self.pendingDevToolSizeIDs.insert(offered.id)
                self.stagedDevToolsByID[offered.id] = offered
            }

            for (id, update) in toolSizes {
                self.pendingDevToolSizeIDs.remove(id)
                guard let tool = self.stagedDevToolsByID.removeValue(forKey: id)
                        ?? self.devTools.first(where: { $0.id == id }) else { continue }
                let updated = DevTool(
                    definitionKey: tool.definitionKey,
                    toolName: tool.toolName,
                    paths: tool.paths,
                    sizeBytes: update.sizeBytes,
                    pathSizeBytesByPath: update.pathSizeBytesByPath,
                    lastModified: update.lastModified,
                    isSelected: false,
                    isDetected: update.sizeBytes > 0,
                    safetyInfo: tool.safetyInfo,
                    reinstallSafety: tool.reinstallSafety
                )
                let existingIndex = self.devTools.firstIndex(where: { $0.id == id })
                if let offered = DeletionSafetyPolicy.devToolFilteredToOfferedCleanup(updated), offered.isDetected {
                    if let existingIndex {
                        self.devTools[existingIndex] = offered
                    } else {
                        self.devTools.append(offered)
                    }
                } else if let existingIndex {
                    self.devTools.remove(at: existingIndex)
                    self.scanSelection.devToolIDs.remove(id)
                }
            }

            if !tools.isEmpty || !toolSizes.isEmpty {
                self.devTools.sort { $0.sizeBytes > $1.sizeBytes }
            }

            for simulator in simulators.values {
                guard let offered = DeletionSafetyPolicy.simulatorFilteredToOfferedCleanup(simulator) else { continue }
                self.stagedSimulatorsByID[offered.id] = offered
            }

            for (id, sizeBytes) in simulatorSizes {
                if var staged = self.stagedSimulatorsByID.removeValue(forKey: id) {
                    guard sizeBytes > 0 else { continue }
                    staged.sizeOnDisk = sizeBytes
                    if let index = self.simulatorDevices.firstIndex(where: { $0.id == id }) {
                        self.simulatorDevices[index] = staged
                    } else {
                        self.simulatorDevices.append(staged)
                    }
                } else if let index = self.simulatorDevices.firstIndex(where: { $0.id == id }) {
                    if sizeBytes > 0 {
                        self.simulatorDevices[index].sizeOnDisk = sizeBytes
                    } else {
                        self.simulatorDevices.remove(at: index)
                    }
                }
            }

            if !simulators.isEmpty || !simulatorSizes.isEmpty {
                self.simulatorDevices.sort { ($0.sizeOnDisk ?? 0) > ($1.sizeOnDisk ?? 0) }
            }

            self.reconcileCrossTabCacheDuplicates()
        }

        if animate {
            withAnimation(.easeInOut(duration: 0.2)) { apply() }
        } else {
            apply()
        }
    }

    private func scheduleProjectGroupFlush(coalesce: ProjectGroupCoalesceBuffers, generation: Int) {
        scheduleFlush(coalesce, generation: generation) { [weak self] buffer in
            self?.flushProjectGroupBuffers(coalesce: buffer, animate: false)
        }
    }

    private func flushProjectGroupBuffers(coalesce: ProjectGroupCoalesceBuffers, animate: Bool) {
        guard coalesce.eventCount > 0 else { return }
        let groups = coalesce.takeSnapshot()
        flushProjectGroupBuffers(groups: groups, animate: animate)
    }

    private func flushProjectGroupBuffers(groups: [ProjectGroup], animate: Bool) {
        guard !groups.isEmpty else { return }

        let apply = {
            for group in groups {
                guard let offered = DeletionSafetyPolicy.projectGroupFilteredToOfferedCleanup(group) else { continue }
                let paths = offered.artifacts.map { $0.path.standardizedFileURL.path }
                self.pendingProjectArtifactPaths.formUnion(paths.filter { path in
                    offered.artifacts.first { $0.path.standardizedFileURL.path == path }?.sizeBytes == 0
                })
                if let index = self.projectGroups.firstIndex(where: { $0.id == offered.id }) {
                    self.projectGroups[index] = offered
                } else {
                    self.projectGroups.append(offered)
                }
            }
            self.projectGroups.sort { $0.totalBytes > $1.totalBytes }
        }

        if animate {
            withAnimation(.easeInOut(duration: 0.2)) { apply() }
        } else {
            apply()
        }
    }

    /// Read once per row per render, so it must not touch the filesystem — the item
    /// already carries its standardized paths.
    func cacheItemHasPendingSize(_ item: CacheItem) -> Bool {
        guard !pendingCacheSizePaths.isEmpty else { return false }
        return item.standardizedPaths.contains { pendingCacheSizePaths.contains($0) }
    }

    func projectArtifactHasPendingSize(_ artifact: ProjectCacheArtifact) -> Bool {
        pendingProjectArtifactPaths.contains(artifact.path.standardizedFileURL.path)
    }

    private func reconcileCrossTabCacheDuplicates() {
        let devPaths = Set(
            devTools
                .filter(\.isDetected)
                .flatMap(\.paths)
                .map { $0.standardizedFileURL.path }
        )
        guard !devPaths.isEmpty else { return }

        func pruned(_ items: [CacheItem]) -> [CacheItem] {
            items.compactMap { item in
                let remaining = item.locations.filter {
                    !devPaths.contains($0.path.standardizedFileURL.path)
                }
                guard !remaining.isEmpty else { return nil }
                guard remaining.count != item.locations.count else { return item }
                return item.withLocations(remaining)
            }
        }

        stagedGeneralCacheItems = pruned(stagedGeneralCacheItems)
        cacheItems = pruned(cacheItems)
    }

    private func resolvedAutomaticSafety(for item: CacheItem) -> SafetyInfo {
        if let key = item.definitionKey,
           let record = ExplanationDatabase.record(forKey: key) {
            return ExplanationDatabase.safetyInfo(from: record)
        }
        let primary = item.locations[0]
        let fallback = appDisplayName(forBundleID: primary.folderName) ?? item.appName
        return ExplanationResolver.initialSafetyForCacheFolder(
            folderName: primary.folderName,
            friendlyHeadline: fallback,
            path: primary.path
        )
    }

    private nonisolated static func worstReinstall(
        _ a: ReinstallSafetyStatus,
        _ b: ReinstallSafetyStatus
    ) -> ReinstallSafetyStatus {
        reinstallRank(a) >= reinstallRank(b) ? a : b
    }

    private nonisolated static func worstGit(_ a: GitWorktreeStatus, _ b: GitWorktreeStatus) -> GitWorktreeStatus {
        gitRank(a) >= gitRank(b) ? a : b
    }

    private nonisolated static func reinstallRank(_ status: ReinstallSafetyStatus) -> Int {
        switch status {
        case .missingLockfile: return 2
        case .reinstallable: return 1
        case .notApplicable: return 0
        }
    }

    private nonisolated static func gitRank(_ status: GitWorktreeStatus) -> Int {
        switch status {
        case .dirty: return 2
        case .unknown: return 1
        case .clean: return 0
        }
    }

    private func hydrateCacheSafetyMetadataParallel() async {
        guard !cacheItems.isEmpty else { return }
        isEnrichingGeneral = true
        defer { isEnrichingGeneral = false }
        var copy = cacheItems
        await withTaskGroup(of: (Int, ReinstallSafetyStatus, GitWorktreeStatus).self) { group in
            for index in copy.indices {
                group.addTask {
                    var reinstall = ReinstallSafetyStatus.notApplicable
                    var git = GitWorktreeStatus.clean
                    for location in copy[index].locations {
                        let url = location.path.standardizedFileURL
                        let locReinstall = Self.cacheReinstallStatus(forPath: url)
                        reinstall = Self.worstReinstall(reinstall, locReinstall)
                        let locGit = await self.gitChecker.cleanupStatus(for: url)
                        git = Self.worstGit(git, locGit)
                    }
                    return (index, reinstall, git)
                }
            }
            for await (index, reinstall, git) in group {
                copy[index].reinstallSafety = reinstall
                copy[index].gitStatus = git
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            cacheItems = copy
        }
    }

    private func hydrateDeveloperGitStatusesParallel() async {
        guard !projectGroups.isEmpty else { return }
        var snapshots: [(Int, Int, URL)] = []
        for gIndex in projectGroups.indices {
            for aIndex in projectGroups[gIndex].artifacts.indices {
                snapshots.append((gIndex, aIndex, projectGroups[gIndex].artifacts[aIndex].path))
            }
        }
        guard !snapshots.isEmpty else { return }

        let paths = snapshots.map(\.2)
        let statusesByPath = await gitChecker.cleanupStatuses(for: paths)

        var updated = projectGroups
        for (gIndex, aIndex, path) in snapshots {
            let pathKey = path.standardizedFileURL.path
            updated[gIndex].artifacts[aIndex].gitStatus = statusesByPath[pathKey] ?? .clean
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            projectGroups = updated
        }
    }

    private func hydrateDeveloperToolRepoStatusesParallel() async {
        let urls = devTools.flatMap(\.paths)
        guard !urls.isEmpty else {
            devToolRepoStatusByPath = [:]
            return
        }

        let statusesByPath = await gitChecker.cleanupStatuses(for: urls)
        withAnimation(.easeInOut(duration: 0.2)) {
            devToolRepoStatusByPath = statusesByPath
        }
    }

    private func devToolDeletionCandidate(_ tool: DevTool, path: URL) -> DeletionCandidate {
        let key = path.standardizedFileURL.path
        let pathBytes = tool.pathSizeBytesByPath[key] ?? (tool.paths.count == 1 ? tool.sizeBytes : 0)
        return DeletionCandidate(
            title: tool.safetyInfo.headline,
            path: path,
            sizeBytes: pathBytes,
            safetyInfo: tool.safetyInfo,
            reinstallCommand: tool.safetyInfo.reinstallCommand,
            subtitle: path.lastPathComponent,
            reinstallSafety: tool.reinstallSafety,
            gitStatus: devToolRepoStatusByPath[key] ?? .unknown
        )
    }

    private func simulatorDeletionCandidate(_ device: SimulatorDevice) -> DeletionCandidate {
        let path = device.folderURL.standardizedFileURL
        let bytes = device.sizeOnDisk ?? 0
        return DeletionCandidate(
            title: device.safetyInfo.headline,
            path: path,
            sizeBytes: bytes,
            safetyInfo: device.safetyInfo,
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
    }

    private func artifactDeletionCandidate(_ artifact: ProjectCacheArtifact) -> DeletionCandidate {
        DeletionCandidate(
            title: artifact.safetyInfo.headline,
            path: artifact.path,
            sizeBytes: artifact.sizeBytes,
            safetyInfo: artifact.safetyInfo,
            reinstallCommand: artifact.safetyInfo.reinstallCommand,
            subtitle: artifact.projectRoot.lastPathComponent,
            reinstallSafety: artifact.reinstallSafety,
            gitStatus: artifact.gitStatus
        )
    }

    private nonisolated static func cacheReinstallStatus(forPath url: URL) -> ReinstallSafetyStatus {
        let name = url.lastPathComponent.lowercased()
        if name == "deriveddata" { return .notApplicable }
        return ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: url)
    }

    private func incrementMovedToTrashTotal(by bytes: Int64) {
        guard bytes > 0, bytes <= Self.maxReasonableSingleCleanBytes else { return }
        let updated = min(totalMovedToTrashBytes + bytes, Self.maxStorableLifetimeMovedBytes)
        totalMovedToTrashBytes = updated
        defaults.set(totalMovedToTrashBytes, forKey: StorageKeys.totalMovedToTrashBytes)
    }

    // MARK: - Project row selection bindings

    func setCacheSelected(id: String, isSelected: Bool) {
        if isSelected { scanSelection.cacheIDs.insert(id) } else { scanSelection.cacheIDs.remove(id) }
    }

    func setAllCachesSelected(_ selected: Bool, ids: [String]) {
        if selected { scanSelection.cacheIDs.formUnion(ids) } else { scanSelection.cacheIDs.subtract(ids) }
    }

    func setDevToolSelected(id: String, isSelected: Bool) {
        if isSelected { scanSelection.devToolIDs.insert(id) } else { scanSelection.devToolIDs.remove(id) }
    }

    private func projectArtifactIndices(groupID: String, artifactID: String) -> (groupIndex: Int, artifactIndex: Int)? {
        guard let groupIndex = projectGroups.firstIndex(where: { $0.id == groupID }),
              let artifactIndex = projectGroups[groupIndex].artifacts.firstIndex(where: { $0.id == artifactID }) else {
            return nil
        }
        return (groupIndex, artifactIndex)
    }

    func setProjectArtifactSelected(groupIndex: Int, artifactIndex: Int, isSelected: Bool) {
        guard projectGroups.indices.contains(groupIndex),
              projectGroups[groupIndex].artifacts.indices.contains(artifactIndex) else { return }
        let id = projectGroups[groupIndex].artifacts[artifactIndex].id
        if isSelected { scanSelection.artifactIDs.insert(id) } else { scanSelection.artifactIDs.remove(id) }
    }

    func setProjectArtifactSelected(groupID: String, artifactID: String, isSelected: Bool) {
        guard let indices = projectArtifactIndices(groupID: groupID, artifactID: artifactID) else { return }
        setProjectArtifactSelected(
            groupIndex: indices.groupIndex,
            artifactIndex: indices.artifactIndex,
            isSelected: isSelected
        )
    }

    func setSimulatorDeviceSelected(id: UUID, isSelected: Bool) {
        if isSelected { scanSelection.simulatorIDs.insert(id) } else { scanSelection.simulatorIDs.remove(id) }
    }

    func setSimulatorGroupSelection(allSelected: Bool) {
        if allSelected {
            scanSelection.simulatorIDs.formUnion(simulatorDevices.map(\.id))
        } else {
            scanSelection.simulatorIDs.subtract(simulatorDevices.map(\.id))
        }
    }

    // MARK: - Categorization (per-row recategorize, manual mark, reset)

    private static func tag(for level: SafetyLevel) -> String {
        switch level {
        case .safe: return "safe"
        case .medium: return "medium"
        case .unknown: return "unknown"
        }
    }

    private func refreshUserOverridePaths() {
        userOverridePaths = UserOverridesStore.allOverriddenPaths()
    }

    private func refreshExcludedPaths() {
        excludedPaths = ExcludedPathsStore.allExcludedPaths()
    }

    /// Subtracts every location from future scans and drops the row. Only removes paths
    /// the allowlist already approved.
    func excludeFromScans(_ item: CacheItem) {
        for url in item.paths {
            ExcludedPathsStore.write(path: url, displayName: item.appName)
        }
        refreshExcludedPaths()

        let itemID = item.id
        let excluded = Set(item.paths.map { $0.standardizedFileURL.path })

        // A mid-scan flush republishes `cacheItems` from the staged buffer, so the row
        // has to leave the buffer too or the next flush brings it straight back. Match on
        // path as well as id: a staged twin can carry not-yet-sized locations that the
        // published row dropped, which shifts its path-derived id.
        stagedGeneralCacheItems = stagedGeneralCacheItems.compactMap { staged in
            guard staged.id != itemID else { return nil }
            let remaining = staged.locations.filter {
                !excluded.contains($0.path.standardizedFileURL.path)
            }
            guard !remaining.isEmpty else { return nil }
            guard remaining.count != staged.locations.count else { return staged }
            return staged.withLocations(remaining)
        }
        pendingCacheSizePaths.subtract(excluded)

        scanSelection.cacheIDs.remove(itemID)
        withAnimation {
            cacheItems.removeAll { $0.id == itemID }
        }
    }

    /// Subtracts every path backing a dev tool row and drops it. Only removes paths the
    /// allowlist already approved.
    func excludeFromScans(_ tool: DevTool) {
        for url in tool.paths {
            ExcludedPathsStore.write(path: url, displayName: tool.toolName)
        }
        refreshExcludedPaths()

        let toolID = tool.id
        // A pending size update re-adds a staged tool to `devTools` when it lands, so drop
        // the staged copy and stop waiting on its size.
        stagedDevToolsByID.removeValue(forKey: toolID)
        pendingDevToolSizeIDs.remove(toolID)

        scanSelection.devToolIDs.remove(toolID)
        withAnimation {
            devTools.removeAll { $0.id == toolID }
        }
    }

    /// Subtracts a simulator device folder and drops it. Only removes paths the allowlist
    /// already approved.
    func excludeFromScans(_ device: SimulatorDevice) {
        ExcludedPathsStore.write(
            path: device.folderURL,
            displayName: "\(device.deviceName) — \(device.runtimeVersion)"
        )
        refreshExcludedPaths()

        let deviceID = device.id
        // Same as dev tools: a staged simulator is re-appended once its size resolves.
        stagedSimulatorsByID.removeValue(forKey: deviceID)

        scanSelection.simulatorIDs.remove(deviceID)
        withAnimation {
            simulatorDevices.removeAll { $0.id == deviceID }
        }
    }

    /// Subtracts one artifact folder; the group vanishes once empty. Only removes paths
    /// the allowlist already approved.
    func excludeProjectArtifactFromScans(groupID: String, artifactID: String) {
        guard let indices = projectArtifactIndices(groupID: groupID, artifactID: artifactID) else { return }
        let group = projectGroups[indices.groupIndex]
        let artifact = group.artifacts[indices.artifactIndex]
        ExcludedPathsStore.write(
            path: artifact.path,
            displayName: "\(group.displayName) — \(artifact.kind.rowTag)"
        )
        refreshExcludedPaths()

        scanSelection.artifactIDs.remove(artifactID)
        withAnimation {
            var groups = projectGroups
            groups[indices.groupIndex].artifacts.removeAll { $0.id == artifactID }
            projectGroups = groups.filter { !$0.artifacts.isEmpty }
        }
    }

    /// Subtracts a project root; descendant paths stay excluded via `isExcluded`. Only
    /// removes paths the allowlist already approved.
    func excludeProjectGroupFromScans(groupID: String) {
        guard let group = projectGroups.first(where: { $0.id == groupID }) else { return }
        ExcludedPathsStore.write(path: group.rootPath, displayName: group.displayName)
        refreshExcludedPaths()

        scanSelection.artifactIDs.subtract(group.artifacts.map(\.id))
        withAnimation {
            projectGroups.removeAll { $0.id == groupID }
        }
    }

    /// Drop an exclusion. The item reappears on the next scan, but only if it still
    /// passes the normal allowlist gate.
    func removeExclusion(path: URL) {
        ExcludedPathsStore.remove(path: path)
        refreshExcludedPaths()
    }

    /// Mark a row with a manual category. Persists `user_overrides.json` keyed
    /// by the exact path and updates the row in place.
    func markCacheItem(id: String, as level: SafetyLevel) {
        guard let index = cacheItems.firstIndex(where: { $0.id == id }) else { return }
        let item = cacheItems[index]
        for location in item.locations {
            UserOverridesStore.write(
                path: location.path,
                overrideTag: Self.tag(for: level),
                originalTag: Self.tag(for: item.safetyInfo.level)
            )
        }
        let info = SafetyInfo(
            level: level,
            headline: item.safetyInfo.headline,
            explanation: manualOverrideExplanation(level: level),
            recoverySteps: "",
            reinstallCommand: item.safetyInfo.reinstallCommand
        )
        withAnimation {
            cacheItems[index].safetyInfo = info
        }
        refreshUserOverridePaths()
    }

    func markDevTool(id: String, as level: SafetyLevel) {
        guard let index = devTools.firstIndex(where: { $0.id == id }) else { return }
        let tool = devTools[index]
        guard let primary = tool.primaryOverridePath else { return }
        UserOverridesStore.write(
            path: primary,
            overrideTag: Self.tag(for: level),
            originalTag: Self.tag(for: tool.safetyInfo.level)
        )
        let info = SafetyInfo(
            level: level,
            headline: tool.safetyInfo.headline,
            explanation: manualOverrideExplanation(level: level),
            recoverySteps: "",
            reinstallCommand: tool.safetyInfo.reinstallCommand
        )
        withAnimation {
            devTools[index].safetyInfo = info
        }
        refreshUserOverridePaths()
    }

    func markProjectArtifact(groupID: String, artifactID: String, as level: SafetyLevel) {
        guard let indices = projectArtifactIndices(groupID: groupID, artifactID: artifactID) else { return }
        markProjectArtifact(groupIndex: indices.groupIndex, artifactIndex: indices.artifactIndex, as: level)
    }

    func markProjectArtifact(groupIndex: Int, artifactIndex: Int, as level: SafetyLevel) {
        guard projectGroups.indices.contains(groupIndex),
              projectGroups[groupIndex].artifacts.indices.contains(artifactIndex) else { return }
        let artifact = projectGroups[groupIndex].artifacts[artifactIndex]
        UserOverridesStore.write(
            path: artifact.path,
            overrideTag: Self.tag(for: level),
            originalTag: Self.tag(for: artifact.safetyInfo.level)
        )
        let info = SafetyInfo(
            level: level,
            headline: artifact.safetyInfo.headline,
            explanation: manualOverrideExplanation(level: level),
            recoverySteps: "",
            reinstallCommand: artifact.safetyInfo.reinstallCommand
        )
        var groups = projectGroups
        groups[groupIndex].artifacts[artifactIndex].safetyInfo = info
        withAnimation {
            projectGroups = groups
        }
        refreshUserOverridePaths()
    }

    /// Remove a single override and re-resolve the row using the automatic chain.
    func resetCacheItemToAutomatic(id: String) {
        guard let index = cacheItems.firstIndex(where: { $0.id == id }) else { return }
        let item = cacheItems[index]
        for location in item.locations {
            UserOverridesStore.remove(path: location.path)
        }
        refreshUserOverridePaths()

        let resolved = resolvedAutomaticSafety(for: item)
        withAnimation {
            cacheItems[index].safetyInfo = resolved
            cacheItems[index].appName = resolved.headline
        }
    }

    func resetDevToolToAutomatic(id: String) {
        guard let index = devTools.firstIndex(where: { $0.id == id }) else { return }
        let tool = devTools[index]
        guard let primary = tool.primaryOverridePath else { return }
        UserOverridesStore.remove(path: primary)
        refreshUserOverridePaths()

        let label = tool.toolName
        let info = DevScanner.automaticSafetyInfo(
            forDevToolLabel: label,
            primaryPath: primary
        )
        withAnimation {
            devTools[index].safetyInfo = info
        }
    }

    func resetProjectArtifactToAutomatic(groupID: String, artifactID: String) {
        guard let indices = projectArtifactIndices(groupID: groupID, artifactID: artifactID) else { return }
        resetProjectArtifactToAutomatic(groupIndex: indices.groupIndex, artifactIndex: indices.artifactIndex)
    }

    func resetProjectArtifactToAutomatic(groupIndex: Int, artifactIndex: Int) {
        guard projectGroups.indices.contains(groupIndex),
              projectGroups[groupIndex].artifacts.indices.contains(artifactIndex) else { return }
        let artifact = projectGroups[groupIndex].artifacts[artifactIndex]
        UserOverridesStore.remove(path: artifact.path)
        refreshUserOverridePaths()

        let info = SafetyInfo.forStaleProjectArtifact(
            kind: artifact.kind,
            path: artifact.path,
            reinstallCommand: artifact.safetyInfo.reinstallCommand
        )
        var groups = projectGroups
        groups[groupIndex].artifacts[artifactIndex].safetyInfo = info
        withAnimation {
            projectGroups = groups
        }
    }

    /// Re-resolve a single cache row using the local chain only.
    func recategorizeCacheItem(id: String) {
        guard let index = cacheItems.firstIndex(where: { $0.id == id }) else { return }
        let item = cacheItems[index]

        for location in item.locations {
            UserOverridesStore.remove(path: location.path)
        }
        refreshUserOverridePaths()

        let resolved = resolvedAutomaticSafety(for: item)
        scanSelection.cacheIDs.remove(item.id)
        withAnimation {
            cacheItems[index].safetyInfo = resolved
            cacheItems[index].appName = resolved.headline
        }
    }

    func recategorizeDevTool(id: String) {
        guard let index = devTools.firstIndex(where: { $0.id == id }) else { return }
        let tool = devTools[index]
        guard let primary = tool.primaryOverridePath else { return }

        UserOverridesStore.remove(path: primary)
        refreshUserOverridePaths()

        let label = tool.toolName
        let info = DevScanner.automaticSafetyInfo(
            forDevToolLabel: label,
            primaryPath: primary
        )
        scanSelection.devToolIDs.remove(tool.id)
        withAnimation {
            devTools[index].safetyInfo = info
        }
    }

    func recategorizeProjectArtifact(groupID: String, artifactID: String) {
        guard let indices = projectArtifactIndices(groupID: groupID, artifactID: artifactID) else { return }
        recategorizeProjectArtifact(groupIndex: indices.groupIndex, artifactIndex: indices.artifactIndex)
    }

    func recategorizeProjectArtifact(groupIndex: Int, artifactIndex: Int) {
        guard projectGroups.indices.contains(groupIndex),
              projectGroups[groupIndex].artifacts.indices.contains(artifactIndex) else { return }
        let artifact = projectGroups[groupIndex].artifacts[artifactIndex]

        UserOverridesStore.remove(path: artifact.path)
        refreshUserOverridePaths()

        let info = SafetyInfo.forStaleProjectArtifact(
            kind: artifact.kind,
            path: artifact.path,
            reinstallCommand: artifact.safetyInfo.reinstallCommand
        )
        scanSelection.artifactIDs.remove(artifact.id)
        var groups = projectGroups
        groups[groupIndex].artifacts[artifactIndex].safetyInfo = info
        withAnimation {
            projectGroups = groups
        }
    }

    private func manualOverrideExplanation(level: SafetyLevel) -> String {
        switch level {
        case .safe:
            return "You marked this as Safe to Clean."
        case .medium:
            return "You marked this as Check First."
        case .unknown:
            return "You marked this as Not Sure."
        }
    }
}
