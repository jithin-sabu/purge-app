import AppKit
import SwiftUI

struct DevToolsView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isLoading: Bool
    let onScan: () -> Void

    @State private var expandedProjectRoots = Set<String>()
    @State private var iosSimulatorsExpanded = false
    /// Last completed dev scan; stabilizes chip counts during an in-flight rescan.
    @State private var displayedDevTools: [DevTool] = []
    @State private var displayedProjectGroups: [ProjectGroup] = []
    @State private var displayedSimulatorDevices: [SimulatorDevice] = []

    /// Stable list IDs so sibling `ForEach` loops in the same `List` never share
    /// bare `Int` identities (which can duplicate or swap rows on expand/collapse).
    private struct ProjectGroupRowKey: Hashable, Identifiable {
        let id: String
        let groupIndex: Int
        static func make(_ groupIndex: Int) -> ProjectGroupRowKey {
            ProjectGroupRowKey(id: "project-group-\(groupIndex)", groupIndex: groupIndex)
        }
    }

    private struct ProjectArtifactRowKey: Hashable, Identifiable {
        let id: String
        let groupIndex: Int
        let artifactIndex: Int
        static func make(groupIndex: Int, artifactIndex: Int) -> ProjectArtifactRowKey {
            ProjectArtifactRowKey(
                id: "project-\(groupIndex)-artifact-\(artifactIndex)",
                groupIndex: groupIndex,
                artifactIndex: artifactIndex
            )
        }
    }

    private enum MergedDevStandardRow: Hashable, Identifiable {
        case tool(index: Int)
        case simulators

        var id: String {
            switch self {
            case .tool(let index): return "merged-tool-\(index)"
            case .simulators: return "merged-simulators"
            }
        }
    }

    @AppStorage("filter.devTools") private var filterRaw: String = SafetyFilter.all.rawValue
    @AppStorage("sort.devTools") private var sortRaw: String = SortOption.sizeDesc.rawValue

    private var currentSafetyFilter: SafetyFilter {
        SafetyFilter(rawValue: filterRaw) ?? .all
    }

    private var safetyFilterBinding: Binding<SafetyFilter> {
        Binding(
            get: { SafetyFilter(rawValue: filterRaw) ?? .all },
            set: { filterRaw = $0.rawValue }
        )
    }

    private var sortOptionBinding: Binding<SortOption> {
        Binding(
            get: { SortOption(rawValue: sortRaw) ?? .sizeDesc },
            set: { sortRaw = $0.rawValue }
        )
    }

    private var currentSort: SortOption {
        SortOption(rawValue: sortRaw) ?? .sizeDesc
    }

    private func artifactVisible(_ info: SafetyInfo) -> Bool {
        currentSafetyFilter.matches(info)
    }

    private func groupHasVisibleArtifacts(_ group: ProjectGroup) -> Bool {
        group.artifacts.contains {
            artifactVisible($0.safetyInfo) && !isVisuallyRemovedBySafeCleanup($0)
        }
    }

    private func filteredProjectGroupIndices() -> [Int] {
        store.projectGroups.indices.filter { groupHasVisibleArtifacts(store.projectGroups[$0]) }
    }

    private func sortedProjectGroupIndices() -> [Int] {
        let ix = filteredProjectGroupIndices()
        let groups = store.projectGroups
        switch currentSort {
        case .sizeDesc:
            return ix.sorted { groups[$0].totalBytes > groups[$1].totalBytes }
        case .sizeAsc:
            return ix.sorted { groups[$0].totalBytes < groups[$1].totalBytes }
        case .dateNewest:
            return ix.sorted { groupModified(groups[$0]) > groupModified(groups[$1]) }
        case .dateOldest:
            return ix.sorted { groupModified(groups[$0]) < groupModified(groups[$1]) }
        case .nameAZ:
            return ix.sorted {
                groups[$0].displayName.localizedCaseInsensitiveCompare(groups[$1].displayName) == .orderedAscending
            }
        }
    }

    private func groupModified(_ group: ProjectGroup) -> Date {
        group.artifacts.map(\.lastModified).max() ?? .distantPast
    }

    private func standardToolIndices() -> [Int] {
        Array(store.devTools.indices)
    }

    private func standardToolVisible(_ index: Int) -> Bool {
        guard store.devTools[index].isDetected else { return false }
        return artifactVisible(store.devTools[index].safetyInfo)
            && !isVisuallyRemovedBySafeCleanup(store.devTools[index])
    }

    private func filteredStandardToolIndices() -> [Int] {
        standardToolIndices().filter { standardToolVisible($0) }
    }

    private func sortedStandardToolIndices() -> [Int] {
        let ix = filteredStandardToolIndices()
        let tools = store.devTools
        switch currentSort {
        case .sizeDesc:
            return ix.sorted { tools[$0].sizeBytes > tools[$1].sizeBytes }
        case .sizeAsc:
            return ix.sorted { tools[$0].sizeBytes < tools[$1].sizeBytes }
        case .dateNewest:
            return ix.sorted { devToolModified(tools[$0]) > devToolModified(tools[$1]) }
        case .dateOldest:
            return ix.sorted { devToolModified(tools[$0]) < devToolModified(tools[$1]) }
        case .nameAZ:
            return ix.sorted {
                tools[$0].toolName.localizedCaseInsensitiveCompare(tools[$1].toolName) == .orderedAscending
            }
        }
    }

    private var simulatorSectionVisible: Bool {
        !store.simulatorDevices.isEmpty
            && store.simulatorDevices.contains { artifactVisible($0.safetyInfo) }
    }

    private func visibleSimulatorIndices() -> [Int] {
        store.simulatorDevices.indices.filter { artifactVisible(store.simulatorDevices[$0].safetyInfo) }
    }

    private func sortedVisibleSimulatorIndices() -> [Int] {
        let raw = visibleSimulatorIndices()
        let list = store.simulatorDevices
        switch currentSort {
        case .sizeDesc:
            return raw.sorted { (list[$0].sizeOnDisk ?? 0) > (list[$1].sizeOnDisk ?? 0) }
        case .sizeAsc:
            return raw.sorted { (list[$0].sizeOnDisk ?? 0) < (list[$1].sizeOnDisk ?? 0) }
        case .dateNewest:
            return raw.sorted { (list[$0].lastBootedAt ?? .distantPast) > (list[$1].lastBootedAt ?? .distantPast) }
        case .dateOldest:
            return raw.sorted { (list[$0].lastBootedAt ?? .distantPast) < (list[$1].lastBootedAt ?? .distantPast) }
        case .nameAZ:
            return raw.sorted {
                list[$0].safetyInfo.headline.localizedCaseInsensitiveCompare(list[$1].safetyInfo.headline) == .orderedAscending
            }
        }
    }

    private func simulatorSectionByteTotal() -> Int64 {
        visibleSimulatorIndices().reduce(Int64(0)) { $0 + (store.simulatorDevices[$1].sizeOnDisk ?? 0) }
    }

    private var simulatorSectionHasPendingSizes: Bool {
        visibleSimulatorIndices().contains { store.simulatorDevices[$0].sizeOnDisk == nil }
    }

    private func simulatorSectionModifiedDate() -> Date {
        visibleSimulatorIndices()
            .map { store.simulatorDevices[$0].lastBootedAt ?? .distantPast }
            .max() ?? .distantPast
    }

    private func worstSafetyLevel(_ levels: [SafetyLevel]) -> SafetyLevel {
        if levels.contains(.danger) { return .danger }
        if levels.contains(.medium) { return .medium }
        if levels.contains(.unknown) { return .unknown }
        return .safe
    }

    private func simulatorParentSafetyInfo() -> SafetyInfo {
        let visible = visibleSimulatorIndices().map { store.simulatorDevices[$0] }
        let worst = worstSafetyLevel(visible.map(\.safetyInfo.level))
        return SafetyInfo(
            level: worst,
            headline: "iOS Simulators",
            explanation: "Each entry is one simulator device folder. Expand the list to delete individual simulators safely.",
            recoverySteps: "",
            reinstallCommand: nil
        )
    }

    private func mergedStandardRowEntries() -> [MergedDevStandardRow] {
        let tools = sortedStandardToolIndices()
        var rows: [MergedDevStandardRow] = tools.map { .tool(index: $0) }
        guard simulatorSectionVisible else { return rows }
        rows.append(.simulators)

        func entrySize(_ e: MergedDevStandardRow) -> Int64 {
            switch e {
            case .tool(let i): return store.devTools[i].sizeBytes
            case .simulators: return simulatorSectionByteTotal()
            }
        }

        func entryDate(_ e: MergedDevStandardRow) -> Date {
            switch e {
            case .tool(let i): return devToolModified(store.devTools[i])
            case .simulators: return simulatorSectionModifiedDate()
            }
        }

        func entryName(_ e: MergedDevStandardRow) -> String {
            switch e {
            case .tool(let i): return store.devTools[i].toolName
            case .simulators: return "iOS Simulators"
            }
        }

        switch currentSort {
        case .sizeDesc:
            rows.sort { entrySize($0) > entrySize($1) }
        case .sizeAsc:
            rows.sort { entrySize($0) < entrySize($1) }
        case .dateNewest:
            rows.sort { entryDate($0) > entryDate($1) }
        case .dateOldest:
            rows.sort { entryDate($0) < entryDate($1) }
        case .nameAZ:
            rows.sort { entryName($0).localizedCaseInsensitiveCompare(entryName($1)) == .orderedAscending }
        }
        return rows
    }

    private func simulatorNonDangerVisibleIndices() -> [Int] {
        visibleSimulatorIndices().filter { store.simulatorDevices[$0].safetyInfo.level != .danger }
    }

    private func simulatorParentTriState() -> SelectAllTriState {
        let ix = simulatorNonDangerVisibleIndices()
        guard !ix.isEmpty else { return .none }
        let selected = ix.filter { store.simulatorDevices[$0].isSelected }.count
        if selected == 0 { return .none }
        if selected == ix.count { return .all }
        return .mixed
    }

    private func toggleSimulatorParentCheckbox() {
        let ix = simulatorNonDangerVisibleIndices()
        guard !ix.isEmpty else { return }
        let allOn = ix.allSatisfy { store.simulatorDevices[$0].isSelected }
        store.setSimulatorGroupNonDangerSelection(allSelected: !allOn)
    }

    private func eligibleSimulatorIndicesForToolbarSelectAll() -> [Int] {
        visibleSimulatorIndices().filter { store.simulatorDevices[$0].safetyInfo.level == .safe }
    }

    private func isEligibleForManualBulkSelection(_ info: SafetyInfo) -> Bool {
        true
    }

    private func eligibleArtifactIndices(forGroupIndex gi: Int) -> [Int] {
        let g = store.projectGroups[gi]
        return g.artifacts.indices.filter { ai in
            let art = g.artifacts[ai]
            guard artifactVisible(art.safetyInfo) else { return false }
            return isEligibleForManualBulkSelection(art.safetyInfo)
        }
    }

    private func projectSelectTriState(forGroupIndex gi: Int) -> SelectAllTriState {
        let eligible = eligibleArtifactIndices(forGroupIndex: gi)
        guard !eligible.isEmpty else { return .none }

        let g = store.projectGroups[gi]
        let selectedCount = eligible.filter { g.artifacts[$0].isSelected }.count
        if selectedCount == 0 { return .none }
        if selectedCount == eligible.count { return .all }
        return .mixed
    }

    private func toggleProjectEligibleSelection(groupIndex gi: Int) {
        let eligible = eligibleArtifactIndices(forGroupIndex: gi)
        guard !eligible.isEmpty else { return }
        let allOn = eligible.allSatisfy { store.projectGroups[gi].artifacts[$0].isSelected }
        let newVal = !allOn
        for ai in eligible {
            store.setProjectArtifactSelected(groupIndex: gi, artifactIndex: ai, isSelected: newVal)
        }
    }

    private func visibleGroupByteTotal(groupIndex gi: Int) -> Int64 {
        sortedVisibleArtifactIndices(forGroup: gi).reduce(Int64(0)) { sum, ai in
            sum + store.projectGroups[gi].artifacts[ai].sizeBytes
        }
    }

    private func sortedVisibleArtifactIndices(forGroup gi: Int) -> [Int] {
        let g = store.projectGroups[gi]
        let raw = g.artifacts.indices.filter {
            artifactVisible(g.artifacts[$0].safetyInfo)
                && !isVisuallyRemovedBySafeCleanup(g.artifacts[$0])
        }
        switch currentSort {
        case .sizeDesc:
            return raw.sorted { g.artifacts[$0].sizeBytes > g.artifacts[$1].sizeBytes }
        case .sizeAsc:
            return raw.sorted { g.artifacts[$0].sizeBytes < g.artifacts[$1].sizeBytes }
        case .dateNewest:
            return raw.sorted { g.artifacts[$0].lastModified > g.artifacts[$1].lastModified }
        case .dateOldest:
            return raw.sorted { g.artifacts[$0].lastModified < g.artifacts[$1].lastModified }
        case .nameAZ:
            return raw.sorted {
                g.artifacts[$0].safetyInfo.headline.localizedCaseInsensitiveCompare(g.artifacts[$1].safetyInfo.headline) == .orderedAscending
            }
        }
    }

    private func reinstallRollup(for tool: DevTool) -> ReinstallSafetyStatus {
        guard !tool.paths.isEmpty else { return .notApplicable }
        let values = tool.paths.map { ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: $0) }
        if values.contains(.missingLockfile) { return .missingLockfile }
        if values.allSatisfy({ $0 == .notApplicable }) { return .notApplicable }
        return .reinstallable
    }

    private func toolShowsUncommitted(_ tool: DevTool) -> Bool {
        tool.paths.contains { path in
            let key = path.standardizedFileURL.path
            return store.devToolRepoStatusByPath[key] == .dirty
        }
    }

    private func eligibleStandardToolIndices() -> [Int] {
        filteredStandardToolIndices().filter {
            isEligibleForManualBulkSelection(store.devTools[$0].safetyInfo)
        }
    }

    private func eligibleProjectArtifactPairs() -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for gi in filteredProjectGroupIndices() {
            for ai in store.projectGroups[gi].artifacts.indices {
                let art = store.projectGroups[gi].artifacts[ai]
                guard artifactVisible(art.safetyInfo) else { continue }
                guard !isVisuallyRemovedBySafeCleanup(art) else { continue }
                guard isEligibleForManualBulkSelection(art.safetyInfo) else { continue }
                pairs.append((gi, ai))
            }
        }
        return pairs
    }

    private var hasEligibleSelectableRows: Bool {
        !eligibleStandardToolIndices().isEmpty
            || !eligibleProjectArtifactPairs().isEmpty
            || !simulatorNonDangerVisibleIndices().isEmpty
    }

    private var selectAllDeveloperState: SelectAllTriState {
        let toolIx = eligibleStandardToolIndices()
        let pairs = eligibleProjectArtifactPairs()
        let simSafeIx = eligibleSimulatorIndicesForToolbarSelectAll()
        let total = toolIx.count + pairs.count + simSafeIx.count
        guard total > 0 else { return .none }

        var selected = 0
        for ti in toolIx where store.devTools[ti].isSelected { selected += 1 }
        for p in pairs where store.projectGroups[p.0].artifacts[p.1].isSelected { selected += 1 }
        for si in simSafeIx where store.simulatorDevices[si].isSelected { selected += 1 }

        if selected == 0 { return .none }
        if selected == total { return .all }
        return .mixed
    }

    private var selectedInScopeCount: Int {
        let toolIx = eligibleStandardToolIndices().filter { store.devTools[$0].isSelected }.count
        let pairSelected = eligibleProjectArtifactPairs().filter { store.projectGroups[$0.0].artifacts[$0.1].isSelected }.count
        let simSelected = visibleSimulatorIndices().filter { store.simulatorDevices[$0].isSelected }.count
        return toolIx + pairSelected + simSelected
    }

    private var selectedInScopeBytes: Int64 {
        let toolBytes = eligibleStandardToolIndices()
            .filter { store.devTools[$0].isSelected }
            .reduce(Int64(0)) { sum, index in sum + store.devTools[index].sizeBytes }
        let projectBytes = eligibleProjectArtifactPairs()
            .filter { store.projectGroups[$0.0].artifacts[$0.1].isSelected }
            .reduce(Int64(0)) { sum, pair in sum + store.projectGroups[pair.0].artifacts[pair.1].sizeBytes }
        let simulatorBytes = visibleSimulatorIndices()
            .filter { store.simulatorDevices[$0].isSelected }
            .reduce(Int64(0)) { sum, index in sum + (store.simulatorDevices[index].sizeOnDisk ?? 0) }
        return toolBytes + projectBytes + simulatorBytes
    }

    private func developerSafetySnapshotsForChipRow() -> [SafetyInfo] {
        let tools = isLoading ? displayedDevTools : store.devTools
        let groups = isLoading ? displayedProjectGroups : store.projectGroups
        let sims = isLoading ? displayedSimulatorDevices : store.simulatorDevices
        var infos: [SafetyInfo] = tools.filter(\.isDetected).map(\.safetyInfo)
        for group in groups {
            for art in group.artifacts {
                infos.append(art.safetyInfo)
            }
        }
        for sim in sims {
            infos.append(sim.safetyInfo)
        }
        return infos
    }

    private var chipCounts: [SafetyFilter: Int] {
        let infos = developerSafetySnapshotsForChipRow()
        var d: [SafetyFilter: Int] = [:]
        for filter in SafetyFilter.allCases {
            d[filter] = infos.filter { filter.matches($0) }.count
        }
        return d
    }

    private var developerListEmpty: Bool {
        if isLoading {
            return displayedDevTools.isEmpty
                && displayedProjectGroups.isEmpty
                && displayedSimulatorDevices.isEmpty
        }
        return store.projectGroups.isEmpty
            && store.devTools.isEmpty
            && store.simulatorDevices.isEmpty
    }

    private var skeletonRowCount: Int {
        let tools = displayedDevTools.filter(\.isDetected).count
        let artifacts = displayedProjectGroups.reduce(0) { $0 + $1.artifacts.count }
        let sims = displayedSimulatorDevices.count
        return SkeletonRowCount.clamped(tools + artifacts + sims)
    }

    private var showsDeveloperListContent: Bool {
        !isLoading && !developerListEmpty && !nothingMatchesFilter
    }

    private func isDevToolMetadataPending(_ tool: DevTool) -> Bool {
        guard store.isEnrichingDeveloper else { return false }
        return tool.paths.contains {
            store.devToolRepoStatusByPath[$0.standardizedFileURL.path] == nil
        }
    }

    private func isArtifactMetadataPending(_ artifact: ProjectCacheArtifact) -> Bool {
        store.isEnrichingDeveloper && artifact.gitStatus == .unknown
    }

    private func isSimulatorMetadataPending(_ device: SimulatorDevice) -> Bool {
        store.isEnrichingDeveloper && device.sizeOnDisk == nil
    }

    private var nothingMatchesFilter: Bool {
        mergedStandardRowEntries().isEmpty && filteredProjectGroupIndices().isEmpty
    }

    /// Row counts mirror the dev tools list + chip aggregates (detected tools + all project artifacts),
    /// excluding items tagged `.unknown` since they are hidden from display.
    private var developerTotalRowCount: Int {
        store.devTools.filter { $0.isDetected && $0.safetyInfo.level != .unknown }.count +
            store.simulatorDevices.filter { $0.safetyInfo.level != .unknown }.count +
            store.projectGroups.reduce(0) { sum, group in
                sum + group.artifacts.filter { $0.safetyInfo.level != .unknown }.count
            }
    }

    private var developerVisibleItemCount: Int {
        let tools = filteredStandardToolIndices().count
        let sims = visibleSimulatorIndices().count
        let artifacts = filteredProjectGroupIndices().reduce(0) { sum, gi in
            sum + sortedVisibleArtifactIndices(forGroup: gi).count
        }
        return tools + sims + artifacts
    }

    private var developerTotalByteSize: Int64 {
        let tools = store.devTools.filter { $0.isDetected && $0.safetyInfo.level != .unknown }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        let sims = store.simulatorDevices
            .filter { $0.safetyInfo.level != .unknown }
            .reduce(Int64(0)) { $0 + ($1.sizeOnDisk ?? 0) }
        let artifacts = store.projectGroups.reduce(Int64(0)) { sum, group in
            sum + group.artifacts.filter { $0.safetyInfo.level != .unknown }
                .reduce(Int64(0)) { $0 + $1.sizeBytes }
        }
        return tools + sims + artifacts
    }

    private var developerVisibleByteSize: Int64 {
        var sum = Int64(0)
        for entry in mergedStandardRowEntries() {
            switch entry {
            case .tool(let i):
                sum += store.devTools[i].sizeBytes
            case .simulators:
                sum += simulatorSectionByteTotal()
            }
        }
        for gi in filteredProjectGroupIndices() {
            let g = store.projectGroups[gi]
            for ai in g.artifacts.indices where artifactVisible(g.artifacts[ai].safetyInfo)
                && !isVisuallyRemovedBySafeCleanup(g.artifacts[ai]) {
                sum += g.artifacts[ai].sizeBytes
            }
        }
        return sum
    }

    private var subtitleItemCount: Int {
        currentSafetyFilter == .all ? developerTotalRowCount : developerVisibleItemCount
    }

    private var subtitleTotalSize: Int64 {
        currentSafetyFilter == .all ? developerTotalByteSize : developerVisibleByteSize
    }

    private var subtitleItemLabel: String {
        subtitleItemCount == 1 ? "item" : "items"
    }

    private var pageSubtitle: String {
        if isLoading {
            return "Scanning developer tool folders and project artifacts."
        }
        return "\(subtitleItemCount) \(subtitleItemLabel) · \(formatBytes(subtitleTotalSize)) recoverable"
    }

    var body: some View {
        VStack(spacing: 0) {
            AppSectionPageHeader(title: "Dev Tools", subtitle: pageSubtitle) {
                AppScanCleanActions(onScan: onScan)
            }

            FilterSortToolbar(
                safetyFilter: safetyFilterBinding,
                sortOption: sortOptionBinding,
                chipCounts: chipCounts,
                selectedInScopeCount: selectedInScopeCount,
                isDeleting: store.isDeleting,
                onCleanSelected: {
                    Task {
                        await store.presentDeletionSheetResolvingGit(
                            candidates: store.selectedDeveloperDeletionCandidates
                        )
                    }
                },
                useStackedLayout: true,
                showsControlsRow: false
            )
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
            .disabled(isLoading)

            HStack {
                TriStateCheckbox(title: "Select All", state: selectAllDeveloperState) {
                    toggleDeveloperSelectAll()
                }
                .fixedSize()
                .disabled(isLoading || !hasEligibleSelectableRows)
                Spacer()
                AppSortMenu(selection: sortOptionBinding)
            }
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
            .padding(.vertical, AppStyle.Spacing.xSmall)
            .disabled(isLoading)

            ZStack {
                ScanResultsListLoadingSurface(
                    isLoading: isLoading,
                    skeletonRowCount: skeletonRowCount
                ) {
                    if developerListEmpty {
                        placeholderNoData
                    } else if nothingMatchesFilter {
                        emptyFilterState
                    } else {
                        developerListOnly
                    }
                }

                if store.isDeleting && showsDeveloperListContent && !store.isInteractiveSafeCleanupInProgress {
                    CleaningOverlay()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScanStatusBar(
                isLoading: isLoading,
                visibleCount: developerVisibleItemCount,
                totalCount: developerTotalRowCount,
                isFiltered: currentSafetyFilter != .all,
                visibleBytes: developerVisibleByteSize,
                totalBytes: developerTotalByteSize,
                selectedCount: selectedInScopeCount,
                selectedBytes: selectedInScopeBytes
            )
        }
        .background(AppStyle.canvas)
        .onAppear {
            syncDisplayedDeveloperSnapshotIfIdle()
            guard !isLoading else { return }
            store.refreshDetectedDevToolSizes()
        }
        .onChange(of: isLoading) { scanning in
            if !scanning {
                syncDisplayedDeveloperSnapshotFromStore()
            }
        }
        .onChange(of: store.devTools) { _ in
            syncDisplayedDeveloperSnapshotIfIdle()
        }
        .onChange(of: store.projectGroups) { _ in
            syncDisplayedDeveloperSnapshotIfIdle()
        }
        .onChange(of: store.simulatorDevices) { _ in
            syncDisplayedDeveloperSnapshotIfIdle()
        }
    }

    private func syncDisplayedDeveloperSnapshotIfIdle() {
        guard !isLoading else { return }
        syncDisplayedDeveloperSnapshotFromStore()
    }

    private func syncDisplayedDeveloperSnapshotFromStore() {
        displayedDevTools = store.devTools
        displayedProjectGroups = store.projectGroups
        displayedSimulatorDevices = store.simulatorDevices
    }

    private var placeholderNoData: some View {
        VStack(spacing: 8) {
            Text("No dev tool folders surfaced yet.")
                .font(.headline)
            Text("Run a scan after adding projects or tool-generated folders.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var developerListOnly: some View {
        List {
            ForEach(mergedStandardRowEntries()) { entry in
                switch entry {
                case .tool(let index):
                    let tool = store.devTools[index]
                    let toolID = tool.id
                    let primaryPath = tool.primaryOverridePath
                    ScanResultRow(
                        isSelected: bindingForStandardTool(index),
                        primaryLabel: tool.safetyInfo.headline,
                        formattedSize: tool.formattedSize,
                        safetyInfo: tool.safetyInfo,
                        brandIcon: .devTool(tool),
                        onRequestUnknownDelete: tool.safetyInfo.level == .unknown
                            ? { store.requestUnknownDeletion(candidates: store.unknownDeletionCandidates(forDevTool: tool)) }
                            : nil,
                        detailCaption: nil,
                        reinstallSafety: reinstallRollup(for: tool),
                        showUncommittedRepoChanges: !isDevToolMetadataPending(tool) && toolShowsUncommitted(tool),
                        onRecategorize: primaryPath != nil ? { store.recategorizeDevTool(id: toolID) } : nil,
                        onMarkSafe: primaryPath != nil ? { store.markDevTool(id: toolID, as: .safe) } : nil,
                        onMarkMedium: primaryPath != nil ? { store.markDevTool(id: toolID, as: .medium) } : nil,
                        onMarkDanger: primaryPath != nil ? { store.markDevTool(id: toolID, as: .danger) } : nil,
                        onResetToAutomatic: primaryPath != nil ? { store.resetDevToolToAutomatic(id: toolID) } : nil,
                        isUserOverride: primaryPath.map { store.userOverridePaths.contains($0.standardizedFileURL.path) } ?? false,
                        isMetadataPending: isDevToolMetadataPending(tool)
                    )
                    .disabled(!tool.isDetected)
                    .opacity(tool.isDetected ? 1 : 0.45)
                    .listRowInsets(ScanListRowInsets.standard)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .transition(cleaningRowRemovalTransition)

                case .simulators:
                    iosSimulatorsHostRow
                        .listRowInsets(ScanListRowInsets.standard)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    if iosSimulatorsExpanded {
                        ForEach(sortedVisibleSimulatorIndices(), id: \.self) { si in
                            let device = store.simulatorDevices[si]
                            ScanResultRow(
                                isSelected: bindingForSimulator(id: device.id),
                                primaryLabel: device.safetyInfo.headline,
                                formattedSize: device.formattedSize,
                                safetyInfo: device.safetyInfo,
                                brandIcon: .sfSymbol("ipad.and.iphone"),
                                onRequestUnknownDelete: nil,
                                detailCaption: nil,
                                reinstallSafety: .notApplicable,
                                showUncommittedRepoChanges: false,
                                onRecategorize: nil,
                                onMarkSafe: nil,
                                onMarkMedium: nil,
                                onMarkDanger: nil,
                                onResetToAutomatic: nil,
                                isUserOverride: false,
                                allowsBulkSelection: !device.isDanger,
                                isMetadataPending: isSimulatorMetadataPending(device)
                            )
                            .padding(.leading, 24)
                            .listRowInsets(ScanListRowInsets.standard)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }

            if !sortedProjectGroupIndices().isEmpty {
                Section {
                    ForEach(sortedProjectGroupIndices().map(ProjectGroupRowKey.make)) { row in
                        let gi = row.groupIndex
                        let group = store.projectGroups[gi]
                        let isExpanded = expandedProjectRoots.contains(group.id)

                        projectGroupCard(for: group, groupIndex: gi, isExpanded: isExpanded)
                            .listRowInsets(ScanListRowInsets.standard)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .transition(cleaningRowRemovalTransition)
                    }
                } header: {
                    Text(projectSectionHeading)
                        .font(AppStyle.Typography.metadataEmphasis)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(AppStyle.canvas)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.interactiveSafeCleanupRemovedPaths)
    }

    private var cleaningRowRemovalTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .identity,
                removal: .opacity.combined(with: .move(edge: .trailing))
            )
    }

    private func isVisuallyRemovedBySafeCleanup(_ tool: DevTool) -> Bool {
        let rowPaths = Set(tool.paths.map { $0.standardizedFileURL.path })
        let targetedPaths = rowPaths.intersection(store.interactiveSafeCleanupTargetPaths)
        guard !targetedPaths.isEmpty else { return false }
        return targetedPaths.isSubset(of: store.interactiveSafeCleanupRemovedPaths)
    }

    private func isVisuallyRemovedBySafeCleanup(_ artifact: ProjectCacheArtifact) -> Bool {
        let path = artifact.path.standardizedFileURL.path
        return store.interactiveSafeCleanupTargetPaths.contains(path)
            && store.interactiveSafeCleanupRemovedPaths.contains(path)
    }

    private func bindingForSimulator(id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                store.simulatorDevices.first(where: { $0.id == id })?.isSelected ?? false
            },
            set: { newVal in
                store.setSimulatorDeviceSelected(id: id, isSelected: newVal)
            }
        )
    }

    private var iosSimulatorsHostRow: some View {
        let parentInfo = simulatorParentSafetyInfo()
        let sizeLabel = simulatorSectionHasPendingSizes
            ? "Calculating…"
            : formatBytes(simulatorSectionByteTotal())
        return HStack(alignment: .center, spacing: 6) {
            Button {
                withAnimation(.spring(duration: 0.2)) {
                    iosSimulatorsExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 44, alignment: .center)
                    .contentShape(Rectangle())
                    .rotationEffect(.degrees(iosSimulatorsExpanded ? 90 : 0))
                    .animation(.spring(duration: 0.2), value: iosSimulatorsExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(iosSimulatorsExpanded ? "Collapse iOS Simulators" : "Expand iOS Simulators")

            TriStateCheckbox(title: "", state: simulatorParentTriState()) {
                toggleSimulatorParentCheckbox()
            }
            .frame(width: 24)

            Circle()
                .fill(parentInfo.level == .safe ? AppStyle.safe : parentInfo.level == .danger ? AppStyle.danger : AppStyle.warning)
                .frame(width: 6, height: 6)

            Image(systemName: "ipad.and.iphone")
                .font(.system(size: AppStyle.Row.sfSymbolPointSize))
                .foregroundStyle(.secondary)
                .frame(width: AppStyle.Row.listIconFrameSize, height: AppStyle.Row.listIconFrameSize)

            VStack(alignment: .leading, spacing: 2) {
                Text("iOS Simulators")
                    .font(AppStyle.Typography.rowTitle)
                Text("Shutdown devices only — booted simulators stay hidden.")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(sizeLabel)
                .font(AppStyle.Typography.rowTitle)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, AppStyle.Spacing.xSmall)
        .frame(minHeight: AppStyle.Row.parentHeight)
        .background(AppStyle.elevated.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iOS Simulators")
    }

    private var projectSectionHeading: String {
        let kinds = Set(
            sortedProjectGroupIndices().flatMap { gi in
                sortedVisibleArtifactIndices(forGroup: gi).map { store.projectGroups[gi].artifacts[$0].kind }
            }
        )
        guard !kinds.isEmpty else { return "Developer Projects" }

        func heading(for kind: DeletableArtifactKind) -> String? {
            switch kind {
            case .nodeModules: return "Node.js Packages"
            case .dartTool, .flutterBuild: return "Flutter Projects"
            case .dotGradle: return "Android Projects"
            case .target: return "Rust Projects"
            case .venv, .pods: return nil
            }
        }

        let mapped = kinds.filter { heading(for: $0) != nil }
        let unmapped = kinds.filter { heading(for: $0) == nil }
        if !unmapped.isEmpty { return "Developer Projects" }

        let headings = Set(mapped.compactMap { heading(for: $0) })
        if headings.count == 1, let only = headings.first {
            return only
        }
        return "Developer Projects"
    }

    private func projectGroupCard(for group: ProjectGroup, groupIndex gi: Int, isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                TriStateCheckbox(title: "", state: projectSelectTriState(forGroupIndex: gi)) {
                    toggleProjectEligibleSelection(groupIndex: gi)
                }
                .frame(width: 24)

                Button {
                    toggleProjectExpanded(group.id)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        AdaptiveBrandIconImage(
                            source: .projectGroup(group),
                            squareSize: AppStyle.Row.projectGroupIconSize,
                            cornerRadius: AppStyle.Row.projectGroupIconCornerRadius
                        )
                        .accessibilityLabel(projectGroupIconAccessibilityLabel(for: group))
                        Text(group.displayName)
                            .font(AppStyle.Typography.rowTitle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(formatBytes(visibleGroupByteTotal(groupIndex: gi)))
                            .font(AppStyle.Typography.rowTitle)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                            .padding(.trailing, AppStyle.Spacing.xSmall)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse project" : "Expand project")
            }
            .padding(.vertical, 2)
            .padding(.horizontal, AppStyle.Spacing.xSmall)
            .frame(minHeight: AppStyle.Row.parentHeight)

            if isExpanded {
                projectArtifactRows(groupIndex: gi)
            }
        }
        .background(AppStyle.elevated.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project \(group.displayName)")
        .accessibilityHint("Grouped dev tool cleanup targets")
    }

    @ViewBuilder
    private func projectArtifactRows(groupIndex gi: Int) -> some View {
        ForEach(
            sortedVisibleArtifactIndices(forGroup: gi).map {
                ProjectArtifactRowKey.make(groupIndex: gi, artifactIndex: $0)
            }
        ) { artRow in
            projectArtifactRow(groupIndex: gi, artifactIndex: artRow.artifactIndex)
        }
    }

    @ViewBuilder
    private func projectArtifactRow(groupIndex gi: Int, artifactIndex ai: Int) -> some View {
        let art = store.projectGroups[gi].artifacts[ai]
        let artifactPath = art.path.standardizedFileURL.path
        let unknownHandler: (() -> Void)? = art.safetyInfo.level == .unknown
            ? { store.requestUnknownDeletion(candidates: store.unknownDeletionCandidates(forArtifact: art)) }
            : nil

        ScanResultRow(
            isSelected: bindingForArtifact(gi: gi, ai: ai),
            primaryLabel: art.safetyInfo.headline,
            formattedSize: art.formattedSize,
            safetyInfo: art.safetyInfo,
            brandIcon: nil,
            onRequestUnknownDelete: unknownHandler,
            detailCaption: nil,
            reinstallSafety: nil,
            showUncommittedRepoChanges: !isArtifactMetadataPending(art) && art.gitStatus == .dirty,
            onRecategorize: { store.recategorizeProjectArtifact(groupIndex: gi, artifactIndex: ai) },
            onMarkSafe: { store.markProjectArtifact(groupIndex: gi, artifactIndex: ai, as: .safe) },
            onMarkMedium: { store.markProjectArtifact(groupIndex: gi, artifactIndex: ai, as: .medium) },
            onMarkDanger: { store.markProjectArtifact(groupIndex: gi, artifactIndex: ai, as: .danger) },
            onResetToAutomatic: { store.resetProjectArtifactToAutomatic(groupIndex: gi, artifactIndex: ai) },
            isUserOverride: store.userOverridePaths.contains(artifactPath),
            showsBulkCheckbox: false,
            isMetadataPending: isArtifactMetadataPending(art),
            showsCardChrome: false,
            showsLeadingIcon: false
        )
        .padding(.trailing, AppStyle.Spacing.xSmall)
        .padding(.leading, AppStyle.Row.projectArtifactLeadingInset)
        .transition(cleaningRowRemovalTransition)
    }

    private func toggleProjectExpanded(_ groupID: String) {
        if expandedProjectRoots.contains(groupID) {
            expandedProjectRoots.remove(groupID)
        } else {
            expandedProjectRoots.insert(groupID)
        }
    }

    private func bindingForStandardTool(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { store.devTools[index].isSelected },
            set: { newVal in
                var tools = store.devTools
                tools[index].isSelected = newVal
                store.devTools = tools
            }
        )
    }

    private func bindingForArtifact(gi: Int, ai: Int) -> Binding<Bool> {
        Binding(
            get: { store.projectGroups[gi].artifacts[ai].isSelected },
            set: { newVal in
                store.setProjectArtifactSelected(groupIndex: gi, artifactIndex: ai, isSelected: newVal)
            }
        )
    }

    private func toggleDeveloperSelectAll() {
        let toolsIx = eligibleStandardToolIndices()
        let pairs = eligibleProjectArtifactPairs()
        let simSafeIx = eligibleSimulatorIndicesForToolbarSelectAll()
        guard !toolsIx.isEmpty || !pairs.isEmpty || !simSafeIx.isEmpty else { return }

        let allSimSafeSelected = simSafeIx.allSatisfy { store.simulatorDevices[$0].isSelected }
        let allOn =
            toolsIx.allSatisfy { store.devTools[$0].isSelected } &&
            pairs.allSatisfy { store.projectGroups[$0.0].artifacts[$0.1].isSelected } &&
            allSimSafeSelected

        let newVal = !allOn
        for ti in toolsIx {
            var tools = store.devTools
            tools[ti].isSelected = newVal
            store.devTools = tools
        }
        for p in pairs {
            store.setProjectArtifactSelected(groupIndex: p.0, artifactIndex: p.1, isSelected: newVal)
        }
        for si in simSafeIx {
            store.setSimulatorDeviceSelected(id: store.simulatorDevices[si].id, isSelected: newVal)
        }
        if newVal {
            for si in visibleSimulatorIndices() where store.simulatorDevices[si].safetyInfo.level != .safe {
                store.setSimulatorDeviceSelected(id: store.simulatorDevices[si].id, isSelected: false)
            }
        } else {
            for si in store.simulatorDevices.indices {
                store.setSimulatorDeviceSelected(id: store.simulatorDevices[si].id, isSelected: false)
            }
        }
    }

    private var devHeaderRow: some View {
        HStack {
            Text("Dev Tools")
                .font(.title3)
                .fontWeight(.bold)
            Spacer()
            Button(action: onScan) {
                Label("Scan", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppStyle.accent)
            .keyboardShortcut("r", modifiers: [.command])
        }
    }

    private var emptyFilterState: some View {
        VStack(spacing: 4) {
            Text("Nothing here.")
                .font(.headline)
            Text("No items match this filter.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func devToolModified(_ tool: DevTool) -> Date {
        tool.paths.compactMap { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max() ?? .distantPast
    }

    private func projectGroupIconAccessibilityLabel(for group: ProjectGroup) -> String {
        let types = group.inferredTypes.map(\.displayName).joined(separator: ", ")
        if types.isEmpty {
            return "Project"
        }
        return "Project, \(types)"
    }
}

#Preview("Dev Tools — scanning") {
    DevToolsView(isLoading: true, onScan: {})
        .environmentObject(PurgeStore())
        .frame(width: 720, height: 560)
}

#Preview("Dev Tools — loaded") {
    let store = PurgeStore()
    return DevToolsView(isLoading: false, onScan: {})
        .environmentObject(store)
        .frame(width: 720, height: 560)
}
