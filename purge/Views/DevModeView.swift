import AppKit
import SwiftUI

struct DevToolsView: View {
    @EnvironmentObject private var store: PurgeStore
    let isLoading: Bool
    let onScan: () -> Void

    @State private var expandedProjectRoots = Set<String>()
    /// Last completed dev scan; stabilizes chip counts during an in-flight rescan.
    @State private var displayedDevTools: [DevTool] = []
    @State private var displayedProjectGroups: [ProjectGroup] = []

    /// Stable list IDs so sibling `ForEach` loops in the same `List` never share
    /// bare `Int` identities (which can duplicate or swap rows on expand/collapse).
    private struct StandardToolRowKey: Hashable, Identifiable {
        let id: String
        let toolIndex: Int
        static func make(_ toolIndex: Int) -> StandardToolRowKey {
            StandardToolRowKey(id: "standard-tool-\(toolIndex)", toolIndex: toolIndex)
        }
    }

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

    @AppStorage("filter.devTools") private var filterRaw: String = SafetyFilter.all.rawValue
    @AppStorage("sort.devTools") private var sortRaw: String = SortOption.sizeDesc.rawValue
    @AppStorage("hasSeenAIUpgradeBanner") private var hasSeenAIUpgradeBanner = false
    @State private var showAIUpgradeBanner = false
    @State private var hasScheduledAIUpgradeBannerAutoDismiss = false
    @State private var aiUpgradeBannerAutoDismissTask: Task<Void, Never>?

    /// Percent of unknown rows the post-key AI sweep has resolved so far (0–100).
    private var aiUpgradeProgress: Int {
        let total = store.unknownReidentifyTotal
        guard total > 0 else { return 0 }
        let done = min(store.unknownReidentifyResolved, total)
        return Int((Double(done) / Double(total)) * 100)
    }

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
        group.artifacts.contains { artifactVisible($0.safetyInfo) }
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

    private func isEligibleForManualBulkSelection(_ info: SafetyInfo) -> Bool {
        switch info.level {
        case .safe, .medium, .danger:
            return true
        case .unknown:
            return !ExplanationResolver.isAwaitingAI(info)
        }
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

    private func sortedVisibleArtifactIndices(forGroup gi: Int) -> [Int] {
        let g = store.projectGroups[gi]
        let raw = g.artifacts.indices.filter { artifactVisible(g.artifacts[$0].safetyInfo) }
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
                guard isEligibleForManualBulkSelection(art.safetyInfo) else { continue }
                pairs.append((gi, ai))
            }
        }
        return pairs
    }

    private var hasEligibleSelectableRows: Bool {
        !eligibleStandardToolIndices().isEmpty || !eligibleProjectArtifactPairs().isEmpty
    }

    private var selectAllDeveloperState: SelectAllTriState {
        let toolIx = eligibleStandardToolIndices()
        let pairs = eligibleProjectArtifactPairs()
        let total = toolIx.count + pairs.count
        guard total > 0 else { return .none }

        var selected = 0
        for ti in toolIx where store.devTools[ti].isSelected { selected += 1 }
        for p in pairs where store.projectGroups[p.0].artifacts[p.1].isSelected { selected += 1 }

        if selected == 0 { return .none }
        if selected == total { return .all }
        return .mixed
    }

    private var selectedInScopeCount: Int {
        let toolIx = eligibleStandardToolIndices().filter { store.devTools[$0].isSelected }.count
        let pairSelected = eligibleProjectArtifactPairs().filter { store.projectGroups[$0.0].artifacts[$0.1].isSelected }.count
        return toolIx + pairSelected
    }

    private func developerSafetySnapshotsForChipRow() -> [SafetyInfo] {
        let tools = isLoading ? displayedDevTools : store.devTools
        let groups = isLoading ? displayedProjectGroups : store.projectGroups
        var infos: [SafetyInfo] = tools.filter(\.isDetected).map(\.safetyInfo)
        for group in groups {
            for art in group.artifacts {
                infos.append(art.safetyInfo)
            }
        }
        return infos
    }

    private var chipCounts: [SafetyFilter: Int] {
        let infos = developerSafetySnapshotsForChipRow()
        var d: [SafetyFilter: Int] = [:]
        for filter in SafetyFilter.allCases {
            switch filter {
            case .all:
                d[filter] = infos.count
            case .safe:
                d[filter] = infos.filter { $0.level == .safe }.count
            case .medium:
                d[filter] = infos.filter { $0.level == .medium }.count
            case .danger:
                d[filter] = infos.filter { $0.level == .danger }.count
            case .unknown:
                d[filter] = infos.filter { $0.level == .unknown }.count
            }
        }
        return d
    }

    private var developerListEmpty: Bool {
        store.projectGroups.isEmpty && store.devTools.isEmpty
    }

    private var nothingMatchesFilter: Bool {
        filteredStandardToolIndices().isEmpty && filteredProjectGroupIndices().isEmpty
    }

    /// Row counts mirror the dev tools list + chip aggregates (detected tools + all project artifacts).
    private var developerTotalRowCount: Int {
        store.devTools.filter(\.isDetected).count +
            store.projectGroups.reduce(0) { $0 + $1.artifacts.count }
    }

    private var developerVisibleRowCount: Int {
        sortedStandardToolIndices().count +
            sortedProjectGroupIndices().reduce(0) { sum, gi in
                sum + sortedVisibleArtifactIndices(forGroup: gi).count
            }
    }

    private var developerTotalByteSize: Int64 {
        let tools = store.devTools.filter(\.isDetected).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let artifacts = store.projectGroups.reduce(Int64(0)) { sum, group in
            sum + group.artifacts.reduce(Int64(0)) { $0 + $1.sizeBytes }
        }
        return tools + artifacts
    }

    private var developerVisibleByteSize: Int64 {
        var sum = Int64(0)
        for i in filteredStandardToolIndices() {
            sum += store.devTools[i].sizeBytes
        }
        for gi in filteredProjectGroupIndices() {
            let g = store.projectGroups[gi]
            for ai in g.artifacts.indices where artifactVisible(g.artifacts[ai].safetyInfo) {
                sum += g.artifacts[ai].sizeBytes
            }
        }
        return sum
    }

    var body: some View {
        VStack(spacing: 0) {
            if showAIUpgradeBanner {
                aiUpgradeBanner
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
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
            .padding(.horizontal)
            .padding(.top, 8)
            .opacity(isLoading ? 0.4 : 1.0)
            .disabled(isLoading)

            HStack {
                TriStateCheckbox(title: "Select All", state: selectAllDeveloperState) {
                    toggleDeveloperSelectAll()
                }
                .fixedSize()
                .disabled(isLoading || !hasEligibleSelectableRows)
                Spacer()
                Picker("Sort", selection: sortOptionBinding) {
                    ForEach(SortOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .opacity(isLoading ? 0.4 : 1.0)
            .disabled(isLoading)

            ZStack {
                if isLoading && developerListEmpty {
                    ScanListSkeletonPlaceholder()
                } else if !isLoading && developerListEmpty {
                    placeholderNoData
                } else if nothingMatchesFilter && !developerListEmpty {
                    emptyFilterState
                } else {
                    developerListOnly
                        .disabled(isLoading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if isLoading {
                    Text("Scanning…")
                } else if currentSafetyFilter == .all {
                    Text("\(developerTotalRowCount) items")
                } else {
                    Text("\(developerVisibleRowCount) of \(developerTotalRowCount) items")
                }
                Spacer()
                if isLoading {
                    Text("")
                } else {
                    Text("Total: \(formatBytes(currentSafetyFilter == .all ? developerTotalByteSize : developerVisibleByteSize))")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle("Dev Tools")
        .onAppear {
            syncDisplayedDeveloperSnapshotIfIdle()
            syncAIUpgradeBannerVisibilityForAppear()
        }
        .onChange(of: isLoading) { scanning in
            if !scanning {
                displayedDevTools = store.devTools
                displayedProjectGroups = store.projectGroups
            }
        }
        .onChange(of: store.devTools) { _ in
            syncDisplayedDeveloperSnapshotIfIdle()
        }
        .onChange(of: store.projectGroups) { _ in
            syncDisplayedDeveloperSnapshotIfIdle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyAdded)) { _ in
            guard !hasSeenAIUpgradeBanner else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                showAIUpgradeBanner = true
            }
        }
        .onChange(of: aiUpgradeProgress) { newProgress in
            scheduleAIUpgradeBannerAutoDismissIfComplete(progress: newProgress)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: onScan) {
                    Label("Scan", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }

    private func syncDisplayedDeveloperSnapshotIfIdle() {
        guard !isLoading else { return }
        displayedDevTools = store.devTools
        displayedProjectGroups = store.projectGroups
    }

    /// Re-show the AI upgrade banner when the user navigates to Dev Tools while
    /// the post-key sweep is still in flight. Lets the banner "follow" the user
    /// across tabs without requiring a fresh notification.
    private func syncAIUpgradeBannerVisibilityForAppear() {
        guard !hasSeenAIUpgradeBanner else { return }
        guard store.isReidentifyingUnknownItems || store.unknownReidentifyTotal > 0 else { return }
        guard !showAIUpgradeBanner else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            showAIUpgradeBanner = true
        }
    }

    private func scheduleAIUpgradeBannerAutoDismissIfComplete(progress: Int) {
        guard progress >= 100,
              showAIUpgradeBanner,
              !hasScheduledAIUpgradeBannerAutoDismiss
        else { return }
        hasScheduledAIUpgradeBannerAutoDismiss = true
        aiUpgradeBannerAutoDismissTask?.cancel()
        aiUpgradeBannerAutoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.35)) {
                    showAIUpgradeBanner = false
                }
                hasSeenAIUpgradeBanner = true
            }
        }
    }

    private var aiUpgradeBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text("AI is now identifying your unknown folders")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button("Got it") {
                        aiUpgradeBannerAutoDismissTask?.cancel()
                        aiUpgradeBannerAutoDismissTask = nil
                        withAnimation(.easeInOut(duration: 0.35)) {
                            showAIUpgradeBanner = false
                        }
                        hasSeenAIUpgradeBanner = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                }

                Text("Purge is categorising dev tool folders it could not identify before. Results are saved permanently · \(aiUpgradeProgress)% done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.25), value: aiUpgradeProgress)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 2)
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
            ForEach(sortedStandardToolIndices().map(StandardToolRowKey.make)) { row in
                    let index = row.toolIndex
                    let tool = store.devTools[index]
                    let toolID = tool.id
                    let primaryPath = tool.primaryOverridePath
                    ScanResultRow(
                        isSelected: bindingForStandardTool(index),
                        primaryLabel: tool.safetyInfo.headline,
                        formattedSize: tool.formattedSize,
                        dateModifiedLine: DateFormatter.localizedString(
                            from: devToolModified(tool),
                            dateStyle: .medium,
                            timeStyle: .short
                        ),
                        safetyInfo: tool.safetyInfo,
                        icon: symbolIcon(tool.iconName),
                        onRequestUnknownDelete: tool.safetyInfo.level == .unknown && !ExplanationResolver.isAwaitingAI(tool.safetyInfo)
                            ? { store.requestUnknownDeletion(candidates: store.unknownDeletionCandidates(forDevTool: tool)) }
                            : nil,
                        detailCaption: nil,
                        reinstallSafety: reinstallRollup(for: tool),
                        showUncommittedRepoChanges: toolShowsUncommitted(tool),
                        onRecategorize: primaryPath != nil ? { store.recategorizeDevTool(id: toolID) } : nil,
                        onMarkSafe: primaryPath != nil ? { store.markDevTool(id: toolID, as: .safe) } : nil,
                        onMarkMedium: primaryPath != nil ? { store.markDevTool(id: toolID, as: .medium) } : nil,
                        onMarkDanger: primaryPath != nil ? { store.markDevTool(id: toolID, as: .danger) } : nil,
                        onResetToAutomatic: primaryPath != nil ? { store.resetDevToolToAutomatic(id: toolID) } : nil,
                        isUserOverride: primaryPath.map { store.userOverridePaths.contains($0.standardizedFileURL.path) } ?? false
                    )
                    .disabled(!tool.isDetected)
                    .opacity(tool.isDetected ? 1 : 0.45)
            }

            if !sortedProjectGroupIndices().isEmpty {
                Section {
                    ForEach(sortedProjectGroupIndices().map(ProjectGroupRowKey.make)) { row in
                            let gi = row.groupIndex
                            let group = store.projectGroups[gi]
                            let isExpanded = expandedProjectRoots.contains(group.id)

                            projectDisclosureHeader(for: group, groupIndex: gi, isExpanded: isExpanded)

                            if isExpanded {
                                ForEach(
                                    sortedVisibleArtifactIndices(forGroup: gi).map {
                                        ProjectArtifactRowKey.make(groupIndex: gi, artifactIndex: $0)
                                    }
                                ) { artRow in
                                    let ai = artRow.artifactIndex
                                    let art = store.projectGroups[gi].artifacts[ai]
                                    let artifactPath = art.path
                                    ScanResultRow(
                                        isSelected: bindingForArtifact(gi: gi, ai: ai),
                                        primaryLabel: art.safetyInfo.headline,
                                        formattedSize: art.formattedSize,
                                        dateModifiedLine: DateFormatter.localizedString(
                                            from: art.lastModified,
                                            dateStyle: .medium,
                                            timeStyle: .short
                                        ),
                                        safetyInfo: art.safetyInfo,
                                        icon: NSWorkspace.shared.icon(forFileType: "public.folder"),
                                        onRequestUnknownDelete: art.safetyInfo.level == .unknown && !ExplanationResolver.isAwaitingAI(art.safetyInfo)
                                            ? {
                                                store.requestUnknownDeletion(candidates:
                                                    store.unknownDeletionCandidates(forArtifact: art)
                                                )
                                              }
                                            : nil,
                                        detailCaption: art.kind.rowTag,
                                        reinstallSafety: art.reinstallSafety,
                                        showUncommittedRepoChanges: art.gitStatus == .dirty,
                                        onRecategorize: { store.recategorizeProjectArtifact(groupIndex: gi, artifactIndex: ai) },
                                        onMarkSafe: { store.markProjectArtifact(groupIndex: gi, artifactIndex: ai, as: .safe) },
                                        onMarkMedium: { store.markProjectArtifact(groupIndex: gi, artifactIndex: ai, as: .medium) },
                                        onMarkDanger: { store.markProjectArtifact(groupIndex: gi, artifactIndex: ai, as: .danger) },
                                        onResetToAutomatic: { store.resetProjectArtifactToAutomatic(groupIndex: gi, artifactIndex: ai) },
                                        isUserOverride: store.userOverridePaths.contains(artifactPath.standardizedFileURL.path)
                                    )
                                    .padding(.leading, 18)
                                }
                            }
                        }
                } header: {
                    Text("Projects")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }

    private func projectDisclosureHeader(for group: ProjectGroup, groupIndex gi: Int, isExpanded: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                toggleProjectExpanded(group.id)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 44, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse project" : "Expand project")

            projectHeader(for: group, groupIndex: gi)
        }
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

    private func projectHeader(for group: ProjectGroup, groupIndex gi: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            TriStateCheckbox(title: "", state: projectSelectTriState(forGroupIndex: gi)) {
                toggleProjectEligibleSelection(groupIndex: gi)
            }
            .frame(width: 24)
            ForEach(group.inferredTypes, id: \.self) { type in
                Image(systemName: type.systemImageName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .help(type.displayName)
                    .accessibilityLabel(type.displayName)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.headline.weight(.semibold))
                Text(group.rootPath.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(group.formattedTotal)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityLabel("Project \(group.displayName)")
        .accessibilityHint("Grouped dev tool cleanup targets")
    }

    private func toggleDeveloperSelectAll() {
        let toolsIx = eligibleStandardToolIndices()
        let pairs = eligibleProjectArtifactPairs()
        guard !toolsIx.isEmpty || !pairs.isEmpty else { return }

        let allOn =
            toolsIx.allSatisfy { store.devTools[$0].isSelected } &&
            pairs.allSatisfy { store.projectGroups[$0.0].artifacts[$0.1].isSelected }

        let newVal = !allOn
        for ti in toolsIx {
            var tools = store.devTools
            tools[ti].isSelected = newVal
            store.devTools = tools
        }
        for p in pairs {
            store.setProjectArtifactSelected(groupIndex: p.0, artifactIndex: p.1, isSelected: newVal)
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
            .foregroundStyle(Color.accentColor)
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

    private func symbolIcon(_ systemName: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        return NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
            ?? NSWorkspace.shared.icon(forFileType: "public.folder")
    }
}
