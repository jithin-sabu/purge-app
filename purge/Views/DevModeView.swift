import AppKit
import SwiftUI

struct DevToolsView<PageHeader: View>: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isLoading: Bool
    let scanPhase: PurgeStore.ScanPhase
    let onScan: () -> Void
    var showsPageHeader = true
    /// When true, the parent supplies the page header and the list uses `safeAreaBar` scroll-edge blur (macOS 26+).
    var usesExternalScrollContainer = false
    private let pageHeader: () -> PageHeader

    init(
        isLoading: Bool,
        scanPhase: PurgeStore.ScanPhase,
        onScan: @escaping () -> Void,
        showsPageHeader: Bool = true,
        usesExternalScrollContainer: Bool = false,
        @ViewBuilder pageHeader: @escaping () -> PageHeader
    ) {
        self.isLoading = isLoading
        self.scanPhase = scanPhase
        self.onScan = onScan
        self.showsPageHeader = showsPageHeader
        self.usesExternalScrollContainer = usesExternalScrollContainer
        self.pageHeader = pageHeader
    }

    @State private var expandedProjectRoots = Set<String>()

    /// Stable list IDs so sibling `ForEach` loops in the same `List` never share
    /// bare `Int` identities (which can duplicate or swap rows on expand/collapse).
    private struct ProjectGroupRowKey: Hashable, Identifiable {
        let id: String
        let groupIndex: Int
        static func make(group: ProjectGroup, groupIndex: Int) -> ProjectGroupRowKey {
            ProjectGroupRowKey(id: "project-group-\(group.id)", groupIndex: groupIndex)
        }
    }

    private struct ProjectArtifactRowKey: Hashable, Identifiable {
        let id: String
        let groupIndex: Int
        let artifactIndex: Int
        let groupID: String
        let artifactID: String
        static func make(group: ProjectGroup, groupIndex: Int, artifactIndex: Int) -> ProjectArtifactRowKey {
            let artifact = group.artifacts[artifactIndex]
            return ProjectArtifactRowKey(
                id: "project-\(group.id)-artifact-\(artifact.id)",
                groupIndex: groupIndex,
                artifactIndex: artifactIndex,
                groupID: group.id,
                artifactID: artifact.id
            )
        }
    }

    private enum MergedDevStandardRow: Hashable, Identifiable {
        case tool(id: String, index: Int)

        var id: String {
            switch self {
            case .tool(let id, _): return "merged-tool-\(id)"
            }
        }
    }

    @AppStorage("filter.devTools") private var filterRaw: String = SafetyFilter.safe.rawValue
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

    private func mergedStandardRowEntries() -> [MergedDevStandardRow] {
        let tools = sortedStandardToolIndices()
        var rows: [MergedDevStandardRow] = tools.map { .tool(id: store.devTools[$0].id, index: $0) }

        func entrySize(_ e: MergedDevStandardRow) -> Int64 {
            switch e {
            case .tool(_, let i): return store.devTools[i].sizeBytes
            }
        }

        func entryDate(_ e: MergedDevStandardRow) -> Date {
            switch e {
            case .tool(_, let i): return devToolModified(store.devTools[i])
            }
        }

        func entryName(_ e: MergedDevStandardRow) -> String {
            switch e {
            case .tool(_, let i): return store.devTools[i].toolName
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
            || !visibleSimulatorIndices().isEmpty
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
        var infos: [SafetyInfo] = store.devTools.filter(\.isDetected).map(\.safetyInfo)
        for group in store.projectGroups {
            for art in group.artifacts {
                infos.append(art.safetyInfo)
            }
        }
        for sim in store.simulatorDevices {
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
        return store.projectGroups.isEmpty
            && store.devTools.isEmpty
            && store.simulatorDevices.isEmpty
    }

    private var showsDeveloperListContent: Bool {
        !developerListEmpty && !nothingMatchesFilter
    }

    private func isDevToolMetadataPending(_ tool: DevTool) -> Bool {
        if store.pendingDevToolSizeIDs.contains(tool.id) { return true }
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
        mergedStandardRowEntries().isEmpty
            && !simulatorSectionVisible
            && filteredProjectGroupIndices().isEmpty
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
            case .tool(_, let i):
                sum += store.devTools[i].sizeBytes
            }
        }
        if simulatorSectionVisible {
            sum += simulatorSectionByteTotal()
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
        return "\(subtitleItemCount) \(subtitleItemLabel) · \(formatBytes(subtitleTotalSize)) recoverable"
    }

    var body: some View {
        Group {
            if usesExternalScrollContainer {
                externalScrollBody
            } else {
                standardBody
            }
        }
        .background(AppColors.bgBase)
    }

    private var standardBody: some View {
        VStack(spacing: 0) {
            if showsPageHeader {
                AppSectionPageHeader(title: "Dev Tools", subtitle: pageSubtitle) {
                    AppScanCleanActions(onScan: onScan, scanPhase: scanPhase)
                }
            }

            scanControlsChrome
            scanListStack
        }
    }

    @ViewBuilder
    private var externalScrollBody: some View {
        if #available(macOS 26.0, *) {
            VStack(spacing: 0) {
                fixedScanTabHeader

                if showsDeveloperListContent {
                    ZStack {
                        developerListOnly
                            .scanTabSoftScrollEdge { selectAllRowChrome }

                        if store.isDeleting && !store.isInteractiveSafeCleanupInProgress && store.manualDeletionSession == nil {
                            CleaningOverlay()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        selectAllRowChrome
                        scanListStack
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        } else {
            standardBody
        }
    }

    /// Filter chips — fixed above the scroll edge; page title lives in the parent column header.
    private var fixedScanTabHeader: some View {
        filterToolbarChrome
    }

    private var filterToolbarChrome: some View {
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
    }

    /// Bottom edge of the blur zone — list rows fade under this row only.
    private var selectAllRowChrome: some View {
        HStack(alignment: .bottom) {
            TriStateCheckbox(title: "Select All", state: selectAllDeveloperState) {
                toggleDeveloperSelectAll()
            }
            .fixedSize()
            .disabled(!hasEligibleSelectableRows)
            Spacer()
            AppSortMenu(selection: sortOptionBinding)
        }
        .scanTabSelectAllRowLayout()
    }

    private var scanControlsChrome: some View {
        VStack(spacing: 0) {
            filterToolbarChrome
            selectAllRowChrome
        }
    }

    private var scanListStack: some View {
        ZStack {
            scanListOrPlaceholder

            if store.isDeleting && showsDeveloperListContent && !store.isInteractiveSafeCleanupInProgress
                && store.manualDeletionSession == nil {
                CleaningOverlay()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var scanListOrPlaceholder: some View {
        if developerListEmpty {
            if isLoading {
                scanningPlaceholder
            } else {
                placeholderNoData
            }
        } else if nothingMatchesFilter {
            if isLoading {
                scanningPlaceholder
            } else {
                emptyFilterState
            }
        } else {
            developerListOnly
        }
    }

    private var placeholderNoData: some View {
        VStack(spacing: 8) {
            Text("No dev tool folders surfaced yet.")
                .font(.headline)
            Text(scanPhase == .completed ? "Your Mac is looking clean. Check back later." : "Run a scan after adding projects or tool-generated folders.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Scanning developer folders")
    }

    /// Stable anchor pinned to the very top of the results list so a fresh scan or
    /// first appearance can reset scroll position to the first row.
    private static var topAnchorID: String { "dev-tools-top" }

    private var developerListOnly: some View {
        ScrollViewReader { proxy in
            developerListContent
                .onChange(of: scanPhase) { newPhase in
                    // A new scan just finished populating the list.
                    guard newPhase == .completed else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
        }
    }

    private var developerListContent: some View {
        List {
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .id(Self.topAnchorID)

            ForEach(mergedStandardRowEntries()) { entry in
                switch entry {
                case .tool(let entryID, let index):
                    if store.devTools.indices.contains(index), store.devTools[index].id == entryID {
                    let tool = store.devTools[index]
                    let toolID = tool.id
                    let primaryPath = tool.primaryOverridePath
                    ScanResultRow(
                        isSelected: bindingForStandardTool(id: toolID),
                        primaryLabel: tool.safetyInfo.headline,
                        formattedSize: tool.formattedSize,
                        safetyInfo: tool.safetyInfo,
                        brandIcon: .devTool(tool),
                        detailCaption: nil,
                        reinstallSafety: tool.reinstallSafety,
                        showUncommittedRepoChanges: !isDevToolMetadataPending(tool) && toolShowsUncommitted(tool),
                        onResetToAutomatic: primaryPath != nil ? { store.resetDevToolToAutomatic(id: toolID) } : nil,
                        isUserOverride: primaryPath.map { store.userOverridePaths.contains($0.standardizedFileURL.path) } ?? false,
                        isMetadataPending: isDevToolMetadataPending(tool)
                    )
                    .disabled(!tool.isDetected)
                    .opacity(tool.isDetected ? 1 : 0.45)
                    .listRowInsets(ScanListRowInsets.standard)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .transition(rowInsertionTransition)
                    }
                }
            }

            if simulatorSectionVisible {
                Section {
                    iosSimulatorsSectionHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    ForEach(sortedVisibleSimulatorIndices().map { store.simulatorDevices[$0].id }, id: \.self) { deviceID in
                        if let device = store.simulatorDevices.first(where: { $0.id == deviceID }) {
                            ScanResultRow(
                                isSelected: bindingForSimulator(id: device.id),
                                primaryLabel: device.safetyInfo.headline,
                                formattedSize: device.formattedSize,
                                safetyInfo: device.safetyInfo,
                                brandIcon: .sfSymbol("ipad.and.iphone"),
                                detailCaption: nil,
                                reinstallSafety: .notApplicable,
                                showUncommittedRepoChanges: false,
                                onResetToAutomatic: nil,
                                isUserOverride: false,
                                allowsBulkSelection: true,
                                isMetadataPending: isSimulatorMetadataPending(device),
                                usesCompactExplanation: true
                            )
                            .listRowInsets(ScanListRowInsets.standard)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .transition(rowInsertionTransition)
                        }
                    }
                }
            }

            if !sortedProjectGroupIndices().isEmpty {
                Section {
                    developerProjectsSectionHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    ForEach(sortedProjectGroupIndices().map { ProjectGroupRowKey.make(group: store.projectGroups[$0], groupIndex: $0) }) { row in
                        let gi = row.groupIndex
                        if store.projectGroups.indices.contains(gi), row.id == "project-group-\(store.projectGroups[gi].id)" {
                            let group = store.projectGroups[gi]
                            let isExpanded = expandedProjectRoots.contains(group.id)

                            projectGroupCard(for: group, groupIndex: gi, isExpanded: isExpanded)
                                .listRowInsets(ScanListRowInsets.standard)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .transition(rowInsertionTransition)
                        }
                    }
                }
            } else if store.isScanningProjects {
                Section {
                    developerProjectsSectionHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    Text("Finding projects…")
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .listRowInsets(ScanListRowInsets.standard)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            ScanListBottomSpacer()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.bgBase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.interactiveSafeCleanupRemovedPaths)
        .animation(rowInsertionAnimation, value: developerTotalRowCount)
        .animation(expandCollapseAnimation, value: expandedProjectRoots)
    }

    private var rowInsertionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.08)
    }

    private var rowInsertionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .scanRowInsertion,
                removal: cleaningRowRemovalTransition
            )
    }

    private var expandCollapseAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.08)
    }

    private var expandCollapseTransition: AnyTransition {
        .opacity
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

    private var developerProjectsSectionHeader: some View {
        devToolsSectionHeader {
            Text("Developer Projects")
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(.secondary)
        }
    }

    private var iosSimulatorsSectionHeader: some View {
        devToolsSectionHeader {
            VStack(alignment: .leading, spacing: 2) {
                Text("iOS Simulators")
                    .font(AppStyle.Typography.metadataEmphasis)
                    .foregroundStyle(.secondary)
                Text("Shutdown devices only — booted simulators stay hidden.")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func devToolsSectionHeader<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, AppStyle.Spacing.medium)
            .padding(.horizontal, AppStyle.Spacing.small)
    }

    @ViewBuilder
    private func projectGroupCard(for group: ProjectGroup, groupIndex _: Int, isExpanded: Bool) -> some View {
        if let currentGroupIndex = store.projectGroups.firstIndex(where: { $0.id == group.id }) {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                TriStateCheckbox(title: "", state: projectSelectTriState(forGroupIndex: currentGroupIndex)) {
                    toggleProjectEligibleSelection(groupIndex: currentGroupIndex)
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
                        Text(formatBytes(visibleGroupByteTotal(groupIndex: currentGroupIndex)))
                            .font(AppStyle.Typography.rowTitle)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        ZStack {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0), anchor: .center)
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
                projectArtifactRows(groupIndex: currentGroupIndex)
                    .transition(expandCollapseTransition)
            }
        }
        .padding(.bottom, isExpanded ? AppStyle.Spacing.xSmall : 0)
        .devToolsGroupCardChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project \(group.displayName)")
        .accessibilityHint("Grouped dev tool cleanup targets")
        }
    }

    @ViewBuilder
    private func projectArtifactRows(groupIndex gi: Int) -> some View {
        if store.projectGroups.indices.contains(gi) {
            let group = store.projectGroups[gi]
            ForEach(
                sortedVisibleArtifactIndices(forGroup: gi).map {
                    ProjectArtifactRowKey.make(group: group, groupIndex: gi, artifactIndex: $0)
                }
            ) { artRow in
                projectArtifactRow(
                    groupIndex: artRow.groupIndex,
                    artifactIndex: artRow.artifactIndex,
                    groupID: artRow.groupID,
                    artifactID: artRow.artifactID
                )
            }
        }
    }

    @ViewBuilder
    private func projectArtifactRow(groupIndex gi: Int, artifactIndex ai: Int, groupID: String, artifactID: String) -> some View {
        if store.projectGroups.indices.contains(gi),
           store.projectGroups[gi].id == groupID,
           store.projectGroups[gi].artifacts.indices.contains(ai),
           store.projectGroups[gi].artifacts[ai].id == artifactID {
            let art = store.projectGroups[gi].artifacts[ai]
            let artifactPath = art.path.standardizedFileURL.path

            ScanResultRow(
                isSelected: bindingForArtifact(groupID: groupID, artifactID: artifactID),
                primaryLabel: art.safetyInfo.headline,
                formattedSize: art.formattedSize,
                safetyInfo: art.safetyInfo,
                brandIcon: nil,
                detailCaption: nil,
                reinstallSafety: nil,
                showUncommittedRepoChanges: !isArtifactMetadataPending(art) && art.gitStatus == .dirty,
                onResetToAutomatic: { store.resetProjectArtifactToAutomatic(groupID: groupID, artifactID: artifactID) },
                isUserOverride: store.userOverridePaths.contains(artifactPath),
                showsBulkCheckbox: false,
                isMetadataPending: isArtifactMetadataPending(art) || store.projectArtifactHasPendingSize(art),
                showsCardChrome: false,
                showsLeadingIcon: false
            )
            .padding(.trailing, AppStyle.Spacing.xSmall)
            .padding(.leading, AppStyle.Row.projectArtifactLeadingInset)
            .transition(cleaningRowRemovalTransition)
        }
    }

    private func toggleProjectExpanded(_ groupID: String) {
        withAnimation(expandCollapseAnimation) {
            if expandedProjectRoots.contains(groupID) {
                expandedProjectRoots.remove(groupID)
            } else {
                expandedProjectRoots.insert(groupID)
            }
        }
    }

    private func bindingForStandardTool(id: String) -> Binding<Bool> {
        Binding(
            get: { store.devTools.first(where: { $0.id == id })?.isSelected ?? false },
            set: { newVal in store.setDevToolSelected(id: id, isSelected: newVal) }
        )
    }

    private func bindingForArtifact(groupID: String, artifactID: String) -> Binding<Bool> {
        Binding(
            get: {
                store.projectGroups
                    .first(where: { $0.id == groupID })?
                    .artifacts
                    .first(where: { $0.id == artifactID })?
                    .isSelected ?? false
            },
            set: { newVal in store.setProjectArtifactSelected(groupID: groupID, artifactID: artifactID, isSelected: newVal) }
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
        var tools = store.devTools
        for ti in toolsIx {
            tools[ti].isSelected = newVal
        }
        store.devTools = tools
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
        tool.lastModified
    }

    private func projectGroupIconAccessibilityLabel(for group: ProjectGroup) -> String {
        let types = group.inferredTypes.map(\.displayName).joined(separator: ", ")
        if types.isEmpty {
            return "Project"
        }
        return "Project, \(types)"
    }
}

private extension View {
    func devToolsGroupCardChrome() -> some View {
        modifier(ScanRowCardChrome())
    }
}

extension DevToolsView where PageHeader == EmptyView {
    init(
        isLoading: Bool,
        scanPhase: PurgeStore.ScanPhase,
        onScan: @escaping () -> Void,
        showsPageHeader: Bool = true,
        usesExternalScrollContainer: Bool = false
    ) {
        self.init(
            isLoading: isLoading,
            scanPhase: scanPhase,
            onScan: onScan,
            showsPageHeader: showsPageHeader,
            usesExternalScrollContainer: usesExternalScrollContainer,
            pageHeader: { EmptyView() }
        )
    }
}

#Preview("Dev Tools — scanning") {
    DevToolsView(
        isLoading: true,
        scanPhase: .scanning,
        onScan: {}
    )
        .environmentObject(PurgeStore())
        .frame(width: 720, height: 560)
}

#Preview("Dev Tools — loaded") {
    let store = PurgeStore()
    return DevToolsView(
        isLoading: false,
        scanPhase: .idle,
        onScan: {}
    )
        .environmentObject(store)
        .frame(width: 720, height: 560)
}
