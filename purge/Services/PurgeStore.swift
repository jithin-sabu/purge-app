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
        static let totalRecoveredBytes = "totalRecoveredBytes"
        static let lastScanCompletedAt = "lastScanCompletedAt"
        static let lastScanSafeRecoverableBytes = "lastScanSafeRecoverableBytes"
    }

    enum Tab: String, CaseIterable, Identifiable {
        case appCaches = "App Caches"
        case devTools = "Dev Tools"
        case largeFiles = "Large Files"
        case settings = "Settings"
        case about = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appCaches: return "internaldrive"
            case .devTools: return "hammer"
            case .largeFiles: return "tray.full"
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
    @Published var cacheItems: [CacheItem] = []
    @Published var devTools: [DevTool] = []
    @Published var simulatorDevices: [SimulatorDevice] = []
    @Published var projectGroups: [ProjectGroup] = []
    @Published var largeFiles: [LargeFile] = []
    /// Large-file selection lives in its own observable object (NOT @Published on the
    /// store) so toggling a row does not fire the store's objectWillChange and thus
    /// does not re-render the results List container — a List re-render reverts the
    /// scroll position. Only views that display selection (rows, select-all bar,
    /// delete button) observe this object directly.
    let largeFileSelection = LargeFileSelection()
    /// See `ScanSelection` — decoupled selection for the App Caches / Dev Tools tabs.
    let scanSelection = ScanSelection()
    @Published var isScanningLargeFiles = false
    @Published var showLargeFileDeletionSheet = false
    /// Best-effort git status keyed by standardized tool path (`URL.path`).
    @Published private(set) var devToolRepoStatusByPath: [String: GitWorktreeStatus] = [:]
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
    @Published var onboardingCelebrationFreedBytes: Int64?
    @Published private(set) var interactiveSafeCleanupTargetPaths: Set<String> = []
    @Published private(set) var interactiveSafeCleanupRemovedPaths: Set<String> = []
    @Published private(set) var interactiveSafeCleanupFreedBytes: Int64?
    @Published var hasFullDiskAccess = PermissionChecker().hasFullDiskAccess()
    @Published var totalRecoveredBytes: Int64 = 0
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
    private let fileDeleter = FileDeleter()
    private let defaults = UserDefaults.standard
    private let gitChecker = GitStatusChecker()

    private enum ScanCoalesce {
        static let debounceNanoseconds: UInt64 = 150_000_000
        static let flushThreshold = 100
    }

    /// Cancels stale async simulator sizing when a new dev scan starts.
    private var simulatorSizingGeneration = 0
    private var scanGeneration = 0
    private var largeFileScanGeneration = 0
    private var hasCompletedLargeFileScan = false
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
    private static let maxStorableLifetimeRecoveredBytes: Int64 = 1_000_000_000_000_000

    var hasDisplayableLifetimeStats: Bool {
        totalRecoveredBytes > 0
    }

    init() {
        var recovered = Int64(defaults.integer(forKey: StorageKeys.totalRecoveredBytes))
        if recovered > Self.maxStorableLifetimeRecoveredBytes {
            recovered = 0
            defaults.set(0, forKey: StorageKeys.totalRecoveredBytes)
        }
        totalRecoveredBytes = recovered
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

    var safeCleanupSummary: SafeCleanupSummary {
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
        !interactiveSafeCleanupTargetPaths.isEmpty && interactiveSafeCleanupFreedBytes == nil
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
            let freedBytes: Int64
            if trigger == .manual {
                freedBytes = report.totalDeleted
            } else {
                freedBytes = report.actualFreedBytes > 0 ? report.actualFreedBytes : report.totalDeleted
            }
            incrementRecoveredTotal(by: freedBytes)
            deselectSkippedItems(report.skippedItems)
            reflectDeletionReportInScanState(report)
            clearAllSelections()
            if defaults.bool(forKey: Self.pendingOnboardingCelebrationKey) {
                publishOnboardingCelebrationIfNeeded(freedBytes: freedBytes)
            } else {
                lastDeletionReport = report
            }
            progressPoller?.cancel()
            session?.completeRun(
                bytesFreed: report.totalDeleted,
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
        let result = await fileDeleter.retryDeleteItem(
            at: url,
            displayName: item.displayName,
            expectedSizeBytes: item.sizeBytes
        )
        switch result {
        case .success(let freedBytes):
            session.removeResolvedFailure(id: item.id, additionalFreedBytes: freedBytes)
            incrementRecoveredTotal(by: freedBytes)
            let deleted = DeletedItem(
                path: item.path,
                sizeBytes: freedBytes,
                displayName: item.displayName
            )
            reflectDeletionReportInScanState(
                DeletionReport(
                    totalDeleted: freedBytes,
                    deletedItems: [deleted],
                    failedItems: [],
                    skippedItems: [],
                    volumeCapacity: 0,
                    availableCapacityBefore: 0,
                    availableCapacityAfter: 0,
                    timestamp: Date()
                )
            )
            return freedBytes
        case .failure:
            return nil
        }
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
        defer {
            if largeFileScanGeneration == generation {
                isScanningLargeFiles = false
            }
        }

        let minBytes = LargeFileSizeThreshold.current().bytes
        let staleDays = LargeFileAgeThreshold.currentThresholdDays()
        var collected: [LargeFile] = []
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

    func confirmLargeFileDeletion() async {
        showLargeFileDeletionSheet = false
        let targets = selectedLargeFiles
        guard !targets.isEmpty, !isDeleting else { return }

        let urls = targets.map { $0.path.standardizedFileURL }
        var pathToDisplayName: [String: String] = [:]
        var pathToExpectedSizeBytes: [String: Int64] = [:]
        for file in targets {
            let key = file.path.standardizedFileURL.path
            pathToDisplayName[key] = file.displayName
            pathToExpectedSizeBytes[key] = file.sizeBytes
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
            incrementRecoveredTotal(by: report.totalDeleted)
            lastDeletionReport = report
            let deletedPaths = Set(report.deletedItems.map {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
            })
            withAnimation(.easeInOut(duration: 0.2)) {
                largeFiles.removeAll { deletedPaths.contains($0.id) }
            }
            largeFileSelection.ids.subtract(deletedPaths)
            progressPoller.cancel()
            liveSession.completeRun(
                bytesFreed: report.totalDeleted,
                elapsedSeconds: elapsedSeconds,
                failedItems: report.userVisibleFailures,
                movedToTrashCount: report.movedToTrashCount
            )
            CleanupHistoryStore.shared.append(trigger: .manual, report: report)
        } catch {
            manualDeletionSession = nil
            errorMessage = "Unable to delete the selected files. Please try again."
        }
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
        let freedBytes: Int64
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
            return ScheduledCleaningSummary(deletedCount: 0, freedBytes: 0)
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
        publishOnboardingCelebrationIfNeeded(freedBytes: summary.freedBytes)
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
        interactiveSafeCleanupFreedBytes = nil
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
        interactiveSafeCleanupFreedBytes = summary.freedBytes
        interactiveSafeCleanupProgressPoller?.cancel()
        interactiveSafeCleanupProgressPoller = nil
        interactiveSafeCleanupProgressBuffer = nil
        if let liveSession = interactiveSafeCleanupSession, liveSession.isLiveRun {
            liveSession.completeRun(
                bytesFreed: summary.freedBytes,
                elapsedSeconds: summary.elapsedSeconds,
                failedItems: summary.failedItems,
                movedToTrashCount: summary.movedToTrashCount
            )
        } else {
            let elapsedSeconds = interactiveCleanupStartedAt.map {
                Date().timeIntervalSince($0)
            } ?? summary.elapsedSeconds
            interactiveSafeCleanupSession = .completed(
                freedBytes: summary.freedBytes,
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
        interactiveSafeCleanupFreedBytes = nil
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

    private func publishOnboardingCelebrationIfNeeded(freedBytes: Int64) {
        guard defaults.bool(forKey: Self.pendingOnboardingCelebrationKey) else { return }
        onboardingCelebrationFreedBytes = freedBytes
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
            return ScheduledCleaningSummary(deletedCount: 0, freedBytes: 0)
        }

        guard !isDeleting else {
            return ScheduledCleaningSummary(deletedCount: 0, freedBytes: 0)
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
            let freedBytes: Int64
            if historyTrigger == .manual {
                freedBytes = report.totalDeleted
            } else {
                freedBytes = report.actualFreedBytes > 0 ? report.actualFreedBytes : report.totalDeleted
            }
            incrementRecoveredTotal(by: freedBytes)
            reflectDeletionReportInScanState(report)
            CleanupHistoryStore.shared.append(trigger: historyTrigger, report: report)
            if clearSelectionsAfterCleanup {
                clearAllSelections()
            }
            if scheduledNotifications {
                await ScheduledCleanupNotifier.notifyScheduledCleanFinished(
                    freedBytes: freedBytes,
                    deletedCount: report.deletedItems.count
                )
            }
            return ScheduledCleaningSummary(
                deletedCount: report.deletedItems.count,
                freedBytes: freedBytes,
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
            return ScheduledCleaningSummary(deletedCount: 0, freedBytes: 0)
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

    private final class CacheScanCoalesceBuffers {
        var pendingFound: [CacheItem] = []
        var pendingSizeUpdates: [String: (sizeBytes: Int64, lastModified: Date)] = [:]
        var debounceTask: Task<Void, Never>?

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

    private final class DeveloperScanCoalesceBuffers {
        var pendingTools: [String: DevTool] = [:]
        var pendingToolSizes: [String: DevToolSizeUpdate] = [:]
        var pendingSimulators: [UUID: SimulatorDevice] = [:]
        var pendingSimulatorSizes: [UUID: Int64] = [:]
        var debounceTask: Task<Void, Never>?

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

    private final class ProjectGroupCoalesceBuffers {
        var pendingGroups: [String: ProjectGroup] = [:]
        var debounceTask: Task<Void, Never>?

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

    private func scheduleCacheScanFlush(coalesce: CacheScanCoalesceBuffers, generation: Int) {
        if coalesce.eventCount >= ScanCoalesce.flushThreshold {
            coalesce.debounceTask?.cancel()
            coalesce.debounceTask = nil
            flushCacheScanBuffers(coalesce: coalesce, animate: false)
            return
        }

        coalesce.debounceTask?.cancel()
        coalesce.debounceTask = Task { @MainActor [weak self, weak coalesce] in
            try? await Task.sleep(nanoseconds: ScanCoalesce.debounceNanoseconds)
            guard let self, let coalesce, !Task.isCancelled else { return }
            guard self.scanGeneration == generation else { return }
            self.flushCacheScanBuffers(coalesce: coalesce, animate: false)
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
        if coalesce.eventCount >= ScanCoalesce.flushThreshold {
            coalesce.debounceTask?.cancel()
            coalesce.debounceTask = nil
            flushDeveloperScanBuffers(coalesce: coalesce, animate: false)
            return
        }

        coalesce.debounceTask?.cancel()
        coalesce.debounceTask = Task { @MainActor [weak self, weak coalesce] in
            try? await Task.sleep(nanoseconds: ScanCoalesce.debounceNanoseconds)
            guard let self, let coalesce, !Task.isCancelled else { return }
            guard self.scanGeneration == generation else { return }
            self.flushDeveloperScanBuffers(coalesce: coalesce, animate: false)
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
        if coalesce.eventCount >= ScanCoalesce.flushThreshold {
            coalesce.debounceTask?.cancel()
            coalesce.debounceTask = nil
            flushProjectGroupBuffers(coalesce: coalesce, animate: false)
            return
        }

        coalesce.debounceTask?.cancel()
        coalesce.debounceTask = Task { @MainActor [weak self, weak coalesce] in
            try? await Task.sleep(nanoseconds: ScanCoalesce.debounceNanoseconds)
            guard let self, let coalesce, !Task.isCancelled else { return }
            guard self.scanGeneration == generation else { return }
            self.flushProjectGroupBuffers(coalesce: coalesce, animate: false)
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

    func cacheItemHasPendingSize(_ item: CacheItem) -> Bool {
        item.locations.contains { pendingCacheSizePaths.contains($0.path.standardizedFileURL.path) }
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

    private func incrementRecoveredTotal(by bytes: Int64) {
        guard bytes > 0, bytes <= Self.maxReasonableSingleCleanBytes else { return }
        let updated = min(totalRecoveredBytes + bytes, Self.maxStorableLifetimeRecoveredBytes)
        totalRecoveredBytes = updated
        defaults.set(totalRecoveredBytes, forKey: StorageKeys.totalRecoveredBytes)
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
