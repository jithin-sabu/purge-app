import AppKit
import SwiftUI

struct AppCachesView: View {
    @EnvironmentObject private var store: PurgeStore
    @Binding var items: [CacheItem]
    let isLoading: Bool
    let onScan: () -> Void

    @AppStorage("filter.appCaches") private var filterRaw: String = SafetyFilter.all.rawValue
    @AppStorage("sort.appCaches") private var sortRaw: String = SortOption.sizeDesc.rawValue
    /// Last completed scan snapshot; used for chip counts during an in-flight rescan so counts don't collapse to zero.
    @State private var displayedItems: [CacheItem] = []

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

    private var visibleIndices: [Int] {
        items.indices.filter { currentSafetyFilter.matches(items[$0].safetyInfo) }
    }

    /// Chip aggregates during scan use the last finished scan so the chip row doesn't resize from 0 mid-scan.
    private var itemsForChipCounts: [CacheItem] {
        isLoading ? displayedItems : items
    }

    private var eligibleSelectIndices: [Int] {
        visibleIndices
    }

    private func sortedVisibleIndices() -> [Int] {
        let base = visibleIndices
        switch SortOption(rawValue: sortRaw) ?? .sizeDesc {
        case .sizeDesc:
            return base.sorted { items[$0].sizeBytes > items[$1].sizeBytes }
        case .sizeAsc:
            return base.sorted { items[$0].sizeBytes < items[$1].sizeBytes }
        case .dateNewest:
            return base.sorted { items[$0].lastModified > items[$1].lastModified }
        case .dateOldest:
            return base.sorted { items[$0].lastModified < items[$1].lastModified }
        case .nameAZ:
            return base.sorted { items[$0].appName.localizedCaseInsensitiveCompare(items[$1].appName) == .orderedAscending }
        }
    }

    private var selectAllState: SelectAllTriState {
        let ix = eligibleSelectIndices
        guard !ix.isEmpty else { return .none }
        let selected = ix.filter { items[$0].isSelected }
        if selected.count == ix.count { return .all }
        if selected.isEmpty { return .none }
        return .mixed
    }

    private var chipCounts: [SafetyFilter: Int] {
        let source = itemsForChipCounts
        var d: [SafetyFilter: Int] = [:]
        for filter in SafetyFilter.allCases {
            d[filter] = source.filter { filter.matches($0.safetyInfo) }.count
        }
        return d
    }

    private var selectedInScopeCount: Int {
        eligibleSelectIndices.filter { items[$0].isSelected }.count
    }

    private var selectedInScopeBytes: Int64 {
        eligibleSelectIndices
            .filter { items[$0].isSelected }
            .reduce(Int64(0)) { sum, index in sum + items[index].sizeBytes }
    }

    private var displayableItemCount: Int {
        items.filter { SafetyFilter.all.matches($0.safetyInfo) }.count
    }

    private var totalSize: Int64 {
        items.filter { SafetyFilter.all.matches($0.safetyInfo) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var visibleTotalSize: Int64 {
        if currentSafetyFilter == .safe {
            return store.safeCleanupSummary.appCacheBytes
        }
        return visibleIndices.reduce(Int64(0)) { sum, index in sum + items[index].sizeBytes }
    }

    private var pageSubtitle: String {
        if isLoading {
            return "Scanning application cache folders."
        }
        return "\(displayableItemCount) items · \(formatBytes(totalSize)) recoverable"
    }

    private var skeletonRowCount: Int {
        SkeletonRowCount.clamped(displayedItems.count)
    }

    private var showsListContent: Bool {
        !isLoading && !items.isEmpty && !visibleIndices.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            AppSectionPageHeader(title: "App Caches", subtitle: pageSubtitle) {
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
                        await store.presentDeletionSheetResolvingGit(candidates: store.selectedGeneralDeletionCandidates)
                    }
                },
                useStackedLayout: true,
                showsControlsRow: false
            )
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
            .disabled(isLoading)

            HStack {
                TriStateCheckbox(title: "Select All", state: selectAllState) {
                    toggleSelectAll()
                }
                .fixedSize()
                .disabled(isLoading || eligibleSelectIndices.isEmpty)
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
                    if items.isEmpty {
                        emptyState
                    } else if visibleIndices.isEmpty {
                        emptyFilterState
                    } else {
                        cacheResultsList
                    }
                }

                if store.isDeleting && showsListContent {
                    CleaningOverlay()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScanStatusBar(
                isLoading: isLoading,
                visibleCount: visibleIndices.count,
                totalCount: displayableItemCount,
                isFiltered: currentSafetyFilter != .all,
                visibleBytes: visibleTotalSize,
                totalBytes: totalSize,
                selectedCount: selectedInScopeCount,
                selectedBytes: selectedInScopeBytes
            )
        }
        .background(AppStyle.canvas)
        .onAppear {
            if !isLoading {
                displayedItems = items
            }
        }
        .onChange(of: isLoading) { scanning in
            if !scanning {
                displayedItems = items
            }
        }
        .onChange(of: items) { newItems in
            if !isLoading {
                displayedItems = newItems
            }
        }
    }

    private func reinstallDisplay(for item: CacheItem) -> ReinstallSafetyStatus? {
        guard item.reinstallSafety != .notApplicable else { return nil }
        return item.reinstallSafety
    }

    private var cacheResultsList: some View {
        List {
            ForEach(sortedVisibleIndices(), id: \.self) { index in
                let item = items[index]
                let itemID = item.id
                ScanResultRow(
                    isSelected: $items[index].isSelected,
                    primaryLabel: item.appName,
                    formattedSize: item.formattedSize,
                    safetyInfo: item.safetyInfo,
                    brandIcon: .cacheItem(item),
                    onRequestUnknownDelete: item.safetyInfo.level == .unknown
                        ? { store.requestUnknownDeletion(candidates: PurgeStore.DeletionCandidate.deletionCandidates(forCache: item)) }
                        : nil,
                    detailCaption: nil,
                    reinstallSafety: reinstallDisplay(for: item),
                    showUncommittedRepoChanges: item.gitStatus == .dirty,
                    onRecategorize: { store.recategorizeCacheItem(id: itemID) },
                    onMarkSafe: { store.markCacheItem(id: itemID, as: .safe) },
                    onMarkMedium: { store.markCacheItem(id: itemID, as: .medium) },
                    onMarkDanger: { store.markCacheItem(id: itemID, as: .danger) },
                    onResetToAutomatic: { store.resetCacheItemToAutomatic(id: itemID) },
                    isUserOverride: item.locations.contains {
                        store.userOverridePaths.contains($0.path.standardizedFileURL.path)
                    },
                    isMetadataPending: false
                )
                .listRowInsets(ScanListRowInsets.standard)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(AppStyle.canvas)
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

    private func toggleSelectAll() {
        let ix = eligibleSelectIndices
        guard !ix.isEmpty else { return }
        let allOn = ix.allSatisfy { items[$0].isSelected }
        let newVal = !allOn
        for i in ix {
            items[i].isSelected = newVal
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("No Caches Found")
                .font(.title3)
            Text("Run a scan to inspect recoverable application caches.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

#Preview("App Caches — scanning") {
    AppCachesView(
        items: .constant([]),
        isLoading: true,
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
        onScan: {}
    )
    .environmentObject(PurgeStore())
    .frame(width: 720, height: 560)
}
