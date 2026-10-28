import AppKit
import SwiftUI

struct DevToolsView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isLoading: Bool
    let scanPhase: PurgeStore.ScanPhase
    /// When true, the parent supplies the page header and this view renders only its
    /// controls and scrolling list.
    var usesExternalScrollContainer = false

    init(
        isLoading: Bool,
        scanPhase: PurgeStore.ScanPhase,
        usesExternalScrollContainer: Bool = false
    ) {
        self.isLoading = isLoading
        self.scanPhase = scanPhase
        self.usesExternalScrollContainer = usesExternalScrollContainer
    }

    @State private var expandedProjectRoots = Set<String>()

    /// Stable list IDs so sibling `ForEach` loops in the same `List` never share
    /// bare `Int` identities (which can duplicate or swap rows on expand/collapse).
    private struct ProjectGroupRowKey: Hashable, Identifiable {
        let id: String
        let groupIndex: Int
        /// A group from the last scan (#283); `groupIndex` then points into the
        /// saved rows. Same id as the live group, so it turns live in place.
        var isFromLastScan = false
        static func make(group: ProjectGroup, groupIndex: Int, isFromLastScan: Bool = false) -> ProjectGroupRowKey {
            ProjectGroupRowKey(id: "project-group-\(group.id)", groupIndex: groupIndex, isFromLastScan: isFromLastScan)
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
        /// A tool from the last scan (#283), indexing the saved rows. Shares the live
        /// row's id, so it turns live in place.
        case savedTool(id: String, index: Int)

        var id: String {
            switch self {
            case .tool(let id, _), .savedTool(let id, _): return "merged-tool-\(id)"
            }
        }
    }

    @AppStorage("filter.devTools") private var filterRaw: String = SafetyFilter.safe.rawValue
    @AppStorage("sort.devTools") private var sortRaw: String = SortOption.sizeDesc.rawValue

    /// Safe while the Overview has this tab open for a visit, the saved filter otherwise.
    private var currentSafetyFilter: SafetyFilter {
        store.safetyFilter(for: .devTools, saved: SafetyFilter(rawValue: filterRaw) ?? .all)
    }

    /// Picking a filter saves it and ends an Overview visit's Safe.
    private var safetyFilterBinding: Binding<SafetyFilter> {
        Binding(
            get: { currentSafetyFilter },
            set: {
                filterRaw = $0.rawValue
                store.endSafetyFilterVisit()
            }
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

    /// Each pass reads the filter once and hands it down. `currentSafetyFilter`
    /// goes through `@AppStorage`, and reading it per row made every Dev Tools
    /// render read it thousands of times (#190).
    private func groupHasVisibleArtifacts(_ group: ProjectGroup, filter: SafetyFilter) -> Bool {
        group.artifacts.contains {
            filter.matches($0.safetyInfo) && !store.isVisuallyRemovedBySafeCleanup($0)
        }
    }

    private func filteredProjectGroupIndices() -> [Int] {
        let filter = currentSafetyFilter
        return store.projectGroups.indices.filter { groupHasVisibleArtifacts(store.projectGroups[$0], filter: filter) }
    }

    /// Live project groups and the last scan's (#283) in one sorted list.
    private func sortedProjectGroupRows() -> [ProjectGroupRowKey] {
        let filter = currentSafetyFilter
        let groups = store.projectGroups
        let saved = lastScanProjectGroups
        var rows = filteredProjectGroupIndices().map { ProjectGroupRowKey.make(group: groups[$0], groupIndex: $0) }
        for index in saved.indices where saved[index].artifacts.contains(where: { filter.matches($0.safetyInfo) }) {
            rows.append(.make(group: saved[index], groupIndex: index, isFromLastScan: true))
        }
        let group: (ProjectGroupRowKey) -> ProjectGroup = { $0.isFromLastScan ? saved[$0.groupIndex] : groups[$0.groupIndex] }
        switch currentSort {
        case .sizeDesc:
            return rows.sorted { group($0).totalBytes > group($1).totalBytes }
        case .sizeAsc:
            return rows.sorted { group($0).totalBytes < group($1).totalBytes }
        case .dateNewest:
            return rows.sorted { groupModified(group($0)) > groupModified(group($1)) }
        case .dateOldest:
            return rows.sorted { groupModified(group($0)) < groupModified(group($1)) }
        case .nameAZ:
            return rows.sorted {
                group($0).displayName.localizedCaseInsensitiveCompare(group($1).displayName) == .orderedAscending
            }
        }
    }

    // MARK: Rows from the last scan (#283)

    /// Saved rows the live lists don't have yet. Read only: nothing here feeds
    /// Select All, the selected count or Clean, which read the live lists.
    private var lastScanTools: [DevTool] {
        let saved = store.lastScanRows.devTools
        guard !saved.isEmpty else { return [] }
        let live = Set(store.devTools.map(\.id))
        return saved.filter { $0.isDetected && !live.contains($0.id) }
    }

    private var lastScanSimulators: [SimulatorDevice] {
        let saved = store.lastScanRows.simulatorDevices
        guard !saved.isEmpty else { return [] }
        let live = Set(store.simulatorDevices.map(\.id)).union(store.runningSimulatorDevices.map(\.id))
        return saved.filter { !live.contains($0.id) }
    }

    private var lastScanRuntimes: [SimulatorRuntime] {
        let saved = store.lastScanRows.simulatorRuntimes
        guard !saved.isEmpty else { return [] }
        let live = Set(store.simulatorRuntimes.map(\.id))
        return saved.filter { !live.contains($0.id) }
    }

    private var lastScanProjectGroups: [ProjectGroup] {
        let saved = store.lastScanRows.projectGroups
        guard !saved.isEmpty else { return [] }
        let live = Set(store.projectGroups.map(\.id))
        return saved.filter { !live.contains($0.id) }
    }

    private var hasLastScanRows: Bool {
        !store.lastScanRows.devTools.isEmpty
            || !store.lastScanRows.simulatorDevices.isEmpty
            || !store.lastScanRows.simulatorRuntimes.isEmpty
            || !store.lastScanRows.projectGroups.isEmpty
    }

    private func groupModified(_ group: ProjectGroup) -> Date {
        group.artifacts.map(\.lastModified).max() ?? .distantPast
    }

    private func standardToolIndices() -> [Int] {
        Array(store.devTools.indices)
    }

    private func standardToolVisible(_ index: Int, filter: SafetyFilter) -> Bool {
        guard store.devTools[index].isDetected else { return false }
        return filter.matches(store.devTools[index].safetyInfo)
            && !store.isVisuallyRemovedBySafeCleanup(store.devTools[index])
    }

    private func filteredStandardToolIndices() -> [Int] {
        let filter = currentSafetyFilter
        return standardToolIndices().filter { standardToolVisible($0, filter: filter) }
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
                tools[$0].safetyInfo.headline.localizedCaseInsensitiveCompare(tools[$1].safetyInfo.headline) == .orderedAscending
            }
        }
    }

    private var simulatorSectionVisible: Bool {
        let filter = currentSafetyFilter
        return store.simulatorDevices.contains { filter.matches($0.safetyInfo) }
            || !visibleRunningSimulators.isEmpty
            || lastScanSimulators.contains { filter.matches($0.safetyInfo) }
    }

    /// Live and saved simulators by id, in the list's order.
    private func sortedSimulatorRowIDs() -> [UUID] {
        let filter = currentSafetyFilter
        let list = store.simulatorDevices.filter { filter.matches($0.safetyInfo) }
            + lastScanSimulators.filter { filter.matches($0.safetyInfo) }
        let sorted: [SimulatorDevice]
        switch currentSort {
        case .sizeDesc:
            sorted = list.sorted { ($0.sizeOnDisk ?? 0) > ($1.sizeOnDisk ?? 0) }
        case .sizeAsc:
            sorted = list.sorted { ($0.sizeOnDisk ?? 0) < ($1.sizeOnDisk ?? 0) }
        case .dateNewest:
            sorted = list.sorted { ($0.lastBootedAt ?? .distantPast) > ($1.lastBootedAt ?? .distantPast) }
        case .dateOldest:
            sorted = list.sorted { ($0.lastBootedAt ?? .distantPast) < ($1.lastBootedAt ?? .distantPast) }
        case .nameAZ:
            sorted = list.sorted { $0.safetyInfo.headline.localizedCaseInsensitiveCompare($1.safetyInfo.headline) == .orderedAscending }
        }
        return sorted.map(\.id)
    }

    /// Booted simulators, shown under the ones that can be removed.
    private var visibleRunningSimulators: [SimulatorDevice] {
        let filter = currentSafetyFilter
        return store.runningSimulatorDevices.filter { filter.matches($0.safetyInfo) }
    }

    private func visibleSimulatorIndices() -> [Int] {
        let filter = currentSafetyFilter
        return store.simulatorDevices.indices.filter { filter.matches(store.simulatorDevices[$0].safetyInfo) }
    }

    private var runtimeSectionVisible: Bool {
        let filter = currentSafetyFilter
        return store.simulatorRuntimes.contains { filter.matches($0.safetyInfo) }
            || lastScanRuntimes.contains { filter.matches($0.safetyInfo) }
    }

    /// Live and saved runtimes by id, in the list's order.
    private func sortedRuntimeRowIDs() -> [String] {
        let filter = currentSafetyFilter
        let list = store.simulatorRuntimes.filter { filter.matches($0.safetyInfo) }
            + lastScanRuntimes.filter { filter.matches($0.safetyInfo) }
        let sorted: [SimulatorRuntime]
        switch currentSort {
        case .sizeDesc:
            sorted = list.sorted { $0.sizeBytes > $1.sizeBytes }
        case .sizeAsc:
            sorted = list.sorted { $0.sizeBytes < $1.sizeBytes }
        case .dateNewest:
            sorted = list.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        case .dateOldest:
            sorted = list.sorted { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
        case .nameAZ:
            sorted = list.sorted { $0.safetyInfo.headline.localizedCaseInsensitiveCompare($1.safetyInfo.headline) == .orderedAscending }
        }
        return sorted.map(\.id)
    }

    private func visibleRuntimeIndices() -> [Int] {
        let filter = currentSafetyFilter
        return store.simulatorRuntimes.indices.filter { filter.matches(store.simulatorRuntimes[$0].safetyInfo) }
    }

    private func mergedStandardRowEntries() -> [MergedDevStandardRow] {
        let tools = sortedStandardToolIndices()
        var rows: [MergedDevStandardRow] = tools.map { .tool(id: store.devTools[$0].id, index: $0) }
        let filter = currentSafetyFilter
        let saved = store.lastScanRows.devTools
        let liveIDs = Set(store.devTools.map(\.id))
        for index in saved.indices where saved[index].isDetected && !liveIDs.contains(saved[index].id)
            && filter.matches(saved[index].safetyInfo) {
            rows.append(.savedTool(id: saved[index].id, index: index))
        }

        func tool(_ e: MergedDevStandardRow) -> DevTool {
            switch e {
            case .tool(_, let i): return store.devTools[i]
            case .savedTool(_, let i): return saved[i]
            }
        }

        func entrySize(_ e: MergedDevStandardRow) -> Int64 {
            tool(e).sizeBytes
        }

        func entryDate(_ e: MergedDevStandardRow) -> Date {
            devToolModified(tool(e))
        }

        func entryName(_ e: MergedDevStandardRow) -> String {
            tool(e).safetyInfo.headline
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

    /// Resolves a group by identity rather than by position.
    ///
    /// The row helpers below are read from closures that SwiftUI re-invokes on its own
    /// schedule — `ScanSelectionScope` exists precisely so a selection change re-renders
    /// the checkbox without rebuilding the whole list. A rescan replaces `projectGroups`
    /// wholesale, so a position captured when the row was first built can point past the
    /// end of the new array by the time such a closure runs. Identity survives that;
    /// a position does not.
    private func projectGroupIndex(forID id: String) -> Int? {
        store.projectGroups.firstIndex { $0.id == id }
    }

    private func eligibleArtifactIndices(forGroupID id: String) -> [Int] {
        guard let gi = projectGroupIndex(forID: id) else { return [] }
        return eligibleArtifactIndices(forGroupIndex: gi)
    }

    private func projectSelectTriState(forGroupID id: String) -> SelectAllTriState {
        guard let gi = projectGroupIndex(forID: id) else { return .none }
        return projectSelectTriState(forGroupIndex: gi)
    }

    private func toggleProjectEligibleSelection(groupID id: String) {
        guard let gi = projectGroupIndex(forID: id) else { return }
        toggleProjectEligibleSelection(groupIndex: gi)
    }

    private func visibleGroupByteTotal(groupID id: String) -> Int64 {
        guard let gi = projectGroupIndex(forID: id) else { return 0 }
        return visibleGroupByteTotal(groupIndex: gi)
    }

    private func eligibleArtifactIndices(forGroupIndex gi: Int) -> [Int] {
        // Defence in depth: the id-addressed entry points above are the supported route,
        // but a stale index must degrade to an empty result rather than trap.
        guard store.projectGroups.indices.contains(gi) else { return [] }
        let g = store.projectGroups[gi]
        let filter = currentSafetyFilter
        return g.artifacts.indices.filter { filter.matches(g.artifacts[$0].safetyInfo) }
    }

    private func projectSelectTriState(forGroupIndex gi: Int) -> SelectAllTriState {
        let eligible = eligibleArtifactIndices(forGroupIndex: gi)
        guard !eligible.isEmpty, store.projectGroups.indices.contains(gi) else { return .none }

        let g = store.projectGroups[gi]
        let selectedIDs = store.scanSelection.artifactIDs
        let selectedCount = eligible.filter { selectedIDs.contains(g.artifacts[$0].id) }.count
        if selectedCount == 0 { return .none }
        if selectedCount == eligible.count { return .all }
        return .mixed
    }

    private func toggleProjectEligibleSelection(groupIndex gi: Int) {
        let eligible = eligibleArtifactIndices(forGroupIndex: gi)
        guard !eligible.isEmpty, store.projectGroups.indices.contains(gi) else { return }
        let group = store.projectGroups[gi]
        let selectedIDs = store.scanSelection.artifactIDs
        let allOn = eligible.allSatisfy { selectedIDs.contains(group.artifacts[$0].id) }
        let newVal = !allOn
        for ai in eligible {
            store.setProjectArtifactSelected(groupIndex: gi, artifactIndex: ai, isSelected: newVal)
        }
    }

    private func visibleGroupByteTotal(groupIndex gi: Int) -> Int64 {
        guard store.projectGroups.indices.contains(gi) else { return 0 }
        let group = store.projectGroups[gi]
        return sortedVisibleArtifactIndices(forGroup: gi).reduce(Int64(0)) { sum, ai in
            sum + group.artifacts[ai].sizeBytes
        }
    }

    private func sortedVisibleArtifactIndices(forGroup gi: Int) -> [Int] {
        guard store.projectGroups.indices.contains(gi) else { return [] }
        let g = store.projectGroups[gi]
        let filter = currentSafetyFilter
        let raw = g.artifacts.indices.filter {
            filter.matches(g.artifacts[$0].safetyInfo)
                && !store.isVisuallyRemovedBySafeCleanup(g.artifacts[$0])
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

    private func eligibleProjectArtifactPairs() -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        let filter = currentSafetyFilter
        for gi in filteredProjectGroupIndices() {
            for ai in store.projectGroups[gi].artifacts.indices {
                let art = store.projectGroups[gi].artifacts[ai]
                guard filter.matches(art.safetyInfo) else { continue }
                guard !store.isVisuallyRemovedBySafeCleanup(art) else { continue }
                pairs.append((gi, ai))
            }
        }
        return pairs
    }

    private enum SelectAllKey: Hashable {
        case tool(String)
        case artifact(groupID: String, artifactID: String)
        case simulator(UUID)
        case runtime(String)
    }

    /// Every visible row in one list, so Select All treats tools, project artifacts
    /// and simulators alike: safe ones first on the All filter.
    private var selectAll: SafeFirstSelectAll<SelectAllKey> {
        let sel = store.scanSelection
        var entries: [SafeFirstSelectAll<SelectAllKey>.Entry] = []
        for ti in filteredStandardToolIndices() {
            let tool = store.devTools[ti]
            entries.append(.init(
                key: .tool(tool.id),
                isSafe: tool.safetyInfo.level == .safe,
                isSelected: sel.devToolIDs.contains(tool.id),
                bytes: tool.sizeBytes
            ))
        }
        for (gi, ai) in eligibleProjectArtifactPairs() {
            let group = store.projectGroups[gi]
            let artifact = group.artifacts[ai]
            entries.append(.init(
                key: .artifact(groupID: group.id, artifactID: artifact.id),
                isSafe: artifact.safetyInfo.level == .safe,
                isSelected: sel.artifactIDs.contains(artifact.id),
                bytes: artifact.sizeBytes
            ))
        }
        for si in visibleSimulatorIndices() {
            let device = store.simulatorDevices[si]
            entries.append(.init(
                key: .simulator(device.id),
                isSafe: device.safetyInfo.level == .safe,
                isSelected: sel.simulatorIDs.contains(device.id),
                bytes: device.sizeOnDisk ?? 0
            ))
        }
        for ri in visibleRuntimeIndices() {
            let runtime = store.simulatorRuntimes[ri]
            entries.append(.init(
                key: .runtime(runtime.id),
                isSafe: runtime.safetyInfo.level == .safe,
                isSelected: sel.simulatorRuntimeIDs.contains(runtime.id),
                bytes: runtime.sizeBytes
            ))
        }
        return SafeFirstSelectAll(entries: entries, filter: currentSafetyFilter)
    }

    private func applySelectAll(_ change: SafeFirstSelectAll<SelectAllKey>.Change) {
        for key in change.select { setSelected(key, true) }
        for key in change.deselect { setSelected(key, false) }
    }

    private func setSelected(_ key: SelectAllKey, _ isSelected: Bool) {
        switch key {
        case .tool(let id):
            store.setDevToolSelected(id: id, isSelected: isSelected)
        case .artifact(let groupID, let artifactID):
            store.setProjectArtifactSelected(groupID: groupID, artifactID: artifactID, isSelected: isSelected)
        case .simulator(let id):
            store.setSimulatorDeviceSelected(id: id, isSelected: isSelected)
        case .runtime(let id):
            store.setSimulatorRuntimeSelected(id: id, isSelected: isSelected)
        }
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
        for runtime in store.simulatorRuntimes {
            infos.append(runtime.safetyInfo)
        }
        // Rows from the last scan count in the chips, so a filter never looks
        // empty while they show (#283).
        infos += lastScanTools.map(\.safetyInfo)
        infos += lastScanSimulators.map(\.safetyInfo)
        infos += lastScanRuntimes.map(\.safetyInfo)
        infos += lastScanProjectGroups.flatMap(\.artifacts).map(\.safetyInfo)
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
            && store.runningSimulatorDevices.isEmpty
            && !hasLastScanRows
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
            && !runtimeSectionVisible
            && sortedProjectGroupRows().isEmpty
    }

    /// Row counts mirror the dev tools list + chip aggregates (detected tools + all project artifacts),
    /// excluding items tagged `.unknown` since they are hidden from display.
    private var developerTotalRowCount: Int {
        store.devTools.filter { $0.isDetected && $0.safetyInfo.level != .unknown }.count +
            store.simulatorDevices.filter { $0.safetyInfo.level != .unknown }.count +
            store.simulatorRuntimes.filter { $0.safetyInfo.level != .unknown }.count +
            store.projectGroups.reduce(0) { sum, group in
                sum + group.artifacts.filter { $0.safetyInfo.level != .unknown }.count
            }
    }

    var body: some View {
        Group {
            if usesExternalScrollContainer {
                externalScrollBody
            } else {
                standardBody
            }
        }
        .background(AppColors.surfaceBase)
    }

    private var standardBody: some View {
        VStack(spacing: 0) {
            if !isAwaitingFirstScan {
                scanControlsChrome
            }
            scanListStack
        }
    }

    private var externalScrollBody: some View {
        // Controls and the Select All row sit above the list as opaque chrome; the
        // list cuts off cleanly at its own edge with no scroll-edge blur, matching
        // the App Uninstaller tab.
        VStack(spacing: 0) {
            if !isAwaitingFirstScan {
                fixedScanTabHeader
                selectAllRowChrome
            }
            scanListStack
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// No cache scan has finished this session and nothing has landed yet: the
    /// filters, Select All and sort have nothing to act on, so the tab shows only
    /// its status.
    private var isAwaitingFirstScan: Bool {
        store.isAwaitingFirstDevToolsScan && !hasLastScanRows
    }

    private var scanStatus: some View {
        ScanStatusPlaceholder(
            status: store.scanWaitStatus(for: .cachesAndDevTools, isScanning: isLoading),
            copy: .devTools
        )
    }

    /// Filter chips — fixed above the scroll edge; page title lives in the parent column header.
    private var fixedScanTabHeader: some View {
        filterToolbarChrome
    }

    private var filterToolbarChrome: some View {
        SafetyFilterChipRow(safetyFilter: safetyFilterBinding, chipCounts: chipCounts)
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
    }

    /// Bottom edge of the blur zone — list rows fade under this row only.
    private var selectAllRowChrome: some View {
        // Scoped so the tri-state updates on selection without re-rendering the
        // container (which would revert list scroll).
        ScanSelectionScope(selection: store.scanSelection, isSelected: { _ in false }) { _ in
            HStack(alignment: .bottom) {
                SafeFirstSelectAllControl(model: selectAll, apply: applySelectAll)
                Spacer()
                AppSortMenu(selection: sortOptionBinding)
            }
            .scanTabSelectAllRowLayout()
        }
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
            if isLoading || isAwaitingFirstScan {
                scanStatus
            } else {
                placeholderNoData
            }
        } else if nothingMatchesFilter {
            if isLoading {
                scanStatus
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
                .font(AppStyle.Typography.headline)
            Text(scanPhase == .completed ? LocalizedStringKey("Your Mac is looking clean. Check back later.") : LocalizedStringKey("Run a scan after adding projects or tool-generated folders."))
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum DeveloperListRowID: Hashable {
        case tool(String)
        case simulators
        case runtimes
        case projects
    }

    /// Scroll to real content: even a zero-height anchor occupies a native List row.
    private var firstDeveloperListRowID: DeveloperListRowID? {
        if case .tool(let id, _) = mergedStandardRowEntries().first {
            return .tool(id)
        }
        if simulatorSectionVisible { return .simulators }
        if runtimeSectionVisible { return .runtimes }
        if !sortedProjectGroupRows().isEmpty || store.isScanningProjects { return .projects }
        return nil
    }

    private var developerListOnly: some View {
        ScrollViewReader { proxy in
            developerListContent
                .onChange(of: scanPhase) { newPhase in
                    // A new scan just finished populating the list.
                    guard newPhase == .completed, let firstRowID = firstDeveloperListRowID else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(firstRowID, anchor: .top)
                    }
                }
        }
    }

    private var developerListContent: some View {
        List {
            ForEach(mergedStandardRowEntries()) { entry in
                switch entry {
                case .tool(let entryID, let index):
                    if store.devTools.indices.contains(index), store.devTools[index].id == entryID {
                    let tool = store.devTools[index]
                    let toolID = tool.id
                    let primaryPath = tool.primaryOverridePath
                    ScanSelectionScope(
                        selection: store.scanSelection,
                        isSelected: { $0.devToolIDs.contains(toolID) }
                    ) { selected in
                        ScanResultRow(
                            isSelected: selected,
                            onToggle: {
                                store.setDevToolSelected(
                                    id: toolID,
                                    isSelected: !store.scanSelection.devToolIDs.contains(toolID)
                                )
                            },
                            primaryLabel: tool.safetyInfo.headline,
                            formattedSize: tool.formattedSize,
                            safetyInfo: tool.safetyInfo,
                            brandIcon: .devTool(tool),
                            detailCaption: nil,
                            reinstallSafety: tool.reinstallSafety,
                            showUncommittedRepoChanges: !isDevToolMetadataPending(tool) && toolShowsUncommitted(tool),
                            onResetToAutomatic: primaryPath != nil ? { store.resetDevToolToAutomatic(id: toolID) } : nil,
                            onExcludeFromScans: { store.excludeFromScans(tool) },
                            revealLocations: {
                                // `standardizedPaths` is precomputed and parallel to `paths`,
                                // and is the key `pathSizeBytesByPath` uses.
                                zip(tool.paths, tool.standardizedPaths).map { path, key in
                                    ScanRowLocation(
                                        url: path,
                                        sizeBytes: tool.pathSizeBytesByPath[key]
                                            ?? (tool.paths.count == 1 ? tool.sizeBytes : nil)
                                    )
                                }
                            },
                            isUserOverride: primaryPath.map { store.userOverridePaths.contains($0.standardizedFileURL.path) } ?? false,
                            isMetadataPending: isDevToolMetadataPending(tool)
                        )
                    }
                    .disabled(!tool.isDetected)
                    .opacity(tool.isDetected ? 1 : 0.45)
                    .id(DeveloperListRowID.tool(toolID))
                    .listRowInsets(ScanListRowInsets.standard)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .transition(rowInsertionTransition)
                    }
                case .savedTool(let entryID, let index):
                    let saved = store.lastScanRows.devTools
                    if saved.indices.contains(index), saved[index].id == entryID {
                        let tool = saved[index]
                        ScanResultRow(
                            isSelected: false,
                            primaryLabel: tool.safetyInfo.headline,
                            formattedSize: tool.formattedSize,
                            safetyInfo: tool.safetyInfo,
                            brandIcon: .devTool(tool),
                            reinstallSafety: tool.reinstallSafety,
                            revealLocations: {
                                zip(tool.paths, tool.standardizedPaths).map { path, key in
                                    ScanRowLocation(
                                        url: path,
                                        sizeBytes: tool.pathSizeBytesByPath[key]
                                            ?? (tool.paths.count == 1 ? tool.sizeBytes : nil)
                                    )
                                }
                            },
                            isFromLastScan: true
                        )
                        .id(DeveloperListRowID.tool(tool.id))
                        .listRowInsets(ScanListRowInsets.standard)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .transition(rowInsertionTransition)
                    }
                }
            }

            if simulatorSectionVisible {
                Group {
                    iosSimulatorsSectionHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    ForEach(sortedSimulatorRowIDs(), id: \.self) { deviceID in
                        if let device = store.simulatorDevices.first(where: { $0.id == deviceID }) {
                            ScanSelectionScope(
                                selection: store.scanSelection,
                                isSelected: { $0.simulatorIDs.contains(device.id) }
                            ) { selected in
                                ScanResultRow(
                                    isSelected: selected,
                                    onToggle: {
                                        store.setSimulatorDeviceSelected(
                                            id: device.id,
                                            isSelected: !store.scanSelection.simulatorIDs.contains(device.id)
                                        )
                                    },
                                    primaryLabel: device.safetyInfo.headline,
                                    formattedSize: device.formattedSize,
                                    safetyInfo: device.safetyInfo,
                                    brandIcon: .sfSymbol("ipad.and.iphone"),
                                    detailCaption: nil,
                                    reinstallSafety: .notApplicable,
                                    showUncommittedRepoChanges: false,
                                    onResetToAutomatic: nil,
                                    onExcludeFromScans: { store.excludeFromScans(device) },
                                    revealLocations: {
                                        [ScanRowLocation(url: device.folderURL, sizeBytes: device.sizeOnDisk)]
                                    },
                                    isUserOverride: false,
                                    allowsBulkSelection: true,
                                    isMetadataPending: isSimulatorMetadataPending(device),
                                    usesCompactExplanation: true
                                )
                            }
                            .listRowInsets(ScanListRowInsets.standard)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .transition(rowInsertionTransition)
                        } else if let device = lastScanSimulators.first(where: { $0.id == deviceID }) {
                            ScanResultRow(
                                isSelected: false,
                                primaryLabel: device.safetyInfo.headline,
                                formattedSize: device.formattedSize,
                                safetyInfo: device.safetyInfo,
                                brandIcon: .sfSymbol("ipad.and.iphone"),
                                revealLocations: {
                                    [ScanRowLocation(url: device.folderURL, sizeBytes: device.sizeOnDisk)]
                                },
                                usesCompactExplanation: true,
                                isFromLastScan: true
                            )
                            .listRowInsets(ScanListRowInsets.standard)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .transition(rowInsertionTransition)
                        }
                    }

                    // No checkbox: a running device is never offered for removal.
                    ForEach(visibleRunningSimulators) { device in
                        ScanResultRow(
                            isSelected: false,
                            primaryLabel: device.safetyInfo.headline,
                            formattedSize: device.formattedSize,
                            safetyInfo: device.safetyInfo,
                            brandIcon: .sfSymbol("ipad.and.iphone"),
                            revealLocations: {
                                [ScanRowLocation(url: device.folderURL, sizeBytes: device.sizeOnDisk)]
                            },
                            allowsBulkSelection: false,
                            usesCompactExplanation: true
                        )
                        .listRowInsets(ScanListRowInsets.standard)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .transition(rowInsertionTransition)
                    }
                }
            }

            if runtimeSectionVisible {
                Group {
                    simulatorRuntimesSectionHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    ForEach(sortedRuntimeRowIDs(), id: \.self) { runtimeID in
                        if let runtime = store.simulatorRuntimes.first(where: { $0.id == runtimeID }) {
                            ScanSelectionScope(
                                selection: store.scanSelection,
                                isSelected: { $0.simulatorRuntimeIDs.contains(runtime.id) }
                            ) { selected in
                                ScanResultRow(
                                    isSelected: selected,
                                    onToggle: {
                                        store.setSimulatorRuntimeSelected(
                                            id: runtime.id,
                                            isSelected: !store.scanSelection.simulatorRuntimeIDs.contains(runtime.id)
                                        )
                                    },
                                    primaryLabel: runtime.safetyInfo.headline,
                                    formattedSize: runtime.formattedSize,
                                    safetyInfo: runtime.safetyInfo,
                                    brandIcon: .sfSymbol("internaldrive"),
                                    detailCaption: String(localized: "Build \(runtime.build)"),
                                    reinstallSafety: .notApplicable,
                                    showUncommittedRepoChanges: false,
                                    onResetToAutomatic: nil,
                                    onExcludeFromScans: { store.excludeFromScans(runtime) },
                                    revealLocations: {
                                        [ScanRowLocation(url: runtime.locationURL, sizeBytes: runtime.sizeBytes)]
                                    },
                                    isUserOverride: false,
                                    allowsBulkSelection: true,
                                    isMetadataPending: false,
                                    usesCompactExplanation: true
                                )
                            }
                            .listRowInsets(ScanListRowInsets.standard)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .transition(rowInsertionTransition)
                        } else if let runtime = lastScanRuntimes.first(where: { $0.id == runtimeID }) {
                            ScanResultRow(
                                isSelected: false,
                                primaryLabel: runtime.safetyInfo.headline,
                                formattedSize: runtime.formattedSize,
                                safetyInfo: runtime.safetyInfo,
                                brandIcon: .sfSymbol("internaldrive"),
                                detailCaption: String(localized: "Build \(runtime.build)"),
                                revealLocations: {
                                    [ScanRowLocation(url: runtime.locationURL, sizeBytes: runtime.sizeBytes)]
                                },
                                usesCompactExplanation: true,
                                isFromLastScan: true
                            )
                            .listRowInsets(ScanListRowInsets.standard)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .transition(rowInsertionTransition)
                        }
                    }
                }
            }

            if !sortedProjectGroupRows().isEmpty {
                Group {
                    developerProjectsSectionHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    ForEach(sortedProjectGroupRows()) { row in
                        let gi = row.groupIndex
                        if row.isFromLastScan {
                            let saved = lastScanProjectGroups
                            if saved.indices.contains(gi), row.id == "project-group-\(saved[gi].id)" {
                                lastScanProjectGroupCard(saved[gi])
                                    .listRowInsets(ScanListRowInsets.standard)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .transition(rowInsertionTransition)
                            }
                        } else if store.projectGroups.indices.contains(gi), row.id == "project-group-\(store.projectGroups[gi].id)" {
                            let group = store.projectGroups[gi]
                            let isExpanded = expandedProjectRoots.contains(group.id)

                            projectGroupCard(for: group, groupIndex: gi, isExpanded: isExpanded)
                                .listRowInsets(ScanListRowInsets.standard)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .transition(rowInsertionTransition)
                        }
                    }

                    // One more card's shape under the projects found so far, while
                    // the search goes on.
                    if store.isScanningProjects {
                        ProjectGroupSkeletonCard(titleWidth: 130)
                            .listRowInsets(ScanListRowInsets.standard)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .transition(.opacity)
                    }
                }
            } else if store.isScanningProjects {
                Group {
                    developerProjectsSectionHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    // Cards in the shape of the ones the search lands, so nothing
                    // moves when the first project arrives.
                    ForEach(ProjectGroupSkeletonCard.titleWidths, id: \.self) { width in
                        ProjectGroupSkeletonCard(titleWidth: width)
                            .listRowInsets(ScanListRowInsets.standard)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .transition(.opacity)
                    }
                }
            }

            ScanListBottomSpacer()
        }
        .listStyle(.plain)
        // Headings use their own token-based padding, without a minimum row height
        // or native Section spacing adding a second gap.
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(AppColors.surfaceBase)
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

    private var developerProjectsSectionHeader: some View {
        devToolsSectionHeader(.projects) {
            HStack(alignment: .center, spacing: AppStyle.Spacing.small) {
                Text("Developer Projects")
                    .font(AppStyle.Typography.metadataEmphasis)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: AppStyle.Spacing.small)
                if store.isScanningProjects {
                    ProjectSearchStatus(found: sortedProjectGroupRows().filter { !$0.isFromLastScan }.count)
                }
            }
        }
    }

    private var iosSimulatorsSectionHeader: some View {
        devToolsSectionHeader(.simulators) {
            permanentSectionTitle(String(localized: "iOS Simulators"))
        }
    }

    private var simulatorRuntimesSectionHeader: some View {
        devToolsSectionHeader(.runtimes) {
            permanentSectionTitle(String(localized: "Simulator Runtimes"))
        }
    }

    /// `simctl` deletes simulators and runtimes, so the header says they skip the
    /// Trash before anything is ticked (#170).
    private func permanentSectionTitle(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.small) {
            Text(title)
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.textSecondary)
            Spacer(minLength: AppStyle.Spacing.small)
            Text("Deleted permanently, not moved to the Trash")
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(1)
        }
    }

    private func devToolsSectionHeader<Content: View>(_ rowID: DeveloperListRowID, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, firstDeveloperListRowID == rowID ? 0 : AppStyle.Spacing.medium)
            .padding(.bottom, AppStyle.Spacing.xxSmall)
            .padding(.leading, ScanListRowInsets.standard.leading)
            .padding(.trailing, ScanListRowInsets.standard.trailing)
            .id(rowID)
    }

    @ViewBuilder
    private func projectGroupCard(for group: ProjectGroup, groupIndex _: Int, isExpanded: Bool) -> some View {
        if let currentGroupIndex = store.projectGroups.firstIndex(where: { $0.id == group.id }) {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                // Scoped so the group tri-state reflects artifact selection changes
                // without re-rendering the list container.
                ScanSelectionScope(selection: store.scanSelection, isSelected: { _ in false }) { _ in
                    TriStateCheckbox(title: "", state: projectSelectTriState(forGroupID: group.id)) {
                        toggleProjectEligibleSelection(groupID: group.id)
                    }
                }
                .frame(width: 24)

                Button {
                    toggleProjectExpanded(group.id)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        AdaptiveBrandIconImage(
                            source: .projectGroup(group),
                            squareSize: AppStyle.Row.projectGroupIconSize
                        )
                        .accessibilityLabel(projectGroupIconAccessibilityLabel(for: group))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.displayName)
                                .font(AppStyle.Typography.rowTitle)
                            Text(projectSummary(groupIndex: currentGroupIndex))
                                .font(AppStyle.Typography.metadata)
                                .foregroundStyle(AppColors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(formatBytes(visibleGroupByteTotal(groupID: group.id)))
                            .font(AppStyle.Typography.rowTitle.numbers)
                            .foregroundStyle(AppColors.textSecondary)
                            .monospacedDigit()
                        projectBadge(level: projectLevel(groupIndex: currentGroupIndex))
                        ZStack {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0), anchor: .center)
                        .padding(.trailing, AppStyle.Spacing.xSmall)
                        .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? LocalizedStringKey("Collapse project") : LocalizedStringKey("Expand project"))
                .accessibilityValue(Text(verbatim:
                    "\(projectLevel(groupIndex: currentGroupIndex).displayName). \(projectSummary(groupIndex: currentGroupIndex))"
                ))
            }
            .padding(.vertical, AppStyle.Spacing.xSmall)
            .padding(.horizontal, AppStyle.Spacing.xSmall)
            .frame(minHeight: AppStyle.Row.parentHeight)
            // Header only: an overlay across the whole card would swallow the
            // right-click meant for an individual artifact row.
            .overlay {
                ScanRowContextMenu(isMenuActive: .constant(false)) {
                    [
                        .action(title: String(localized: "Exclude project from scans")) {
                            store.excludeProjectGroupFromScans(groupID: group.id)
                        },
                        .separator,
                    ] + FinderReveal.menuEntries(for: [ScanRowLocation(url: group.rootPath)])
                }
            }
            // The overlay only answers a secondary click, which VoiceOver and the
            // keyboard cannot produce.
            .accessibilityAction(named: Text("Exclude project from scans")) {
                store.excludeProjectGroupFromScans(groupID: group.id)
            }
            .accessibilityAction(named: Text("Show in Finder")) {
                FinderReveal.show(group.rootPath)
            }
            .accessibilityAction(named: Text("Copy Path")) {
                FinderReveal.copyPaths([group.rootPath])
            }

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

    /// A project from the last scan (#283): the card's header, read only, with the
    /// clock where its checkbox goes. Its folders are named in the summary line.
    private func lastScanProjectGroupCard(_ group: ProjectGroup) -> some View {
        let filter = currentSafetyFilter
        let artifacts = group.artifacts.filter { filter.matches($0.safetyInfo) }
        let level: SafetyLevel = artifacts.contains { $0.safetyInfo.level == .medium } ? .medium : .safe
        let summary = artifacts.first(where: { $0.checkFirstReason != nil && $0.safetyInfo.level == .medium })?
            .checkFirstReason?.summary
            ?? artifacts.map(\.safetyInfo.headline).joined(separator: String(localized: ", "))
        return HStack(alignment: .center, spacing: 10) {
            LastScanRowMarker()
                .frame(width: 24)
            AdaptiveBrandIconImage(
                source: .projectGroup(group),
                squareSize: AppStyle.Row.projectGroupIconSize
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(AppStyle.Typography.rowTitle)
                Text(summary)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatBytes(artifacts.reduce(Int64(0)) { $0 + $1.sizeBytes }))
                .font(AppStyle.Typography.rowTitle.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
            projectBadge(level: level)
            // Where the chevron sits, so sizes line up with the live cards.
            Color.clear
                .frame(width: 12, height: 12)
                .padding(.trailing, AppStyle.Spacing.xSmall)
        }
        .padding(.vertical, AppStyle.Spacing.xSmall)
        .padding(.horizontal, AppStyle.Spacing.xSmall)
        .frame(minHeight: AppStyle.Row.parentHeight)
        .contentShape(Rectangle())
        .help(LastScanRowMarker.help)
        .overlay {
            ScanRowContextMenu(isMenuActive: .constant(false)) {
                FinderReveal.menuEntries(for: [ScanRowLocation(url: group.rootPath)])
            }
        }
        .devToolsGroupCardChrome()
        .opacity(0.55)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project \(group.displayName)")
        .accessibilityHint(LastScanRowMarker.help)
    }

    /// The strictest level among the folders on show, so a closed card never reads
    /// Safe while one of its folders is Check First.
    private func projectLevel(groupIndex gi: Int) -> SafetyLevel {
        let levels = sortedVisibleArtifactIndices(forGroup: gi).map { store.projectGroups[gi].artifacts[$0].safetyInfo.level }
        if levels.contains(.unknown) { return .unknown }
        if levels.contains(.medium) { return .medium }
        return .safe
    }

    /// Why the project is held at Check First, said once for all its folders, or
    /// else the folders it holds.
    private func projectSummary(groupIndex gi: Int) -> String {
        let artifacts = sortedVisibleArtifactIndices(forGroup: gi).map { store.projectGroups[gi].artifacts[$0] }
        if let held = artifacts.first(where: { $0.checkFirstReason != nil && $0.safetyInfo.level == .medium }),
           let reason = held.checkFirstReason {
            return reason.summary
        }
        return artifacts.map(\.safetyInfo.headline).joined(separator: String(localized: ", "))
    }

    /// As wide as the widest level's badge, so sizes line up down the list in any
    /// language.
    private func projectBadge(level: SafetyLevel) -> some View {
        ZStack(alignment: .trailing) {
            ForEach(SafetyLevel.allCases, id: \.self) { slot in
                AppBadge(text: slot.displayName, tone: Self.badgeTone(for: slot)).hidden()
            }
            AppBadge(text: level.displayName, tone: Self.badgeTone(for: level))
        }
        .accessibilityHidden(true)
    }

    private static func badgeTone(for level: SafetyLevel) -> AppBadge.Tone {
        switch level {
        case .safe: return .safe
        case .medium: return .warning
        case .unknown: return .neutral
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

            ScanSelectionScope(
                selection: store.scanSelection,
                isSelected: { $0.artifactIDs.contains(artifactID) }
            ) { selected in
                ScanResultRow(
                    isSelected: selected,
                    onToggle: {
                        store.setProjectArtifactSelected(
                            groupID: groupID,
                            artifactID: artifactID,
                            isSelected: !store.scanSelection.artifactIDs.contains(artifactID)
                        )
                    },
                    primaryLabel: art.safetyInfo.headline,
                    formattedSize: art.formattedSize,
                    safetyInfo: art.safetyInfo,
                    brandIcon: nil,
                    detailCaption: nil,
                    reinstallSafety: nil,
                    showUncommittedRepoChanges: !isArtifactMetadataPending(art) && art.gitStatus == .dirty,
                    onResetToAutomatic: { store.resetProjectArtifactToAutomatic(groupID: groupID, artifactID: artifactID) },
                    onExcludeFromScans: {
                        store.excludeProjectArtifactFromScans(groupID: groupID, artifactID: artifactID)
                    },
                    revealLocations: {
                        [ScanRowLocation(url: art.path, sizeBytes: art.sizeBytes)]
                    },
                    isUserOverride: store.userOverridePaths.contains(artifactPath),
                    showsBulkCheckbox: false,
                    isMetadataPending: isArtifactMetadataPending(art) || store.projectArtifactHasPendingSize(art),
                    showsCardChrome: false,
                    showsLeadingIcon: false
                )
            }
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

    private var emptyFilterState: some View {
        VStack(spacing: 4) {
            Text("Nothing here.")
                .font(AppStyle.Typography.headline)
            Text("No items match this filter.")
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func devToolModified(_ tool: DevTool) -> Date {
        tool.lastModified
    }

    private func projectGroupIconAccessibilityLabel(for group: ProjectGroup) -> String {
        let types = group.inferredTypes.map(\.displayName).joined(separator: String(localized: ", "))
        if types.isEmpty {
            return String(localized: "Project")
        }
        return String(localized: "Project, \(types)")
    }
}

/// Beside the Developer Projects heading while the search runs. The count is of
/// the projects this scan has listed, so it grows as they land.
private struct ProjectSearchStatus: View {
    let found: Int

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(found > 0 ? String(localized: "\(found) found, still looking…") : String(localized: "Searching…"))
                .font(AppStyle.Typography.metadata.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A project card with no project in it: the same checkbox, icon, two text lines
/// and chevron at the same height, so the card that replaces it doesn't move.
private struct ProjectGroupSkeletonCard: View {
    /// Title widths for the cards shown before any project lands, so they read as
    /// a list, not a pattern.
    static let titleWidths: [CGFloat] = [140, 110, 160]

    let titleWidth: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: AppStyle.Radius.xs, style: .continuous)
                .stroke(AppColors.textSecondary.opacity(SkeletonOpacity.medium), lineWidth: 1)
                .frame(width: 14, height: 14)
                .frame(width: 24)
            RoundedRectangle(cornerRadius: AppStyle.Radius.xs, style: .continuous)
                .fill(AppColors.textSecondary.opacity(SkeletonOpacity.medium))
                .frame(width: AppStyle.Row.projectGroupIconSize, height: AppStyle.Row.projectGroupIconSize)
            // Invisible text in the real card's styles holds its line heights.
            VStack(alignment: .leading, spacing: 2) {
                ZStack(alignment: .leading) {
                    Text(verbatim: " ").font(AppStyle.Typography.rowTitle).opacity(0)
                    SkeletonBar(width: titleWidth, height: 10)
                }
                ZStack(alignment: .leading) {
                    Text(verbatim: " ").font(AppStyle.Typography.metadata).opacity(0)
                    SkeletonBar(width: titleWidth * 0.6, height: 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SkeletonBar(width: 52, height: 10)
            SkeletonBar(width: 12, height: 12)
                .padding(.trailing, AppStyle.Spacing.xSmall)
        }
        .padding(.vertical, AppStyle.Spacing.xSmall)
        .padding(.horizontal, AppStyle.Spacing.xSmall)
        .frame(minHeight: AppStyle.Row.parentHeight)
        .devToolsGroupCardChrome()
        .shimmering()
        .accessibilityHidden(true)
    }
}

private extension View {
    func devToolsGroupCardChrome() -> some View {
        modifier(ScanRowCardChrome())
    }
}

#Preview("Dev Tools — scanning") {
    DevToolsView(
        isLoading: true,
        scanPhase: .scanning
    )
        .environmentObject(PurgeStore())
        .frame(width: 720, height: 560)
}

#Preview("Dev Tools — loaded") {
    let store = PurgeStore()
    return DevToolsView(
        isLoading: false,
        scanPhase: .idle
    )
        .environmentObject(store)
        .frame(width: 720, height: 560)
}
