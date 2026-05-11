import AppKit
import Foundation
import SwiftUI
import Combine

extension Notification.Name {
    /// Posted from `SettingsView` immediately after a new OpenRouter API key is
    /// saved successfully. Triggers the one-time "AI is now identifying your
    /// unknown folders" banner in `AppCachesView` / `DevToolsView`.
    static let apiKeyAdded = Notification.Name("APIKeyAdded")
}

@MainActor
final class PurgeStore: ObservableObject {
    private enum StorageKeys {
        static let totalRecoveredBytes = "totalRecoveredBytes"
        static let hasCompletedFirstAIScan = "hasCompletedFirstAIScan"
    }

    enum Tab: String, CaseIterable, Identifiable {
        case appCaches = "App Caches"
        case devTools = "Dev Tools"
        case settings = "Settings"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appCaches: return "internaldrive"
            case .devTools: return "hammer"
            case .settings: return "gearshape"
            }
        }
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

        static func forCache(_ item: CacheItem) -> DeletionCandidate {
            DeletionCandidate(
                title: item.appName,
                path: item.path,
                sizeBytes: item.sizeBytes,
                safetyInfo: item.safetyInfo,
                reinstallCommand: item.safetyInfo.reinstallCommand,
                subtitle: item.bundleID,
                reinstallSafety: item.reinstallSafety,
                gitStatus: item.gitStatus
            )
        }
    }

    struct UnknownDeletionPayload: Identifiable {
        let id = UUID()
        let candidates: [DeletionCandidate]
    }

    @Published var selectedTab: Tab = .appCaches
    @Published var cacheItems: [CacheItem] = []
    @Published var devTools: [DevTool] = []
    @Published var projectGroups: [ProjectGroup] = []
    /// Best-effort git status keyed by standardized tool path (`URL.path`).
    @Published private(set) var devToolRepoStatusByPath: [String: GitWorktreeStatus] = [:]
    @Published var isScanningGeneral = false
    @Published var isScanningDeveloper = false
    @Published var isDeleting = false
    @Published var errorMessage: String?
    @Published var showDeletionSheet = false
    /// When set (e.g. tab-scoped cleanup), the confirmation sheet lists these instead of `deletionCandidates`.
    @Published var deletionSheetCandidates: [DeletionCandidate]?
    @Published var pendingUnknownDeletion: UnknownDeletionPayload?
    @Published var lastDeletionReport: DeletionReport?
    @Published var hasFullDiskAccess = PermissionChecker().hasFullDiskAccess()
    @Published var totalRecoveredBytes: Int64 = 0
    @Published var firstAIScanCompletionBannerID: UUID?

    /// Drives the post-API-key "AI is now identifying your unknown folders" banner.
    /// `total` is captured once when reidentification starts; `resolved` increments per row.
    @Published private(set) var unknownReidentifyTotal: Int = 0
    @Published private(set) var unknownReidentifyResolved: Int = 0
    @Published private(set) var isReidentifyingUnknownItems: Bool = false

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

    /// After the primary confirm sheet runs, extra warnings may enqueue here.
    private var stagedDeletionCandidates: [DeletionCandidate]?
    private var stagedDeletionTrigger: CleanupTrigger = .manual
    /// Holds candidates between the primary sheet and the second high-risk alert.
    private var highRiskDeletionStagingCandidates: [DeletionCandidate]?

    init() {
        totalRecoveredBytes = Int64(defaults.integer(forKey: StorageKeys.totalRecoveredBytes))
    }

    var selectedTotalBytes: Int64 {
        let selectedCaches = cacheItems.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let selectedTools = devTools.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let projectSelected = projectGroups.flatMap(\.artifacts).filter(\.isSelected).reduce(Int64(0)) { $0 + $1.sizeBytes }
        return selectedCaches + selectedTools + projectSelected
    }

    var recoverableTotalBytes: Int64 {
        let cacheTotal = cacheItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let toolsTotal = devTools.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let projTotal = projectGroups.reduce(Int64(0)) { $0 + $1.totalBytes }
        return cacheTotal + toolsTotal + projTotal
    }

    var selectedCount: Int {
        let selectedCaches = cacheItems.filter(\.isSelected).count
        let selectedTools = devTools.filter(\.isSelected).count
        let selectedProjects = projectGroups.flatMap(\.artifacts).filter(\.isSelected).count
        return selectedCaches + selectedTools + selectedProjects
    }

    /// Manual clean can include any classification once the user confirms; excludes rows still awaiting AI.
    private func isManualDeletionCandidateEligible(_ safetyInfo: SafetyInfo) -> Bool {
        switch safetyInfo.level {
        case .safe, .medium, .danger:
            return true
        case .unknown:
            return !ExplanationResolver.isAwaitingAI(safetyInfo)
        }
    }

    /// Selected caches eligible for manual delete (includes Do Not Delete / Not Sure when selected).
    var selectedGeneralDeletionCandidates: [DeletionCandidate] {
        cacheItems.filter { $0.isSelected && isManualDeletionCandidateEligible($0.safetyInfo) }
            .map { DeletionCandidate.forCache($0) }
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

        let artifacts = projectGroups.flatMap(\.artifacts)
            .filter { $0.isSelected && isManualDeletionCandidateEligible($0.safetyInfo) }
            .map(artifactDeletionCandidate)

        let merged = tools + artifacts
        let unique = Dictionary(grouping: merged, by: { $0.path }).compactMap { $0.value.first }
        return unique.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    var deletionCandidates: [DeletionCandidate] {
        let caches = cacheItems.filter { $0.isSelected && isManualDeletionCandidateEligible($0.safetyInfo) }
            .map { DeletionCandidate.forCache($0) }

        let tools = devTools.filter { $0.isSelected }.filter(\.isDetected)
            .flatMap { tool in tool.paths.map { devToolDeletionCandidate(tool, path: $0) } }
            .filter { isManualDeletionCandidateEligible($0.safetyInfo) }

        let artifacts = projectGroups.flatMap(\.artifacts)
            .filter { $0.isSelected && isManualDeletionCandidateEligible($0.safetyInfo) }
            .map(artifactDeletionCandidate)

        let unique = Dictionary(grouping: caches + tools + artifacts, by: { $0.path }).compactMap { $0.value.first }
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
        for candidate in candidates {
            pathToDisplayName[candidate.path.standardizedFileURL.path] = candidate.title
        }

        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            let report = try await fileDeleter.deleteItems(at: urls, pathToDisplayName: pathToDisplayName)
            let freedBytes = report.actualFreedBytes > 0 ? report.actualFreedBytes : report.totalDeleted
            incrementRecoveredTotal(by: freedBytes)
            deselectSkippedItems(report.skippedItems)
            reflectDeletionReportInScanState(report)
            clearAllSelections()
            lastDeletionReport = report
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
            cacheItems.removeAll { deletedPaths.contains($0.path.standardizedFileURL.path) }

            devTools = devTools.map { tool in
                let paths = tool.paths
                let existingPaths = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
                let newSize = existingPaths.reduce(Int64(0)) { $0 + cacheScanner.calculateFolderSize(at: $1) }
                let stillDetected = !existingPaths.isEmpty
                let newSelected = tool.isSelected && stillDetected
                if newSize == tool.sizeBytes, stillDetected == tool.isDetected, newSelected == tool.isSelected {
                    return tool
                }
                return DevTool(
                    toolName: tool.toolName,
                    iconName: tool.iconName,
                    paths: paths,
                    sizeBytes: newSize,
                    isSelected: newSelected,
                    isDetected: stillDetected,
                    safetyInfo: tool.safetyInfo
                )
            }

            var groups = projectGroups
            for gi in groups.indices {
                groups[gi].artifacts.removeAll { deletedPaths.contains($0.path.standardizedFileURL.path) }
            }
            projectGroups = groups.filter { !$0.artifacts.isEmpty }
        }

        for path in deletedPaths {
            devToolRepoStatusByPath.removeValue(forKey: path)
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

        for index in cacheItems.indices where skippedPaths.contains(cacheItems[index].path.standardizedFileURL.path) {
            cacheItems[index].isSelected = false
        }

        for index in devTools.indices {
            let toolPaths = devTools[index].paths.map { $0.standardizedFileURL.path }
            if toolPaths.contains(where: { skippedPaths.contains($0) }) {
                devTools[index].isSelected = false
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
        let isFirstAIScan = !defaults.bool(forKey: StorageKeys.hasCompletedFirstAIScan)
        isScanningGeneral = true
        errorMessage = nil
        let items = await cacheScanner.scanCaches()
        await gitChecker.clearSessionCache()
        withAnimation(.easeInOut(duration: 0.2)) {
            cacheItems = items
        }
        isScanningGeneral = false
        await hydrateCacheSafetyMetadataParallel()

        let pendingFolderNames = Set(cacheItems.filter { ExplanationResolver.isAwaitingAI($0.safetyInfo) }.map(\.bundleID))
        guard !pendingFolderNames.isEmpty else {
            markFirstAIScanCompleteIfNeeded(showCompletionBanner: false)
            return
        }

        for folderName in pendingFolderNames.sorted() {
            let friendlyHeadline = cacheItems.first { $0.bundleID == folderName }?.appName ?? folderName
            let resolved = await ExplanationResolver.resolveWithAIIfNeeded(
                folderName: folderName,
                friendlyHeadline: friendlyHeadline
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                for index in cacheItems.indices where cacheItems[index].bundleID == folderName {
                    cacheItems[index].safetyInfo = resolved
                    cacheItems[index].appName = resolved.headline
                }
            }
        }

        markFirstAIScanCompleteIfNeeded(showCompletionBanner: isFirstAIScan)
    }

    func scanDeveloper() async {
        isScanningDeveloper = true
        errorMessage = nil
        let outcome = await devScanner.scanDevTools()
        await gitChecker.clearSessionCache()
        withAnimation(.easeInOut(duration: 0.2)) {
            devTools = outcome.tools
            projectGroups = outcome.projects
        }
        isScanningDeveloper = false
        await hydrateDeveloperGitStatusesParallel()
        await hydrateDeveloperToolRepoStatusesParallel()
    }

    func scanAll() async {
        await scanGeneral()
        await scanDeveloper()
    }

    // MARK: - Re-identify unknown items after a new API key is added

    /// Sweep every row that previously resolved as `.unknown` (no API key, AI
    /// failed, or simply not in the bundled DB / tier list) and ask the model
    /// for a verdict now that a key is available. Each row updates in place as
    /// soon as its result comes back so progress reflects in the UI.
    func reidentifyUnknownItems() async {
        let unknownCacheItems = cacheItems.filter { $0.safetyInfo.level == .unknown }
        let unknownArtifacts = projectGroups.flatMap(\.artifacts).filter { $0.safetyInfo.level == .unknown }
        let unknownTools = devTools.filter { $0.safetyInfo.level == .unknown }

        let total = unknownCacheItems.count + unknownArtifacts.count + unknownTools.count
        guard total > 0 else { return }

        unknownReidentifyTotal = total
        unknownReidentifyResolved = 0
        isReidentifyingUnknownItems = true
        defer { isReidentifyingUnknownItems = false }

        // Flip every unknown row to the "Checking..." placeholder before kicking
        // off any network calls so the row tooltip immediately reflects that AI
        // is identifying it (matches `ExplanationResolver.isAwaitingAI`).
        let checkingInfo = SafetyInfo(
            level: .unknown,
            headline: "Identifying...",
            explanation: ExplanationResolver.checkingExplanation,
            recoverySteps: "",
            reinstallCommand: nil
        )

        withAnimation(.easeInOut(duration: 0.2)) {
            for index in cacheItems.indices
            where cacheItems[index].safetyInfo.level == .unknown {
                cacheItems[index].safetyInfo = checkingInfo
                cacheItems[index].appName = "Identifying..."
            }
        }

        for gi in projectGroups.indices {
            for ai in projectGroups[gi].artifacts.indices
            where projectGroups[gi].artifacts[ai].safetyInfo.level == .unknown {
                withAnimation(.easeInOut(duration: 0.2)) {
                    projectGroups[gi].artifacts[ai].safetyInfo = checkingInfo
                }
            }
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            for index in devTools.indices
            where devTools[index].safetyInfo.level == .unknown {
                devTools[index].safetyInfo = checkingInfo
            }
        }

        for item in unknownCacheItems {
            let resolved = await ExplanationResolver.resolveWithAIIfNeeded(
                folderName: item.bundleID,
                friendlyHeadline: item.appName
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                for index in cacheItems.indices where cacheItems[index].bundleID == item.bundleID {
                    cacheItems[index].safetyInfo = resolved
                    cacheItems[index].appName = resolved.headline
                }
            }
            unknownReidentifyResolved += 1
        }

        for artifact in unknownArtifacts {
            let resolved = await ExplanationResolver.resolveWithAIIfNeeded(
                folderName: artifact.kind.explanationKey,
                friendlyHeadline: artifact.safetyInfo.headline
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                for gi in projectGroups.indices {
                    for ai in projectGroups[gi].artifacts.indices
                    where projectGroups[gi].artifacts[ai].path == artifact.path {
                        projectGroups[gi].artifacts[ai].safetyInfo = resolved
                    }
                }
            }
            unknownReidentifyResolved += 1
        }

        for tool in unknownTools {
            let resolved = await ExplanationResolver.resolveWithAIIfNeeded(
                folderName: tool.toolName,
                friendlyHeadline: tool.toolName
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                for index in devTools.indices where devTools[index].toolName == tool.toolName {
                    devTools[index].safetyInfo = resolved
                }
            }
            unknownReidentifyResolved += 1
        }
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
        let minDays = ScheduledCleaningPreferenceStore.shared.unusedDays.rawValue
        return await performSafeCleanup(
            referenceDate: now,
            minUnusedDays: minDays,
            historyTrigger: .scheduled,
            scheduledNotifications: true,
            clearSelectionsAfterCleanup: false
        )
    }

    /// Immediate safe cleanup from the menu bar (no “unused days” wait; does not require scheduled cleaning to be enabled).
    @discardableResult
    func performManualSafeCleanNow(referenceDate now: Date = Date()) async -> ScheduledCleaningSummary {
        await performSafeCleanup(
            referenceDate: now,
            minUnusedDays: 0,
            historyTrigger: .manual,
            scheduledNotifications: false,
            clearSelectionsAfterCleanup: true
        )
    }

    private func performSafeCleanup(
        referenceDate now: Date,
        minUnusedDays: Int,
        historyTrigger: CleanupTrigger,
        scheduledNotifications: Bool,
        clearSelectionsAfterCleanup: Bool
    ) async -> ScheduledCleaningSummary {
        await scanDeveloper()
        if cacheItems.isEmpty {
            await scanGeneral()
        } else {
            await hydrateCacheSafetyMetadataParallel()
        }

        let projectURLs = projectGroups.flatMap(\.artifacts).compactMap { artifact -> URL? in
            guard artifact.safetyInfo.level == .safe else { return nil }
            guard artifact.reinstallSafety != .missingLockfile else { return nil }
            guard artifact.gitStatus == .clean else { return nil }
            guard daysBetween(artifact.lastModified, now) >= minUnusedDays else { return nil }
            return artifact.path.standardizedFileURL
        }

        let toolURLs = devTools.flatMap { tool -> [URL] in
            guard tool.isDetected, tool.safetyInfo.level == .safe else { return [] }
            return tool.paths.compactMap { url -> URL? in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let reinstall = ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: url)
                guard reinstall != .missingLockfile else { return nil }
                guard daysBetween(FolderSizing.contentModificationDate(at: url), now) >= minUnusedDays else { return nil }
                return url.standardizedFileURL
            }
        }

        let cacheURLs = cacheItems.filter { $0.safetyInfo.level == .safe }.compactMap { item -> URL? in
            guard item.reinstallSafety != .missingLockfile else { return nil }
            guard daysBetween(FolderSizing.contentModificationDate(at: item.path), now) >= minUnusedDays else { return nil }
            guard item.gitStatus == .clean else { return nil }
            return item.path.standardizedFileURL
        }

        let rough = Array(Set(projectURLs + toolURLs + cacheURLs)).sorted { $0.path < $1.path }

        var combined: [URL] = []
        var pathToDisplayName: [String: String] = [:]
        for url in rough {
            let git = await gitChecker.cleanupStatus(for: url)
            guard git == .clean else { continue }
            let std = url.standardizedFileURL
            combined.append(std)
            pathToDisplayName[std.path] = displayNameForDeletionPath(std.path)
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
            let report = try await fileDeleter.deleteItems(at: combined, pathToDisplayName: pathToDisplayName)
            let freedBytes = report.actualFreedBytes > 0 ? report.actualFreedBytes : report.totalDeleted
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

    private func hydrateCacheSafetyMetadataParallel() async {
        guard !cacheItems.isEmpty else { return }
        var copy = cacheItems
        await withTaskGroup(of: (Int, ReinstallSafetyStatus, GitWorktreeStatus).self) { group in
            for index in copy.indices {
                group.addTask {
                    let url = copy[index].path.standardizedFileURL
                    let reinstall = Self.cacheReinstallStatus(forPath: url)
                    let git = await self.gitChecker.cleanupStatus(for: url)
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
        if let item = cacheItems.first(where: { $0.path.standardizedFileURL.path == standardizedPath }) {
            return item.appName
        }
        for tool in devTools where tool.isDetected {
            if tool.paths.contains(where: { $0.standardizedFileURL.path == standardizedPath }) {
                return tool.safetyInfo.headline
            }
        }
        if let artifact = projectGroups.flatMap(\.artifacts).first(where: { $0.path.standardizedFileURL.path == standardizedPath }) {
            return artifact.safetyInfo.headline
        }
        let fallback = URL(fileURLWithPath: standardizedPath).lastPathComponent
        return fallback.isEmpty ? standardizedPath : fallback
    }

    private func devToolDeletionCandidate(_ tool: DevTool, path: URL) -> DeletionCandidate {
        let key = path.standardizedFileURL.path
        return DeletionCandidate(
            title: tool.safetyInfo.headline,
            path: path,
            sizeBytes: cacheScanner.calculateFolderSize(at: path),
            safetyInfo: tool.safetyInfo,
            reinstallCommand: tool.safetyInfo.reinstallCommand,
            subtitle: nil,
            reinstallSafety: ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: path),
            gitStatus: devToolRepoStatusByPath[key] ?? .unknown
        )
    }

    private func artifactDeletionCandidate(_ artifact: ProjectCacheArtifact) -> DeletionCandidate {
        DeletionCandidate(
            title: artifact.safetyInfo.headline,
            path: artifact.path,
            sizeBytes: artifact.sizeBytes,
            safetyInfo: artifact.safetyInfo,
            reinstallCommand: artifact.safetyInfo.reinstallCommand,
            subtitle: artifact.projectRoot.path,
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

    private func markFirstAIScanCompleteIfNeeded(showCompletionBanner: Bool) {
        guard !defaults.bool(forKey: StorageKeys.hasCompletedFirstAIScan) else { return }
        defaults.set(true, forKey: StorageKeys.hasCompletedFirstAIScan)
        if showCompletionBanner {
            firstAIScanCompletionBannerID = UUID()
        }
    }

    // MARK: - Project row selection bindings

    func setProjectArtifactSelected(groupIndex: Int, artifactIndex: Int, isSelected: Bool) {
        guard projectGroups.indices.contains(groupIndex),
              projectGroups[groupIndex].artifacts.indices.contains(artifactIndex) else { return }
        var copy = projectGroups
        copy[groupIndex].artifacts[artifactIndex].isSelected = isSelected
        projectGroups = copy
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
    func markCacheItem(id: UUID, as level: SafetyLevel) {
        guard let index = cacheItems.firstIndex(where: { $0.id == id }) else { return }
        let item = cacheItems[index]
        UserOverridesStore.write(
            path: item.path,
            overrideTag: Self.tag(for: level),
            originalTag: Self.tag(for: item.safetyInfo.level)
        )
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

    func markDevTool(id: UUID, as level: SafetyLevel) {
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
    /// If automatic resolution lands on the AI placeholder, kick a fresh AI call.
    func resetCacheItemToAutomatic(id: UUID) {
        guard let index = cacheItems.firstIndex(where: { $0.id == id }) else { return }
        let item = cacheItems[index]
        UserOverridesStore.remove(path: item.path)
        refreshUserOverridePaths()

        let resolved = ExplanationResolver.initialSafetyForCacheFolder(
            folderName: item.bundleID,
            friendlyHeadline: appNameFromBundleIDForReset(item.bundleID) ?? item.appName,
            path: item.path
        )
        withAnimation {
            cacheItems[index].safetyInfo = resolved
            cacheItems[index].appName = resolved.headline
        }

        if ExplanationResolver.isAwaitingAI(resolved) {
            Task { [weak self, bundleID = item.bundleID, itemID = item.id, headline = resolved.headline, path = item.path] in
                let final = await ExplanationResolver.resolveWithAIIfNeeded(
                    folderName: bundleID,
                    friendlyHeadline: headline,
                    path: path
                )
                await self?.applyResolvedSafety(forCacheItemID: itemID, resolved: final)
            }
        }
    }

    func resetDevToolToAutomatic(id: UUID) {
        guard let index = devTools.firstIndex(where: { $0.id == id }) else { return }
        let tool = devTools[index]
        guard let primary = tool.primaryOverridePath else { return }
        UserOverridesStore.remove(path: primary)
        refreshUserOverridePaths()

        let label = tool.toolName
        let key = devToolExplanationKey(forToolLabel: label)
        let info = SafetyInfo.fromExplanationDatabase(
            key: key,
            friendlyFallback: label,
            reinstallCommand: tool.safetyInfo.reinstallCommand,
            path: primary
        )
        withAnimation {
            devTools[index].safetyInfo = info
        }
    }

    func resetProjectArtifactToAutomatic(groupIndex: Int, artifactIndex: Int) {
        guard projectGroups.indices.contains(groupIndex),
              projectGroups[groupIndex].artifacts.indices.contains(artifactIndex) else { return }
        let artifact = projectGroups[groupIndex].artifacts[artifactIndex]
        UserOverridesStore.remove(path: artifact.path)
        refreshUserOverridePaths()

        let info = SafetyInfo.fromExplanationDatabase(
            key: artifact.kind.explanationKey,
            friendlyFallback: artifact.kind.rowTag,
            reinstallCommand: artifact.safetyInfo.reinstallCommand,
            path: artifact.path
        )
        var groups = projectGroups
        groups[groupIndex].artifacts[artifactIndex].safetyInfo = info
        withAnimation {
            projectGroups = groups
        }
    }

    /// Force a fresh remote categorization for a single cache row. Removes the
    /// cached AI entry, displays `Identifying...`, then patches the row when
    /// the model returns.
    func recategorizeCacheItem(id: UUID) {
        guard let index = cacheItems.firstIndex(where: { $0.id == id }) else { return }
        let item = cacheItems[index]

        UserOverridesStore.remove(path: item.path)
        AICacheStore.remove(folderName: item.bundleID)
        refreshUserOverridePaths()

        let placeholder = SafetyInfo(
            level: .unknown,
            headline: item.appName,
            explanation: ExplanationResolver.checkingExplanation,
            recoverySteps: "",
            reinstallCommand: item.safetyInfo.reinstallCommand
        )
        withAnimation {
            cacheItems[index].safetyInfo = placeholder
            cacheItems[index].isSelected = false
        }

        Task { [weak self, bundleID = item.bundleID, itemID = item.id, headline = item.appName, path = item.path] in
            let final = await ExplanationResolver.recategorizeWithAI(
                folderName: bundleID,
                friendlyHeadline: headline,
                path: path
            )
            await self?.applyResolvedSafety(forCacheItemID: itemID, resolved: final)
        }
    }

    func recategorizeDevTool(id: UUID) {
        guard let index = devTools.firstIndex(where: { $0.id == id }) else { return }
        let tool = devTools[index]
        guard let primary = tool.primaryOverridePath else { return }

        UserOverridesStore.remove(path: primary)
        let folderName = primary.lastPathComponent
        AICacheStore.remove(folderName: folderName)
        refreshUserOverridePaths()

        let placeholder = SafetyInfo(
            level: .unknown,
            headline: tool.safetyInfo.headline,
            explanation: ExplanationResolver.checkingExplanation,
            recoverySteps: "",
            reinstallCommand: tool.safetyInfo.reinstallCommand
        )
        withAnimation {
            devTools[index].safetyInfo = placeholder
            devTools[index].isSelected = false
        }

        Task { [weak self, toolID = tool.id, headline = tool.safetyInfo.headline, path = primary] in
            let final = await ExplanationResolver.recategorizeWithAI(
                folderName: folderName,
                friendlyHeadline: headline,
                path: path
            )
            await self?.applyResolvedSafety(forDevToolID: toolID, resolved: final)
        }
    }

    func recategorizeProjectArtifact(groupIndex: Int, artifactIndex: Int) {
        guard projectGroups.indices.contains(groupIndex),
              projectGroups[groupIndex].artifacts.indices.contains(artifactIndex) else { return }
        let artifact = projectGroups[groupIndex].artifacts[artifactIndex]

        UserOverridesStore.remove(path: artifact.path)
        let folderName = artifact.path.lastPathComponent
        AICacheStore.remove(folderName: folderName)
        refreshUserOverridePaths()

        let placeholder = SafetyInfo(
            level: .unknown,
            headline: artifact.safetyInfo.headline,
            explanation: ExplanationResolver.checkingExplanation,
            recoverySteps: "",
            reinstallCommand: artifact.safetyInfo.reinstallCommand
        )
        var groups = projectGroups
        groups[groupIndex].artifacts[artifactIndex].safetyInfo = placeholder
        groups[groupIndex].artifacts[artifactIndex].isSelected = false
        withAnimation {
            projectGroups = groups
        }

        let artifactPath = artifact.path
        let headline = artifact.safetyInfo.headline
        Task { [weak self, gi = groupIndex, ai = artifactIndex] in
            let final = await ExplanationResolver.recategorizeWithAI(
                folderName: folderName,
                friendlyHeadline: headline,
                path: artifactPath
            )
            await self?.applyResolvedSafety(forArtifactAtGroup: gi, artifactIndex: ai, expectedPath: artifactPath, resolved: final)
        }
    }

    /// Re-resolves rows after `ai_cache.json` is cleared from Settings.
    func reapplyAutomaticCategorizationForAllRows() {
        var caches = cacheItems
        for index in caches.indices {
            let item = caches[index]
            let resolved = ExplanationResolver.initialSafetyForCacheFolder(
                folderName: item.bundleID,
                friendlyHeadline: appNameFromBundleIDForReset(item.bundleID) ?? item.appName,
                path: item.path
            )
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
            let key = devToolExplanationKey(forToolLabel: label)
            let info = SafetyInfo.fromExplanationDatabase(
                key: key,
                friendlyFallback: label,
                reinstallCommand: tool.safetyInfo.reinstallCommand,
                path: tool.primaryOverridePath
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
                let info = SafetyInfo.fromExplanationDatabase(
                    key: artifact.kind.explanationKey,
                    friendlyFallback: artifact.kind.rowTag,
                    reinstallCommand: artifact.safetyInfo.reinstallCommand,
                    path: artifact.path
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

    private func applyResolvedSafety(forCacheItemID id: UUID, resolved: SafetyInfo) {
        guard let index = cacheItems.firstIndex(where: { $0.id == id }) else { return }
        withAnimation {
            cacheItems[index].safetyInfo = resolved
            cacheItems[index].appName = resolved.headline
        }
    }

    private func applyResolvedSafety(forDevToolID id: UUID, resolved: SafetyInfo) {
        guard let index = devTools.firstIndex(where: { $0.id == id }) else { return }
        withAnimation {
            devTools[index].safetyInfo = resolved
        }
    }

    private func applyResolvedSafety(forArtifactAtGroup gi: Int, artifactIndex ai: Int, expectedPath: URL, resolved: SafetyInfo) {
        guard projectGroups.indices.contains(gi),
              projectGroups[gi].artifacts.indices.contains(ai),
              projectGroups[gi].artifacts[ai].path == expectedPath else { return }
        var groups = projectGroups
        groups[gi].artifacts[ai].safetyInfo = resolved
        withAnimation {
            projectGroups = groups
        }
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
            "Xcode Caches": "xcode",
            "Homebrew Cache": "homebrew",
            "Gradle Cache": "gradle",
            "Docker Desktop": "docker",
            "npm Cache": "npm",
            "pnpm Store": "pnpm",
            "Yarn Cache": "yarn",
            "CocoaPods": "cocoapods"
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
