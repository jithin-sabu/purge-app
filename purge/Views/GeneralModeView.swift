import AppKit
import SwiftUI

struct AppCachesView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only the leftover macOS update files row reads this. It changes when the user
    /// turns secure removal on, which is rare, so observing it here costs nothing.
    @ObservedObject private var helperPrefs = PrivilegedHelperPreferenceStore.shared
    @Binding var items: [CacheItem]
    let isLoading: Bool
    let scanPhase: PurgeStore.ScanPhase
    /// When true, the parent supplies the page header and this view renders only its
    /// controls and scrolling list.
    var usesExternalScrollContainer = false

    init(
        items: Binding<[CacheItem]>,
        isLoading: Bool,
        scanPhase: PurgeStore.ScanPhase,
        usesExternalScrollContainer: Bool = false
    ) {
        _items = items
        self.isLoading = isLoading
        self.scanPhase = scanPhase
        self.usesExternalScrollContainer = usesExternalScrollContainer
    }

    @AppStorage("filter.appCaches") private var filterRaw: String = SafetyFilter.safe.rawValue
    @AppStorage("sort.appCaches") private var sortRaw: String = SortOption.sizeDesc.rawValue

    /// Safe while the Overview has this tab open for a visit, the saved filter otherwise.
    private var currentSafetyFilter: SafetyFilter {
        store.safetyFilter(for: .appCaches, saved: SafetyFilter(rawValue: filterRaw) ?? .all)
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
        /// Live rows only: what Select All, the selected count and Clean work on.
        var sortedVisibleIndices: [Int] = []
        /// Live rows and rows from the last scan (#283) in one sorted list, for drawing.
        var sortedEntries: [Entry] = []
        /// The saved rows `sortedEntries` points into, captured with the plan.
        var savedItems: [CacheItem] = []
        var chipCounts: [SafetyFilter: Int] = [:]

        var isEmpty: Bool { sortedEntries.isEmpty }
    }

    /// One drawn row. Keyed by the item's id, so a saved row the scan finds again
    /// turns live in place instead of being replaced.
    struct Entry: Hashable {
        let id: String
        let index: Int
        let isFromLastScan: Bool
    }

    private func makeListPlan() -> ListPlan {
        var plan = ListPlan()
        let saved = store.lastScanRows.cacheItems
        guard !items.isEmpty || !saved.isEmpty else { return plan }

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

            guard filter.matches(info) else { continue }
            if hidesRemovedRows, store.isVisuallyRemovedBySafeCleanup(item) { continue }
            visible.append(index)
        }

        // Rows from the last scan the live list doesn't have yet. They count in the
        // chips, so a filter never looks empty while they show, but not in the totals.
        var entries = visible.map { Entry(id: items[$0].id, index: $0, isFromLastScan: false) }
        if !saved.isEmpty {
            let liveIDs = Set(items.map(\.id))
            for index in saved.indices where !liveIDs.contains(saved[index].id) {
                let info = saved[index].safetyInfo
                for candidate in SafetyFilter.allCases where candidate.matches(info) {
                    chips[candidate, default: 0] += 1
                }
                guard filter.matches(info) else { continue }
                entries.append(Entry(id: saved[index].id, index: index, isFromLastScan: true))
            }
            plan.savedItems = saved
        }
        plan.chipCounts = chips

        let item: (Entry) -> CacheItem = { $0.isFromLastScan ? saved[$0.index] : items[$0.index] }
        switch SortOption(rawValue: sortRaw) ?? .sizeDesc {
        case .sizeDesc:
            entries.sort { item($0).sizeBytes > item($1).sizeBytes }
        case .sizeAsc:
            entries.sort { item($0).sizeBytes < item($1).sizeBytes }
        case .dateNewest:
            entries.sort { item($0).lastModified > item($1).lastModified }
        case .dateOldest:
            entries.sort { item($0).lastModified < item($1).lastModified }
        case .nameAZ:
            entries.sort { item($0).appName.localizedCaseInsensitiveCompare(item($1).appName) == .orderedAscending }
        }
        plan.sortedEntries = entries
        plan.sortedVisibleIndices = entries.filter { !$0.isFromLastScan }.map(\.index)
        return plan
    }

    private func selectAll(plan: ListPlan) -> SafeFirstSelectAll<String> {
        let selectedIDs = store.scanSelection.cacheIDs
        let entries = plan.sortedVisibleIndices.map { index in
            let item = items[index]
            return SafeFirstSelectAll<String>.Entry(
                key: item.id,
                isSafe: item.safetyInfo.level == .safe,
                isSelected: selectedIDs.contains(item.id),
                bytes: item.sizeBytes
            )
        }
        return SafeFirstSelectAll(entries: entries, filter: currentSafetyFilter)
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
        .background(AppColors.surfaceBase)
    }

    private func standardBody(plan: ListPlan) -> some View {
        VStack(spacing: 0) {
            scanControlsChrome(plan: plan)
            scanListStack(plan: plan)
        }
    }

    private func externalScrollBody(plan: ListPlan) -> some View {
        // Controls and the Select All row sit above the list as opaque chrome; the
        // list cuts off cleanly at its own edge with no scroll-edge blur, matching
        // the App Uninstaller tab.
        VStack(spacing: 0) {
            filterToolbarChrome(plan: plan)
            selectAllRowChrome(plan: plan)
            scanListStack(plan: plan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Filter chips — fixed above the scroll edge; page title lives in the parent column header.
    private func filterToolbarChrome(plan: ListPlan) -> some View {
        SafetyFilterChipRow(safetyFilter: safetyFilterBinding, chipCounts: plan.chipCounts)
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
    }

    /// Bottom edge of the blur zone — list rows fade under this row only.
    private func selectAllRowChrome(plan: ListPlan) -> some View {
        // Scoped so the tri-state updates on selection without re-rendering the
        // container (which would revert list scroll).
        ScanSelectionScope(selection: store.scanSelection, isSelected: { _ in false }) { _ in
            HStack(alignment: .bottom) {
                SafeFirstSelectAllControl(model: selectAll(plan: plan)) { change in
                    store.setAllCachesSelected(true, ids: change.select)
                    store.setAllCachesSelected(false, ids: change.deselect)
                }
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
        if items.isEmpty && store.lastScanRows.cacheItems.isEmpty {
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

    /// Leftover macOS update files move only through the helper (#127). While it is
    /// off, say so on the row; cleaning it then offers the one-time setup.
    private func secureRemovalCaption(for item: CacheItem) -> String? {
        guard item.bundleID == CacheDiscoveryPaths.macOSInstallDataKey, !helperPrefs.isEnabled else { return nil }
        return String(localized: "Needs secure removal")
    }

    private func reinstallDisplay(for item: CacheItem) -> ReinstallSafetyStatus? {
        guard item.reinstallSafety != .notApplicable else { return nil }
        return item.reinstallSafety
    }

    private func cacheResultsList(plan: ListPlan) -> some View {
        ScrollViewReader { proxy in
            cacheResultsListContent(plan: plan)
                .onChange(of: scanPhase) { newPhase in
                    // A new scan just finished populating the list.
                    guard newPhase == .completed, let firstIndex = plan.sortedVisibleIndices.first else { return }
                    let firstItemID = items[firstIndex].id
                    DispatchQueue.main.async {
                        proxy.scrollTo(firstItemID, anchor: .top)
                    }
                }
        }
    }

    private func cacheResultsListContent(plan: ListPlan) -> some View {
        List {
            ForEach(plan.sortedEntries, id: \.id) { entry in
                if entry.isFromLastScan {
                    lastScanRow(plan.savedItems[entry.index])
                } else {
                    liveRow(items[entry.index])
                }
            }

            ScanListBottomSpacer()
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(AppColors.surfaceBase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.interactiveSafeCleanupRemovedPaths)
        // O(1) stand-in for "the row set changed". `items.map(\.id)` allocated and then
        // compared an array of every row's id string on every body evaluation.
        .animation(rowInsertionAnimation, value: store.cacheItemsRevision)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: plan.savedItems.count)
    }

    /// A row from the last scan (#283): the same row, read only, until the scan
    /// finds it again. Show in Finder is the one thing it offers.
    private func lastScanRow(_ item: CacheItem) -> some View {
        ScanResultRow(
            isSelected: false,
            primaryLabel: CacheHeadline.localized(item.appName, cacheFolder: item.path.lastPathComponent, appFolder: item.bundleID),
            formattedSize: item.formattedSize,
            safetyInfo: item.safetyInfo,
            brandIcon: .cacheItem(item),
            reinstallSafety: reinstallDisplay(for: item),
            showUncommittedRepoChanges: item.gitStatus == .dirty,
            revealLocations: {
                item.locations.map {
                    ScanRowLocation(url: $0.path, sizeBytes: $0.sizeBytes)
                }
            },
            isFromLastScan: true
        )
        .id(item.id)
        .listRowInsets(ScanListRowInsets.standard)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .transition(rowInsertionTransition)
    }

    @ViewBuilder
    private func liveRow(_ item: CacheItem) -> some View {
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
                primaryLabel: CacheHeadline.localized(item.appName, cacheFolder: item.path.lastPathComponent, appFolder: item.bundleID),
                formattedSize: item.formattedSize,
                safetyInfo: item.safetyInfo,
                brandIcon: .cacheItem(item),
                detailCaption: secureRemovalCaption(for: item),
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
        .id(itemID)
        .listRowInsets(ScanListRowInsets.standard)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .transition(rowInsertionTransition)
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
        VStack(spacing: AppStyle.Spacing.xxSmall) {
            Text("Nothing here.")
                .font(AppStyle.Typography.headline)
            Text("No items match this filter.")
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: AppStyle.Spacing.small) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 38))
                .foregroundStyle(AppColors.textSecondary)
            Text(scanPhase == .completed ? LocalizedStringKey("Your Mac is looking clean.") : LocalizedStringKey("No Caches Found"))
                .font(AppStyle.Typography.sectionTitle.weight(.regular))
            Text(scanPhase == .completed ? LocalizedStringKey("Check back later.") : LocalizedStringKey("Run a scan to inspect recoverable application caches."))
                .foregroundStyle(AppColors.textSecondary)
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
        scanPhase: .scanning
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
                    headline: String(localized: "Safari"),
                    explanation: String(localized: "Cache rebuilds on launch."),
                    recoverySteps: "",
                    reinstallCommand: nil
                ),
                reinstallSafety: .notApplicable,
                gitStatus: .clean
            )
        ]),
        isLoading: false,
        scanPhase: .idle
    )
    .environmentObject(PurgeStore())
    .frame(width: 720, height: 560)
}
