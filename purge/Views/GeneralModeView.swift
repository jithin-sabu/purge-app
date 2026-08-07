import AppKit
import SwiftUI

struct AppCachesView<PageHeader: View>: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var items: [CacheItem]
    let isLoading: Bool
    let scanPhase: PurgeStore.ScanPhase
    let onScan: () -> Void
    var showsPageHeader = true
    /// When true, the parent supplies the page header and the list uses `safeAreaBar` scroll-edge blur (macOS 26+).
    var usesExternalScrollContainer = false
    private let pageHeader: () -> PageHeader

    init(
        items: Binding<[CacheItem]>,
        isLoading: Bool,
        scanPhase: PurgeStore.ScanPhase,
        onScan: @escaping () -> Void,
        showsPageHeader: Bool = true,
        usesExternalScrollContainer: Bool = false,
        @ViewBuilder pageHeader: @escaping () -> PageHeader
    ) {
        _items = items
        self.isLoading = isLoading
        self.scanPhase = scanPhase
        self.onScan = onScan
        self.showsPageHeader = showsPageHeader
        self.usesExternalScrollContainer = usesExternalScrollContainer
        self.pageHeader = pageHeader
    }

    @AppStorage("filter.appCaches") private var filterRaw: String = SafetyFilter.safe.rawValue
    @AppStorage("sort.appCaches") private var sortRaw: String = SortOption.sizeDesc.rawValue

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

    /// Everything the render needs that is derived from `items`, computed in one pass.
    ///
    /// Previously each of these was a computed property that re-derived `visibleIndices`
    /// from scratch, and eight separate call sites read one of them per render — so a
    /// single body evaluation walked the full item list eight times over. Profiling the
    /// tab-switch stall showed `visibleIndices` reached from `showsListContent`,
    /// `selectAllState`, `selectedInScopeCount`, `selectedInScopeBytes`,
    /// `sortedVisibleIndices()`, and the select-all row, all in the same pass.
    ///
    /// Selection-dependent numbers deliberately stay out of here: they are read inside
    /// `ScanSelectionScope`, which re-renders on selection changes *without* re-rendering
    /// the container, and folding them in would defeat that.
    struct ListPlan {
        var sortedVisibleIndices: [Int] = []
        var visibleCount = 0
        var visibleTotalBytes: Int64 = 0
        var displayableCount = 0
        var displayableTotalBytes: Int64 = 0
        var chipCounts: [SafetyFilter: Int] = [:]

        var isEmpty: Bool { sortedVisibleIndices.isEmpty }
    }

    private func makeListPlan() -> ListPlan {
        var plan = ListPlan()
        guard !items.isEmpty else { return plan }

        let filter = currentSafetyFilter
        let hidesRemovedRows = !store.interactiveSafeCleanupTargetPaths.isEmpty
        var chips: [SafetyFilter: Int] = [:]
        var visible: [Int] = []
        visible.reserveCapacity(items.count)

        for index in items.indices {
            let item = items[index]
            let info = item.safetyInfo

            for candidate in SafetyFilter.allCases where candidate.matches(info) {
                chips[candidate, default: 0] += 1
            }

            if SafetyFilter.all.matches(info) {
                plan.displayableCount += 1
                plan.displayableTotalBytes += item.sizeBytes
            }

            guard filter.matches(info) else { continue }
            if hidesRemovedRows, store.isVisuallyRemovedBySafeCleanup(item) { continue }
            visible.append(index)
            plan.visibleTotalBytes += item.sizeBytes
        }

        plan.chipCounts = chips
        plan.visibleCount = visible.count

        switch SortOption(rawValue: sortRaw) ?? .sizeDesc {
        case .sizeDesc:
            visible.sort { items[$0].sizeBytes > items[$1].sizeBytes }
        case .sizeAsc:
            visible.sort { items[$0].sizeBytes < items[$1].sizeBytes }
        case .dateNewest:
            visible.sort { items[$0].lastModified > items[$1].lastModified }
        case .dateOldest:
            visible.sort { items[$0].lastModified < items[$1].lastModified }
        case .nameAZ:
            visible.sort { items[$0].appName.localizedCaseInsensitiveCompare(items[$1].appName) == .orderedAscending }
        }
        plan.sortedVisibleIndices = visible
        return plan
    }

    private func selectAllState(plan: ListPlan) -> SelectAllTriState {
        let ix = plan.sortedVisibleIndices
        guard !ix.isEmpty else { return .none }
        let selectedIDs = store.scanSelection.cacheIDs
        var selected = 0
        for index in ix where selectedIDs.contains(items[index].id) { selected += 1 }
        if selected == ix.count { return .all }
        if selected == 0 { return .none }
        return .mixed
    }

    private func selectedInScope(plan: ListPlan) -> (count: Int, bytes: Int64) {
        let selectedIDs = store.scanSelection.cacheIDs
        var count = 0
        var bytes: Int64 = 0
        for index in plan.sortedVisibleIndices where selectedIDs.contains(items[index].id) {
            count += 1
            bytes += items[index].sizeBytes
        }
        return (count, bytes)
    }

    private func pageSubtitle(plan: ListPlan) -> String {
        let count = currentSafetyFilter == .all ? plan.displayableCount : plan.visibleCount
        let bytes = currentSafetyFilter == .all ? plan.displayableTotalBytes : plan.visibleTotalBytes
        return "\(count) \(count == 1 ? "item" : "items") · \(formatBytes(bytes)) recoverable"
    }

    var body: some View {
        let plan = makeListPlan()
        return Group {
            if usesExternalScrollContainer {
                externalScrollBody(plan: plan)
            } else {
                standardBody(plan: plan)
            }
        }
        .background(AppColors.bgBase)
    }

    private func standardBody(plan: ListPlan) -> some View {
        VStack(spacing: 0) {
            if showsPageHeader {
                AppSectionPageHeader(title: "App Caches", subtitle: pageSubtitle(plan: plan)) {
                    AppScanCleanActions(onScan: onScan, scanPhase: scanPhase)
                }
            }

            scanControlsChrome(plan: plan)
            scanListStack(plan: plan)
        }
    }

    @ViewBuilder
    private func externalScrollBody(plan: ListPlan) -> some View {
        if #available(macOS 26.0, *) {
            VStack(spacing: 0) {
                filterToolbarChrome(plan: plan)

                if !items.isEmpty && !plan.isEmpty {
                    ZStack {
                        cacheResultsList(plan: plan)
                            .scanTabSoftScrollEdge { selectAllRowChrome(plan: plan) }

                        if store.isDeleting && !store.isInteractiveSafeCleanupInProgress && store.manualDeletionSession == nil {
                            CleaningOverlay()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        selectAllRowChrome(plan: plan)
                        scanListStack(plan: plan)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        } else {
            standardBody(plan: plan)
        }
    }

    /// Filter chips — fixed above the scroll edge; page title lives in the parent column header.
    private func filterToolbarChrome(plan: ListPlan) -> some View {
        // Scoped to scanSelection so the selected count/clean button update on a
        // toggle without re-rendering GeneralModeView (which reverts list scroll).
        ScanSelectionScope(selection: store.scanSelection, isSelected: { _ in false }) { _ in
            let scope = selectedInScope(plan: plan)
            FilterSortToolbar(
                safetyFilter: safetyFilterBinding,
                sortOption: sortOptionBinding,
                chipCounts: plan.chipCounts,
                selectedInScopeCount: scope.count,
                selectedInScopeBytes: scope.bytes,
                isDeleting: store.isDeleting,
                onCleanSelected: {
                    Task {
                        await store.presentDeletionSheetResolvingGit(candidates: store.selectedGeneralDeletionCandidates)
                    }
                },
                useStackedLayout: true,
                showsControlsRow: false
            )
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
    }

    /// Bottom edge of the blur zone — list rows fade under this row only.
    private func selectAllRowChrome(plan: ListPlan) -> some View {
        // Scoped so the tri-state updates on selection without re-rendering the
        // container (which would revert list scroll).
        ScanSelectionScope(selection: store.scanSelection, isSelected: { _ in false }) { _ in
            HStack(alignment: .bottom) {
                TriStateCheckbox(title: "Select All", state: selectAllState(plan: plan)) {
                    toggleSelectAll(plan: plan)
                }
                .fixedSize()
                .disabled(plan.isEmpty)
                Spacer()
                AppSortMenu(selection: sortOptionBinding)
            }
            .scanTabSelectAllRowLayout()
        }
    }

    private func scanControlsChrome(plan: ListPlan) -> some View {
        VStack(spacing: 0) {
            filterToolbarChrome(plan: plan)
            selectAllRowChrome(plan: plan)
        }
    }

    private func scanListStack(plan: ListPlan) -> some View {
        ZStack {
            scanListOrPlaceholder(plan: plan)

            if store.isDeleting && !items.isEmpty && !plan.isEmpty
                && !store.isInteractiveSafeCleanupInProgress
                && store.manualDeletionSession == nil {
                CleaningOverlay()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func scanListOrPlaceholder(plan: ListPlan) -> some View {
        if items.isEmpty {
            if isLoading {
                scanningPlaceholder
            } else {
                emptyState
            }
        } else if plan.isEmpty {
            if isLoading {
                scanningPlaceholder
            } else {
                emptyFilterState
            }
        } else {
            cacheResultsList(plan: plan)
        }
    }

    private func reinstallDisplay(for item: CacheItem) -> ReinstallSafetyStatus? {
        guard item.reinstallSafety != .notApplicable else { return nil }
        return item.reinstallSafety
    }

    /// Stable anchor pinned to the very top of the results list so a fresh scan or
    /// first appearance can reset scroll position to the first row.
    private static var topAnchorID: String { "app-caches-top" }

    private func cacheResultsList(plan: ListPlan) -> some View {
        ScrollViewReader { proxy in
            cacheResultsListContent(plan: plan)
                .onChange(of: scanPhase) { newPhase in
                    // A new scan just finished populating the list.
                    guard newPhase == .completed else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
        }
    }

    private func cacheResultsListContent(plan: ListPlan) -> some View {
        List {
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .id(Self.topAnchorID)

            ForEach(plan.sortedVisibleIndices, id: \.self) { index in
                let item = items[index]
                let itemID = item.id
                // Scope observes scanSelection so a toggle re-renders only the row,
                // not the list container (which would revert scroll).
                ScanSelectionScope(
                    selection: store.scanSelection,
                    isSelected: { $0.cacheIDs.contains(itemID) }
                ) { selected in
                    ScanResultRow(
                        isSelected: selected,
                        onToggle: {
                            store.setCacheSelected(
                                id: itemID,
                                isSelected: !store.scanSelection.cacheIDs.contains(itemID)
                            )
                        },
                        primaryLabel: item.appName,
                        formattedSize: item.formattedSize,
                        safetyInfo: item.safetyInfo,
                        brandIcon: .cacheItem(item),
                        detailCaption: nil,
                        reinstallSafety: reinstallDisplay(for: item),
                        showUncommittedRepoChanges: item.gitStatus == .dirty,
                        onResetToAutomatic: { store.resetCacheItemToAutomatic(id: itemID) },
                        onExcludeFromScans: { store.excludeFromScans(item) },
                        revealLocations: {
                            item.locations.map {
                                ScanRowLocation(url: $0.path, sizeBytes: $0.sizeBytes)
                            }
                        },
                        // `standardizedPaths` is precomputed on the item; deriving it here
                        // meant a filesystem stat per location, per row, per render.
                        isUserOverride: item.standardizedPaths.contains {
                            store.userOverridePaths.contains($0)
                        },
                        isMetadataPending: store.cacheItemHasPendingSize(item)
                    )
                }
                .listRowInsets(ScanListRowInsets.standard)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .transition(rowInsertionTransition)
            }

            ScanListBottomSpacer()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.bgBase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.interactiveSafeCleanupRemovedPaths)
        // O(1) stand-in for "the row set changed". `items.map(\.id)` allocated and then
        // compared an array of every row's id string on every body evaluation.
        .animation(rowInsertionAnimation, value: store.cacheItemsRevision)
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

    private var cleaningRowRemovalTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .identity,
                removal: .opacity.combined(with: .move(edge: .trailing))
            )
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

    private func toggleSelectAll(plan: ListPlan) {
        let ix = plan.sortedVisibleIndices
        guard !ix.isEmpty else { return }
        let ids = ix.map { items[$0].id }
        let allOn = ids.allSatisfy { store.scanSelection.cacheIDs.contains($0) }
        store.setAllCachesSelected(!allOn, ids: ids)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(scanPhase == .completed ? "Your Mac is looking clean." : "No Caches Found")
                .font(.title3)
            Text(scanPhase == .completed ? "Check back later." : "Run a scan to inspect recoverable application caches.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Scanning app caches")
    }

}

extension AppCachesView where PageHeader == EmptyView {
    init(
        items: Binding<[CacheItem]>,
        isLoading: Bool,
        scanPhase: PurgeStore.ScanPhase,
        onScan: @escaping () -> Void,
        showsPageHeader: Bool = true,
        usesExternalScrollContainer: Bool = false
    ) {
        self.init(
            items: items,
            isLoading: isLoading,
            scanPhase: scanPhase,
            onScan: onScan,
            showsPageHeader: showsPageHeader,
            usesExternalScrollContainer: usesExternalScrollContainer,
            pageHeader: { EmptyView() }
        )
    }
}

#Preview("App Caches — scanning") {
    AppCachesView(
        items: .constant([]),
        isLoading: true,
        scanPhase: .scanning,
        onScan: {}
    )
    .environmentObject(PurgeStore())
    .frame(width: 720, height: 560)
}

#Preview("App Caches — loaded") {
    AppCachesView(
        items: .constant([
            CacheItem(
                definitionKey: "safari",
                location: CacheLocation(
                    path: URL(fileURLWithPath: "/tmp/Safari"),
                    sizeBytes: 420_000_000,
                    lastModified: Date(),
                    folderName: "com.apple.Safari"
                ),
                appName: "Safari",
                safetyInfo: SafetyInfo(
                    level: .safe,
                    headline: "Safari",
                    explanation: "Cache rebuilds on launch.",
                    recoverySteps: "",
                    reinstallCommand: nil
                ),
                reinstallSafety: .notApplicable,
                gitStatus: .clean
            )
        ]),
        isLoading: false,
        scanPhase: .idle,
        onScan: {}
    )
    .environmentObject(PurgeStore())
    .frame(width: 720, height: 560)
}
