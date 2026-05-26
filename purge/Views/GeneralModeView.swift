import AppKit
import SwiftUI

struct AppCachesView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var items: [CacheItem]
    let isLoading: Bool
    let scanPhase: PurgeStore.ScanPhase
    let onScan: () -> Void

    @AppStorage("filter.appCaches") private var filterRaw: String = SafetyFilter.all.rawValue
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

    private var visibleIndices: [Int] {
        items.indices.filter {
            currentSafetyFilter.matches(items[$0].safetyInfo) && !isVisuallyRemovedBySafeCleanup(items[$0])
        }
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
        var d: [SafetyFilter: Int] = [:]
        for filter in SafetyFilter.allCases {
            d[filter] = items.filter { filter.matches($0.safetyInfo) }.count
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
        return visibleIndices.reduce(Int64(0)) { sum, index in sum + items[index].sizeBytes }
    }

    private var subtitleItemCount: Int {
        currentSafetyFilter == .all ? displayableItemCount : visibleIndices.count
    }

    private var subtitleTotalSize: Int64 {
        currentSafetyFilter == .all ? totalSize : visibleTotalSize
    }

    private var subtitleItemLabel: String {
        subtitleItemCount == 1 ? "item" : "items"
    }

    private var pageSubtitle: String {
        return "\(subtitleItemCount) \(subtitleItemLabel) · \(formatBytes(subtitleTotalSize)) recoverable"
    }

    private var showsListContent: Bool {
        !items.isEmpty && !visibleIndices.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            AppSectionPageHeader(title: "App Caches", subtitle: pageSubtitle) {
                AppScanCleanActions(onScan: onScan, scanPhase: scanPhase)
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

            HStack {
                TriStateCheckbox(title: "Select All", state: selectAllState) {
                    toggleSelectAll()
                }
                .fixedSize()
                .disabled(eligibleSelectIndices.isEmpty)
                Spacer()
                AppSortMenu(selection: sortOptionBinding)
            }
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
            .padding(.vertical, AppStyle.Spacing.xSmall)

            ZStack {
                if items.isEmpty {
                    if isLoading {
                        scanningPlaceholder
                    } else {
                        emptyState
                    }
                } else if visibleIndices.isEmpty {
                    if isLoading {
                        scanningPlaceholder
                    } else {
                        emptyFilterState
                    }
                } else {
                    cacheResultsList
                }

                if store.isDeleting && showsListContent && !store.isInteractiveSafeCleanupInProgress {
                    CleaningOverlay()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppStyle.canvas)
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
                    isMetadataPending: store.cacheItemHasPendingSize(item)
                )
                .listRowInsets(ScanListRowInsets.standard)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .transition(rowInsertionTransition)
            }

            ScanListBottomSpacer()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppStyle.canvas)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.interactiveSafeCleanupRemovedPaths)
        .animation(rowInsertionAnimation, value: items.map(\.id))
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

    private func isVisuallyRemovedBySafeCleanup(_ item: CacheItem) -> Bool {
        let rowPaths = Set(item.locations.map { $0.path.standardizedFileURL.path })
        let targetedPaths = rowPaths.intersection(store.interactiveSafeCleanupTargetPaths)
        guard !targetedPaths.isEmpty else { return false }
        return targetedPaths.isSubset(of: store.interactiveSafeCleanupRemovedPaths)
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
