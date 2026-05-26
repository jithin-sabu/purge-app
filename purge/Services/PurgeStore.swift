import AppKit
import Foundation
import SwiftUI
import Combine

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
        case settings = "Settings"

        var id: String { rawValue }
        func icon(selected: Bool) -> String {
            switch self {
            case .appCaches: return selected ? "internaldrive.fill" : "internaldrive"
            case .devTools: return selected ? "hammer.fill" : "hammer"
            case .settings: return selected ? "gearshape.fill" : "gearshape"
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
    /// Best-effort git status keyed by standardized tool path (`URL.path`).
    @Published private(set) var devToolRepoStatusByPath: [String: GitWorktreeStatus] = [:]
    @Published var isScanningGeneral = false
    @Published var isScanningDeveloper = false
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
    /// Second-step confirmation after the primary deletion sheet when the batch includes Do Not Delete or Not Sure items.
    @Published var showHighRiskDeletionSecondConfirm = false

    /// Standardized paths with manual user categorizations. Mirrors `user_overrides.json`.
    @Published private(set) var userOverridePaths: Set<String> = UserOverridesStore.allOverriddenPaths()

    private let cacheScanner = CacheScanner()
    private let devScanner = DevScanner()
    private let fileDeleter = FileDeleter()
    private let defaults = UserDefaults.standard
    private let gitChecker = GitStatusChecker()

    /// Cancels stale async simulator sizing when a new dev scan starts.
    private var simulatorSizingGeneration = 0
    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?
    private var scanCompletionHideTask: Task<Void, Never>?
    private var interactiveSafeCleanupRemovalTask: Task<Void, Never>?

    /// After the primary confirm sheet runs, extra warnings may enqueue here.
    private var stagedDeletionCandidates: [DeletionCandidate]?
    private var stagedDeletionTrigger: CleanupTrigger = .manual
    /// Holds candidates between the primary sheet and the second high-risk alert.
    private var highRiskDeletionStagingCandidates: [DeletionCandidate]?

    init() {
        totalRecoveredBytes = Int64(defaults.integer(forKey: StorageKeys.totalRecoveredBytes))
        lastScanCompletedAt = defaults.object(forKey: StorageKeys.lastScanCompletedAt) as? Date
        if defaults.object(forKey: StorageKeys.lastScanSafeRecoverableBytes) != nil {
            lastScanSafeRecoverableBytes = Int64(defaults.integer(forKey: StorageKeys.lastScanSafeRecoverableBytes))
        }
    }

    var selectedTotalBytes: Int64 {
        let selectedCaches = cacheItems.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let selectedTools = devTools.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let simSelected = simulatorDevices.filter(\.isSelected).reduce(Int64(0)) { $0 + ($1.sizeOnDisk ?? 0) }
        let projectSelected = projectGroups.flatMap(\.artifacts).filter(\.isSelected).reduce(Int64(0)) { $0 + $1.sizeBytes }
        return selectedCaches + selectedTools + simSelected + projectSelected
    }

    var recoverableTotalBytes: Int64 {
        let cacheTotal = cacheItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let toolsTotal = devTools.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let simTotal = simulatorDevices.reduce(Int64(0)) { $0 + ($1.sizeOnDisk ?? 0) }
        let projTotal = projectGroups.reduce(Int64(0)) { $0 + $1.totalBytes }
        return cacheTotal + toolsTotal + simTotal + projTotal
    }

    /// Byte totals for one-click safe cleanup, grouped by tab so sidebar and filter totals stay aligned.
    struct SafeCleanupSummary {
        var appCacheBytes: Int64 = 0
        var devToolBytes: Int64 = 0
        var projectArtifactBytes: Int64 = 0

        var totalBytes: Int64 {
            appCacheBytes + devToolBytes + projectArtifactBytes
        }

        var devToolsTabBytes: Int64 {
            devToolBytes + projectArtifactBytes
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

    /// Paths that match the same safety, git, lockfile, and staleness rules used by manual safe cleanup.
    func manualSafeCleanupCandidates(
        referenceDate now: Date = Date(),
        minUnusedDaysForCaches: Int = 0,
        minUnusedDaysForDeveloperArtifacts: Int = 0
    ) -> [DeletionCandidate] {
        _ = now
        _ = minUnusedDaysForCaches
        _ = minUnusedDaysForDeveloperArtifacts
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
                guard daysBetween(location.lastModified, now) >= minUnusedDaysForCaches else { continue }
                let path = location.path.standardizedFileURL
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

    var checkFirstRecoverableBytes: Int64 {
        func isCheckFirst(_ level: SafetyLevel) -> Bool {
            level == .medium || level == .danger
        }

        let cacheBytes = cacheItems
            .filter { isCheckFirst($0.safetyInfo.level) }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }

        let toolBytes = devTools
            .filter { $0.isDetected && isCheckFirst($0.safetyInfo.level) }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }

        let projectBytes = projectGroups
            .flatMap(\.artifacts)
            .filter { isCheckFirst($0.safetyInfo.level) }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }

        return cacheBytes + toolBytes + projectBytes
    }

    var totalRecoverableBytes: Int64 {
        let cacheBytes = cacheItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let toolBytes = devTools.filter(\.isDetected).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let projectBytes = projectGroups.flatMap(\.artifacts).reduce(Int64(0)) { $0 + $1.sizeBytes }
        return cacheBytes + toolBytes + projectBytes
    }

    var selectedCount: Int {
        let selectedCaches = cacheItems.filter(\.isSelected).count
        let selectedTools = devTools.filter(\.isSelected).count
        let selectedSims = simulatorDevices.filter(\.isSelected).count
        let selectedProjects = projectGroups.flatMap(\.artifacts).filter(\.isSelected).count
        return selectedCaches + selectedTools + selectedSims + selectedProjects
    }

    private func isManualDeletionCandidateEligible(_ safetyInfo: SafetyInfo) -> Bool {
        true
    }

    /// Selected caches eligible for manual delete (includes Do Not Delete / Not Sure when selected).
    var selectedGeneralDeletionCandidates: [DeletionCandidate] {
        cacheItems.filter { $0.isSelected && isManualDeletionCandidateEligible($0.safetyInfo) }
            .flatMap { DeletionCandidate.deletionCandidates(forCache: $0) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Selected Dev Tools paths (standard caches + grouped project artifacts).
    var selectedDeveloperDeletionCandidates: [DeletionCandidate] {
        let tools = devTools.filter(\.isSelected).filter(\.isDetected)
            .flatMap { tool in
                tool.paths.map { path in
                    devToolDeletionCandidate(tool, path: path)
                }
            }
            .filter { isManualDeletionCandidateEligible($0.safetyInfo) }

        let sims = simulatorDevices.filter(\.isSelected)
            .map(simulatorDeletionCandidate)
            .filter { isManualDeletionCandidateEligible($0.safetyInfo) }

        let artifacts = projectGroups.flatMap(\.artifacts)
            .filter { $0.isSelected && isManualDeletionCandidateEligible($0.safetyInfo) }
            .map(artifactDeletionCandidate)

        let merged = tools + sims + artifacts
        let unique = Dictionary(grouping: merged, by: { $0.path }).compactMap { $0.value.first }
        return unique.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    var deletionCandidates: [DeletionCandidate] {
        let caches = cacheItems.filter { $0.isSelected && isManualDeletionCandidateEligible($0.safetyInfo) }
            .flatMap { DeletionCandidate.deletionCandidates(forCache: $0) }

        let tools = devTools.filter { $0.isSelected }.filter(\.isDetected)
            .flatMap { tool in tool.paths.map { devToolDeletionCandidate(tool, path: $0) } }
            .filter { isManualDeletionCandidateEligible($0.safetyInfo) }

        let sims = simulatorDevices.filter(\.isSelected)
            .map(simulatorDeletionCandidate)
            .filter { isManualDeletionCandidateEligible($0.safetyInfo) }

        let artifacts = projectGroups.flatMap(\.artifacts)
            .filter { $0.isSelected && isManualDeletionCandidateEligible($0.safetyInfo) }
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
        if picks.contains(where: { $0.safetyInfo.level == .danger || $0.safetyInfo.level == .unknown }) {
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

        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            let report = try await fileDeleter.deleteItems(
                at: urls,
                pathToDisplayName: pathToDisplayName,
                pathToExpectedSizeBytes: pathToExpectedSizeBytes
            )
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
            CleanupHistoryStore.shared.append(trigger: trigger, report: report)
        } catch {
            errorMessage = trigger == .scheduled
                ? "Scheduled cleaning couldn’t finish. Open the app to try manually."
                : "Unable to clean selected items. Please try again."
        }
    }

    /// Updates in-memory scan results so removed folders disappear without requiring a full rescan
    /// (e.g. after **Done** on the summary sheet, which no longer triggers `scanAll()`).
    private func reflectDeletionReportInScanState(_ report: DeletionReport) {
        let deletedPaths = Set(report.deletedItems.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        guard !deletedPaths.isEmpty else { return }

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
                let newSelected = tool.isSelected && stillDetected
                if newSize == tool.sizeBytes, stillDetected == tool.isDetected, newSelected == tool.isSelected {
                    return tool
                }
                return DevTool(
                    definitionKey: tool.definitionKey,
                    toolName: tool.toolName,
                    paths: remainingPaths,
                    sizeBytes: newSize,
                    pathSizeBytesByPath: pathSizes,
                    lastModified: tool.lastModified,
                    isSelected: newSelected,
                    isDetected: stillDetected,
                    safetyInfo: tool.safetyInfo,
                    reinstallSafety: tool.reinstallSafety
                )
            }

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
        withAnimation {
            for index in cacheItems.indices {
                cacheItems[index].isSelected = false
            }

            for index in devTools.indices {
                devTools[index].isSelected = false
            }

            for index in simulatorDevices.indices {
                simulatorDevices[index].isSelected = false
            }

            var groupsCopy = projectGroups
            for gIndex in groupsCopy.indices {
                for aIndex in groupsCopy[gIndex].artifacts.indices {
                    groupsCopy[gIndex].artifacts[aIndex].isSelected = false
                }
            }
            projectGroups = groupsCopy
        }
    }

    /// Drop any selections that the safety policy rejected so they don't keep
    /// reappearing in the staged set on the next confirmation.
    private func deselectSkippedItems(_ skipped: [SkippedDeletionItem]) {
        guard !skipped.isEmpty else { return }
        let skippedPaths = Set(skipped.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        guard !skippedPaths.isEmpty else { return }

        for index in cacheItems.indices {
            let anySkipped = cacheItems[index].locations.contains {
                skippedPaths.contains($0.path.standardizedFileURL.path)
            }
            if anySkipped {
                cacheItems[index].isSelected = false
            }
        }

        for index in devTools.indices {
            let toolPaths = devTools[index].paths.map { $0.standardizedFileURL.path }
            if toolPaths.contains(where: { skippedPaths.contains($0) }) {
                devTools[index].isSelected = false
            }
        }

        for index in simulatorDevices.indices {
            if skippedPaths.contains(simulatorDevices[index].folderURL.standardizedFileURL.path) {
                simulatorDevices[index].isSelected = false
            }
        }

        var groupsCopy = projectGroups
        for gIndex in groupsCopy.indices {
            for aIndex in groupsCopy[gIndex].artifacts.indices {
                let path = groupsCopy[gIndex].artifacts[aIndex].path.standardizedFileURL.path
                if skippedPaths.contains(path) {
                    groupsCopy[gIndex].artifacts[aIndex].isSelected = false
                }
            }
        }
        projectGroups = groupsCopy
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
        if resolved.contains(where: { $0.safetyInfo.level == .danger || $0.safetyInfo.level == .unknown }) {
            highRiskDeletionStagingCandidates = resolved
            showHighRiskDeletionSecondConfirm = true
            return
        }
        beginManualDeletionPipeline(with: resolved)
    }

    func refreshPermission() {
        hasFullDiskAccess = PermissionChecker().hasFullDiskAccess()
    }

    func scanGeneral() async {
        scanGeneration += 1
        let generation = scanGeneration
        scanPhase = .scanning
        clearGeneralScanState()
        await runGeneralScan(generation: generation)
        await finishStandaloneScanIfCurrent(generation: generation)
    }

    func scanDeveloper() async {
        scanGeneration += 1
        let generation = scanGeneration
        scanPhase = .scanning
        clearDeveloperScanState()
        await runDeveloperScan(generation: generation)
        await finishStandaloneScanIfCurrent(generation: generation)
    }

    func scanAll() async {
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
        }

        await runGeneralScan(generation: generation)
        guard !Task.isCancelled, scanGeneration == generation else { return }
        await runDeveloperScan(generation: generation)
        guard !Task.isCancelled, scanGeneration == generation else { return }
        finishScan(generation: generation)
    }

    private func runGeneralScan(generation: Int) async {
        scanCompletionHideTask?.cancel()
        errorMessage = nil
        isScanningGeneral = true
        await gitChecker.clearSessionCache()
        defer {
            if scanGeneration == generation {
                isScanningGeneral = false
            }
        }

        for await event in cacheScanner.scanGeneralStream() {
            guard scanGeneration == generation, !Task.isCancelled else { return }
            switch event {
            case .status(let status):
                scanStatusLine = status
            case .found(let item):
                publishCacheItem(item)
            case .sizeResolved(let path, let sizeBytes, let lastModified):
                applyCacheSize(path: path, sizeBytes: sizeBytes, lastModified: lastModified)
            }
        }

        guard scanGeneration == generation, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            cacheItems = dedupeCacheItemsByPath(cacheItems)
            reconcileCrossTabCacheDuplicates()
        }
        await hydrateCacheSafetyMetadataParallel()
    }

    private func runDeveloperScan(generation: Int) async {
        scanCompletionHideTask?.cancel()
        errorMessage = nil
        simulatorSizingGeneration += 1
        isScanningDeveloper = true
        await gitChecker.clearSessionCache()
        defer {
            if scanGeneration == generation {
                isScanningDeveloper = false
            }
        }

        for await event in devScanner.scanDevToolsStream() {
            guard scanGeneration == generation, !Task.isCancelled else { return }
            switch event {
            case .status(let status):
                scanStatusLine = status
            case .devToolFound(let tool):
                publishDevTool(tool)
            case .devToolSizeResolved(let id, let pathSizes, let sizeBytes, let lastModified):
                applyDevToolSize(id: id, pathSizeBytesByPath: pathSizes, sizeBytes: sizeBytes, lastModified: lastModified)
            case .projectGroupFound(let group):
                publishProjectGroup(group)
            case .simulatorFound(let simulator):
                publishSimulator(simulator)
            case .simulatorSizeResolved(let id, let sizeBytes):
                applySimulatorSize(id: id, sizeBytes: sizeBytes)
            }
        }

        guard scanGeneration == generation, !Task.isCancelled else { return }
        let needsGitHydration = !projectGroups.isEmpty
        let needsToolRepoHydration = devTools.contains { !$0.paths.isEmpty }
        guard needsGitHydration || needsToolRepoHydration else { return }

        isEnrichingDeveloper = true
        defer { isEnrichingDeveloper = false }
        if needsGitHydration {
            await hydrateDeveloperGitStatusesParallel()
        }
        if needsToolRepoHydration {
            await hydrateDeveloperToolRepoStatusesParallel()
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
    }

    @discardableResult
    func performScheduledClean(referenceDate now: Date = Date()) async -> ScheduledCleaningSummary {
        guard ScheduledCleaningPreferenceStore.shared.isEnabled else {
            return ScheduledCleaningSummary(deletedCount: 0, freedBytes: 0)
        }
        let option = ScheduledCleaningPreferenceStore.shared.unusedDays
        return await performSafeCleanup(
            referenceDate: now,
            minUnusedDaysForCaches: option.cacheStaleDays,
            minUnusedDaysForDeveloperArtifacts: option.developerArtifactStaleDays,
            historyTrigger: .scheduled,
            scheduledNotifications: true,
            clearSelectionsAfterCleanup: false
        )
    }

    /// Immediate safe cleanup from the menu bar (no “unused days” wait; does not require scheduled cleaning to be enabled).
    @discardableResult
    func performManualSafeCleanNow(
        referenceDate now: Date = Date(),
        pinnedCandidates: [DeletionCandidate]? = nil
    ) async -> ScheduledCleaningSummary {
        let summary = await performSafeCleanup(
            referenceDate: now,
            minUnusedDaysForCaches: 0,
            minUnusedDaysForDeveloperArtifacts: 0,
            historyTrigger: .manual,
            scheduledNotifications: false,
            clearSelectionsAfterCleanup: true,
            pinnedCandidates: pinnedCandidates
        )
        publishOnboardingCelebrationIfNeeded(freedBytes: summary.freedBytes)
        return summary
    }

    func beginInteractiveSafeCleanup(
        candidates: [DeletionCandidate],
        reduceMotion: Bool
    ) -> Bool {
        guard !isDeleting, interactiveSafeCleanupTargetPaths.isEmpty else { return false }
        let orderedPaths = Self.uniqueStandardizedPaths(for: candidates)
        guard !orderedPaths.isEmpty else { return false }

        errorMessage = nil
        interactiveSafeCleanupRemovalTask?.cancel()
        interactiveSafeCleanupFreedBytes = nil
        interactiveSafeCleanupTargetPaths = Set(orderedPaths)

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

    func completeInteractiveSafeCleanup(freedBytes: Int64) {
        interactiveSafeCleanupFreedBytes = freedBytes
    }

    func cancelInteractiveSafeCleanup() {
        interactiveSafeCleanupRemovalTask?.cancel()
        interactiveSafeCleanupRemovalTask = nil
        interactiveSafeCleanupTargetPaths = []
        interactiveSafeCleanupRemovedPaths = []
        interactiveSafeCleanupFreedBytes = nil
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
        referenceDate now: Date,
        minUnusedDaysForCaches: Int,
        minUnusedDaysForDeveloperArtifacts: Int,
        historyTrigger: CleanupTrigger,
        scheduledNotifications: Bool,
        clearSelectionsAfterCleanup: Bool,
        pinnedCandidates: [DeletionCandidate]? = nil
    ) async -> ScheduledCleaningSummary {
        if pinnedCandidates == nil {
            await scanDeveloper()
            if cacheItems.isEmpty {
                await scanGeneral()
            } else {
                await hydrateCacheSafetyMetadataParallel()
            }
        }

        let syncCandidates = pinnedCandidates ?? manualSafeCleanupCandidates(
            referenceDate: now,
            minUnusedDaysForCaches: minUnusedDaysForCaches,
            minUnusedDaysForDeveloperArtifacts: minUnusedDaysForDeveloperArtifacts
        )

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

        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            let report = try await fileDeleter.deleteItems(
                at: combined,
                pathToDisplayName: pathToDisplayName,
                pathToExpectedSizeBytes: pathToExpectedSizeBytes
            )
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
            return ScheduledCleaningSummary(deletedCount: report.deletedItems.count, freedBytes: freedBytes)
        } catch {
            if scheduledNotifications {
                await ScheduledCleanupNotifier.notifyScheduledCleanFailed()
            } else {
                errorMessage = "Unable to clean safe items. Please try again."
            }
            return ScheduledCleaningSummary(deletedCount: 0, freedBytes: 0)
        }
    }

    private func daysBetween(_ start: Date, _ end: Date) -> Int {
        Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
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
        isEnrichingGeneral = false
    }

    private func clearDeveloperScanState() {
        pendingDevToolSizeIDs = []
        pendingProjectArtifactPaths = []
        devTools = []
        simulatorDevices = []
        projectGroups = []
        devToolRepoStatusByPath = [:]
        isEnrichingDeveloper = false
    }

    private func publishCacheItem(_ item: CacheItem) {
        let paths = item.locations.map { $0.path.standardizedFileURL.path }
        pendingCacheSizePaths.formUnion(paths)
        withAnimation(.easeOut(duration: 0.22)) {
            cacheItems = DefinitionCacheGrouper.group(cacheItems + [item])
            reconcileCrossTabCacheDuplicates()
        }
    }

    private func applyCacheSize(path: String, sizeBytes: Int64, lastModified: Date) {
        pendingCacheSizePaths.remove(path)
        var updated: [CacheItem] = []
        for item in cacheItems {
            let locations = item.locations.compactMap { location -> CacheLocation? in
                guard location.path.standardizedFileURL.path == path else { return location }
                guard sizeBytes > 0 else { return nil }
                return CacheLocation(
                    path: location.path,
                    sizeBytes: sizeBytes,
                    lastModified: lastModified,
                    folderName: location.folderName
                )
            }
            guard !locations.isEmpty else { continue }
            updated.append(item.withLocations(locations))
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            cacheItems = DefinitionCacheGrouper.group(updated)
            reconcileCrossTabCacheDuplicates()
        }
    }

    private func publishDevTool(_ tool: DevTool) {
        pendingDevToolSizeIDs.insert(tool.id)
        withAnimation(.easeOut(duration: 0.22)) {
            if let index = devTools.firstIndex(where: { $0.id == tool.id }) {
                devTools[index] = tool
            } else {
                devTools.append(tool)
            }
            devTools.sort { $0.sizeBytes > $1.sizeBytes }
            reconcileCrossTabCacheDuplicates()
        }
    }

    private func applyDevToolSize(
        id: String,
        pathSizeBytesByPath: [String: Int64],
        sizeBytes: Int64,
        lastModified: Date
    ) {
        pendingDevToolSizeIDs.remove(id)
        guard let index = devTools.firstIndex(where: { $0.id == id }) else { return }
        let tool = devTools[index]
        let updated = DevTool(
            definitionKey: tool.definitionKey,
            toolName: tool.toolName,
            paths: tool.paths,
            sizeBytes: sizeBytes,
            pathSizeBytesByPath: pathSizeBytesByPath,
            lastModified: lastModified,
            isSelected: tool.isSelected && sizeBytes > 0,
            isDetected: sizeBytes > 0,
            safetyInfo: tool.safetyInfo,
            reinstallSafety: tool.reinstallSafety
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            if updated.isDetected {
                devTools[index] = updated
                devTools.sort { $0.sizeBytes > $1.sizeBytes }
            } else {
                devTools.remove(at: index)
            }
            reconcileCrossTabCacheDuplicates()
        }
    }

    private func publishProjectGroup(_ group: ProjectGroup) {
        let paths = group.artifacts.map { $0.path.standardizedFileURL.path }
        pendingProjectArtifactPaths.formUnion(paths.filter { path in
            group.artifacts.first { $0.path.standardizedFileURL.path == path }?.sizeBytes == 0
        })
        withAnimation(.easeOut(duration: 0.22)) {
            if let index = projectGroups.firstIndex(where: { $0.id == group.id }) {
                projectGroups[index] = group
            } else {
                projectGroups.append(group)
            }
            projectGroups.sort { $0.totalBytes > $1.totalBytes }
        }
    }

    private func publishSimulator(_ simulator: SimulatorDevice) {
        withAnimation(.easeOut(duration: 0.22)) {
            if let index = simulatorDevices.firstIndex(where: { $0.id == simulator.id }) {
                simulatorDevices[index] = simulator
            } else {
                simulatorDevices.append(simulator)
            }
        }
    }

    private func applySimulatorSize(id: UUID, sizeBytes: Int64) {
        guard let index = simulatorDevices.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            if sizeBytes > 0 {
                simulatorDevices[index].sizeOnDisk = sizeBytes
                simulatorDevices.sort { ($0.sizeOnDisk ?? 0) > ($1.sizeOnDisk ?? 0) }
            } else {
                simulatorDevices.remove(at: index)
            }
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

        cacheItems = cacheItems.compactMap { item in
            let remaining = item.locations.filter {
                !devPaths.contains($0.path.standardizedFileURL.path)
            }
            guard !remaining.isEmpty else { return nil }
            guard remaining.count != item.locations.count else { return item }
            return item.withLocations(remaining)
        }
    }

    private func resolvedAutomaticSafety(for item: CacheItem) -> SafetyInfo {
        if let key = item.definitionKey,
           let record = ExplanationDatabase.record(forKey: key) {
            return ExplanationDatabase.safetyInfo(from: record)
        }
        let primary = item.locations[0]
        let fallback = appNameFromBundleIDForReset(primary.folderName) ?? item.appName
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
        var updated = projectGroups
        await withTaskGroup(of: (Int, Int, GitWorktreeStatus).self) { group in
            for snapshot in snapshots {
                group.addTask {
                    let status = await self.gitChecker.cleanupStatus(for: snapshot.2)
                    return (snapshot.0, snapshot.1, status)
                }
            }
            for await (gIndex, aIndex, git) in group {
                updated[gIndex].artifacts[aIndex].gitStatus = git
            }
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
        var accum: [String: GitWorktreeStatus] = [:]
        await withTaskGroup(of: (String, GitWorktreeStatus).self) { group in
            for u in urls {
                group.addTask {
                    let standardized = u.standardizedFileURL
                    let git = await self.gitChecker.cleanupStatus(for: standardized)
                    return (standardized.path, git)
                }
            }
            for await (path, git) in group {
                accum[path] = git
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            devToolRepoStatusByPath = accum
        }
    }

    /// Resolves the same friendly headline shown in scan lists for a path (scheduled cleanup).
    private func displayNameForDeletionPath(_ standardizedPath: String) -> String {
        if let item = cacheItems.first(where: { item in
            item.locations.contains { $0.path.standardizedFileURL.path == standardizedPath }
        }) {
            return item.appName
        }
        for tool in devTools where tool.isDetected {
            if tool.paths.contains(where: { $0.standardizedFileURL.path == standardizedPath }) {
                return tool.safetyInfo.headline
            }
        }
        if let sim = simulatorDevices.first(where: { $0.folderURL.standardizedFileURL.path == standardizedPath }) {
            return sim.safetyInfo.headline
        }
        if let artifact = projectGroups.flatMap(\.artifacts).first(where: { $0.path.standardizedFileURL.path == standardizedPath }) {
            return artifact.safetyInfo.headline
        }
        let fallback = URL(fileURLWithPath: standardizedPath).lastPathComponent
        return fallback.isEmpty ? standardizedPath : fallback
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
        guard bytes > 0 else { return }
        totalRecoveredBytes += bytes
        defaults.set(totalRecoveredBytes, forKey: StorageKeys.totalRecoveredBytes)
    }

    /// Re-measures detected dev tool folders so list rows and safe cleanup totals stay aligned.
    func refreshDetectedDevToolSizes() {
        // Sizes are refreshed by the background scanner and streamed into `devTools`.
    }

    // MARK: - Project row selection bindings

    func setDevToolSelected(id: String, isSelected: Bool) {
        guard let index = devTools.firstIndex(where: { $0.id == id }) else { return }
        var copy = devTools
        copy[index].isSelected = isSelected
        devTools = copy
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
        var copy = projectGroups
        copy[groupIndex].artifacts[artifactIndex].isSelected = isSelected
        projectGroups = copy
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
        guard let index = simulatorDevices.firstIndex(where: { $0.id == id }) else { return }
        var copy = simulatorDevices
        copy[index].isSelected = isSelected
        simulatorDevices = copy
    }

    func setSimulatorGroupNonDangerSelection(allSelected: Bool) {
        var copy = simulatorDevices
        for index in copy.indices where copy[index].safetyInfo.level != .danger {
            copy[index].isSelected = allSelected
        }
        simulatorDevices = copy
    }

    func setEligibleArtifactsInProjectSelected(groupIndex: Int, isSelected: Bool) {
        guard projectGroups.indices.contains(groupIndex) else { return }
        var copy = projectGroups
        for idx in copy[groupIndex].artifacts.indices {
            let info = copy[groupIndex].artifacts[idx].safetyInfo
            guard isManualDeletionCandidateEligible(info) else { continue }
            copy[groupIndex].artifacts[idx].isSelected = isSelected
        }
        projectGroups = copy
    }

    // MARK: - Categorization (per-row recategorize, manual mark, reset)

    private static func tag(for level: SafetyLevel) -> String {
        switch level {
        case .safe: return "safe"
        case .medium: return "medium"
        case .danger: return "danger"
        case .unknown: return "unknown"
        }
    }

    private func refreshUserOverridePaths() {
        userOverridePaths = UserOverridesStore.allOverriddenPaths()
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
        withAnimation {
            cacheItems[index].safetyInfo = resolved
            cacheItems[index].appName = resolved.headline
            cacheItems[index].isSelected = false
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
        withAnimation {
            devTools[index].safetyInfo = info
            devTools[index].isSelected = false
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
        var groups = projectGroups
        groups[groupIndex].artifacts[artifactIndex].safetyInfo = info
        groups[groupIndex].artifacts[artifactIndex].isSelected = false
        withAnimation {
            projectGroups = groups
        }
    }

    /// Re-resolves rows after `ai_cache.json` is cleared from Settings.
    func reapplyAutomaticCategorizationForAllRows() {
        var caches = cacheItems
        for index in caches.indices {
            let resolved = resolvedAutomaticSafety(for: caches[index])
            caches[index].safetyInfo = resolved
            caches[index].appName = resolved.headline
        }
        withAnimation {
            cacheItems = caches
        }

        var tools = devTools
        for index in tools.indices {
            let tool = tools[index]
            let label = tool.toolName
            let info = DevScanner.automaticSafetyInfo(
                forDevToolLabel: label,
                primaryPath: tool.primaryOverridePath ?? tool.paths.first
            )
            tools[index].safetyInfo = info
        }
        withAnimation {
            devTools = tools
        }

        var groups = projectGroups
        for gi in groups.indices {
            for ai in groups[gi].artifacts.indices {
                let artifact = groups[gi].artifacts[ai]
                let info = SafetyInfo.forStaleProjectArtifact(
                    kind: artifact.kind,
                    path: artifact.path,
                    reinstallCommand: artifact.safetyInfo.reinstallCommand
                )
                groups[gi].artifacts[ai].safetyInfo = info
            }
        }
        withAnimation {
            projectGroups = groups
        }

        refreshUserOverridePaths()
    }

    func clearAllUserOverridesAndReapply() {
        UserOverridesStore.clearAll()
        refreshUserOverridePaths()
        reapplyAutomaticCategorizationForAllRows()
    }

    func clearAICacheAndReapply() {
        AICacheStore.clearAll()
        reapplyAutomaticCategorizationForAllRows()
    }

    func resetEverythingAndReapply() {
        AICacheStore.clearAll()
        UserOverridesStore.clearAll()
        refreshUserOverridePaths()
        reapplyAutomaticCategorizationForAllRows()
    }

    /// Public read of the override entry for a given path so views can show the badge.
    func userOverride(forPath path: URL) -> UserOverrideEntry? {
        UserOverridesStore.read(path: path)
    }

    private func appNameFromBundleIDForReset(_ bundleID: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: appURL.path)
    }

    private func devToolExplanationKey(forToolLabel toolLabel: String) -> String {
        let map: [String: String] = [
            "Xcode Derived Data": "DerivedData",
            "Xcode iOS DeviceSupport": "iOS DeviceSupport",
            "Xcode Archives": "archives",
            "Xcode Caches": "xcode",
            "Homebrew Cache": "homebrew",
            "Gradle Cache": "gradle",
            "Docker Desktop": "docker",
            "npm Cache": "npm",
            "pnpm Store": "pnpm",
            "Yarn Cache": "yarn",
            "CocoaPods": "cocoapods",
            "Git Worktrees": "gitworktrees",
            "VS Code Cache": "vscode",
            "Cursor Cache": "cursor",
            "JetBrains Cache": "jetbrains",
            "Zed Cache": "zed",
            "Go Module Cache": "go",
            "Maven Cache": "maven",
            "SBT Cache": "sbt",
            "Ruby Gems": "rubygems",
            "Bundler Cache": "bundler",
            "Composer Cache": "composer",
            "Cargo Registry": "cargo",
            "Terraform Cache": "terraform",
            "GitHub Actions Cache": "githubactions",
            "Vagrant Cache": "vagrant",
            "Zsh Cache": "zsh",
            "Electron App Caches": "electron",
            "Playwright Browsers": "playwright"
        ]
        return map[toolLabel] ?? toolLabel
    }

    private func manualOverrideExplanation(level: SafetyLevel) -> String {
        switch level {
        case .safe:
            return "You marked this as Safe to Clean."
        case .medium:
            return "You marked this as Check First."
        case .danger:
            return "You marked this as Do Not Delete."
        case .unknown:
            return "You marked this as Not Sure."
        }
    }
}
