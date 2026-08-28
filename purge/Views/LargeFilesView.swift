import AppKit
import SwiftUI

struct LargeFilesView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isLoading: Bool
    let onScan: () -> Void
    /// Owned by the parent rather than held as local `@State` so the page header's
    /// "N files · X GB to review" subtitle — which `ContentView` renders outside this
    /// view — counts the same rows the list is actually showing. With the query
    /// private to this view the header kept advertising the full unfiltered scan.
    @Binding var searchQuery: String
    var showsPageHeader = true
    var usesExternalScrollContainer = false

    @AppStorage(LargeFileFilterDefaults.categoryKey) private var categoryFilterRaw = LargeFileCategoryFilter.all
    @AppStorage("sort.largeFiles") private var sortRaw: String = SortOption.sizeDesc.rawValue
    @AppStorage(LargeFileSizeThreshold.userDefaultsKey) private var minSizeMB: Int = LargeFileSizeThreshold.defaultOption.rawValue
    @AppStorage(LargeFileAgeThreshold.userDefaultsKey) private var minAgeDays: Int = LargeFileAgeThreshold.defaultOption.rawValue

    /// Bumped when a scan finishes to reset the results List's identity (and thus
    /// its scroll to the top). Kept out of selection so toggles never reset scroll.
    @State private var scanGeneration = 0

    /// Mirror of `store.largeFileDuplicates.index`, kept as local state rather
    /// than by `@ObservedObject`-ing the index object: this view owns the chip
    /// counts and the filter, so it has to re-render when groups land — but it
    /// must *not* also re-render on every `isChecking` flip, because a re-render
    /// of this view reverts the results List's scroll position. The store assigns
    /// the index exactly once per pass, so this fires exactly once.
    @State private var duplicateIndex: DuplicateIndex = .empty

    /// Pseudo-category shared with the real category chips via `categoryFilterRaw`,
    /// so chip selection stays single-select without a second piece of state.
    private static let duplicatesFilterID = LargeFileCategoryFilter.duplicates

    private var currentSort: SortOption {
        SortOption(rawValue: sortRaw) ?? .sizeDesc
    }

    private var sortOptionBinding: Binding<SortOption> {
        Binding(
            get: { SortOption(rawValue: sortRaw) ?? .sizeDesc },
            set: { sortRaw = $0.rawValue }
        )
    }

    private var sizeThreshold: LargeFileSizeThreshold {
        LargeFileSizeThreshold(rawValue: minSizeMB) ?? .defaultOption
    }

    private var ageThreshold: LargeFileAgeThreshold {
        LargeFileAgeThreshold(rawValue: minAgeDays) ?? .defaultOption
    }

    /// Which categories get a chip. Intentionally keyed off the full scan result and
    /// not the query, so chips don't appear and vanish under the pointer as the user
    /// types — a chip that reads 0 is steadier than a row that reflows every keystroke.
    private var availableCategories: [LargeFileCategory] {
        let present = Set(store.largeFiles.map(\.category))
        return LargeFileCategory.allCases.filter { present.contains($0) }
    }

    /// Everything matching the query, before the category chip narrows it further.
    /// This is what the chip counts are drawn from.
    private var searchMatches: [LargeFile] {
        store.largeFiles.filter { $0.matches(searchQuery: searchQuery) }
    }

    private var hasActiveQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the Duplicates chip is the active filter *and* has something to
    /// show. The two come apart within a session: a fresh Scan empties the index
    /// while the chip is still selected, and without this guard the list would
    /// show nothing until the duplicate pass finished. Across launches the filter
    /// is reset in `LargeFileFilterDefaults.register()` instead.
    private var isDuplicatesFilterActive: Bool {
        LargeFileCategoryFilter.isDuplicatesActive(
            rawValue: categoryFilterRaw, duplicates: duplicateIndex
        )
    }

    /// The groups the list draws as containers, each holding its copies.
    ///
    /// The sort menu reorders whole groups here rather than individual rows —
    /// copies stay together either way, since splitting them up is the thing the
    /// grouping exists to prevent.
    private var duplicateSections: [LargeFileCategoryFilter.Section] {
        let sections = LargeFileCategoryFilter.duplicateSections(
            in: store.largeFiles, query: searchQuery, duplicates: duplicateIndex
        )
        let files = store.largeFiles

        // "Newest"/"Oldest" rank a group by its most recently touched copy: that
        // is the one that says whether the set is still in use.
        func lastUsed(_ section: LargeFileCategoryFilter.Section) -> Date {
            section.memberIndices.map { files[$0].lastUsed }.max() ?? .distantPast
        }
        func name(_ section: LargeFileCategoryFilter.Section) -> String {
            section.memberIndices.first.map { files[$0].displayName } ?? ""
        }

        switch currentSort {
        // Sorted on the reclaimable figure the group header shows, not on the
        // index's own ordering: the two agree today, but only the header's number
        // is derived from the rows actually rendered.
        case .sizeDesc:
            return sections.sorted { $0.displayedReclaimableBytes > $1.displayedReclaimableBytes }
        case .sizeAsc:
            return sections.sorted { $0.displayedReclaimableBytes < $1.displayedReclaimableBytes }
        case .dateNewest: return sections.sorted { lastUsed($0) > lastUsed($1) }
        case .dateOldest: return sections.sorted { lastUsed($0) < lastUsed($1) }
        case .nameAZ:
            return sections.sorted {
                name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
            }
        }
    }

    /// Rows in display order. Derived from `visibleIndices` so the two can never
    /// disagree about what the list is showing.
    private var visibleFiles: [LargeFile] {
        let files = store.largeFiles
        return visibleIndices.map { files[$0] }
    }

    private var visibleIDs: [String] {
        visibleFiles.map(\.id)
    }

    /// Indices into `store.largeFiles` in display (filtered + sorted) order. The
    /// results List iterates these instead of `visibleFiles` so its ForEach data is
    /// a plain `[Int]` that stays value-identical when only a row's selection flips
    /// — that structural stability is what keeps the macOS List from re-scrolling
    /// to its stuck "current row" on select (matches the App Caches list, which
    /// iterates `sortedVisibleIndices()`). Iterating fresh `LargeFile` value copies
    /// instead churns the data every toggle and reintroduces the scroll jump.
    private var visibleIndices: [Int] {
        let files = store.largeFiles
        let filtered = LargeFileCategoryFilter.visibleIndices(
            in: files, rawValue: categoryFilterRaw, query: searchQuery, duplicates: duplicateIndex
        )

        // Under the Duplicates chip the rows are laid out group by group, which
        // the shared filter has already done. The sort menu doesn't apply — the
        // grouping *is* the order.
        if isDuplicatesFilterActive { return filtered }

        switch currentSort {
        case .sizeDesc: return filtered.sorted { files[$0].sizeBytes > files[$1].sizeBytes }
        case .sizeAsc: return filtered.sorted { files[$0].sizeBytes < files[$1].sizeBytes }
        case .dateNewest: return filtered.sorted { files[$0].lastUsed > files[$1].lastUsed }
        case .dateOldest: return filtered.sorted { files[$0].lastUsed < files[$1].lastUsed }
        case .nameAZ:
            return filtered.sorted {
                files[$0].displayName.localizedCaseInsensitiveCompare(files[$1].displayName) == .orderedAscending
            }
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
        .background(AppColors.bgBase)
        .onReceive(store.largeFileDuplicates.indexPublisher) { index in
            duplicateIndex = index
        }
    }

    private var standardBody: some View {
        VStack(spacing: 0) {
            if showsPageHeader {
                AppSectionPageHeader(title: "Large Files", subtitle: pageSubtitle) {
                    headerActions
                }
            }

            controlsChrome
            listStack
        }
    }

    @ViewBuilder
    private var externalScrollBody: some View {
        if #available(macOS 26.0, *) {
            VStack(spacing: 0) {
                controlsChrome

                if !visibleFiles.isEmpty {
                    ZStack {
                        resultsList
                            .scanTabSoftScrollEdge { selectAllRowChrome }

                        if store.isDeleting {
                            CleaningOverlay()
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        selectAllRowChrome
                        listStack
                    }
                }
            }
        } else {
            standardBody
        }
    }

    private var headerActions: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Button(action: onScan) {
                CleaningButtonLabel(
                    title: isLoading ? "Scanning..." : "Scan",
                    systemImage: isLoading ? nil : "arrow.clockwise",
                    isCleaning: isLoading
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
            .disabled(isLoading)

            LargeFileDeleteButton(selection: store.largeFileSelection)
        }
        .fixedSize()
    }

    private var controlsChrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                thresholdMenu
                ageMenu
                Spacer(minLength: 12)
                LargeFileSearchField(query: $searchQuery)
            }
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Counts are search-filtered but not category-filtered, so the
                    // chips answer "where did my matches land?" while a query is
                    // active instead of advertising rows the query already hid.
                    categoryChip(
                        id: LargeFileCategoryFilter.all,
                        title: "All",
                        systemImage: "square.grid.2x2",
                        count: searchMatches.count
                    )

                    // Sits right after "All" rather than among the categories: a
                    // duplicate cuts across every category, and it's the one chip
                    // that answers "what here is redundant?".
                    if !duplicateIndex.isEmpty {
                        categoryChip(
                            id: Self.duplicatesFilterID,
                            title: "Duplicates",
                            systemImage: "square.on.square",
                            // The count of *removable* copies — one keeper per
                            // group excluded — so it answers "what here is
                            // redundant?" and agrees with the reclaimable bytes
                            // rather than double-counting the copy worth keeping.
                            //
                            // Counted from the sections the list would draw, not
                            // from the query matches: a query matching one copy
                            // expands to its whole group, so counting matches
                            // directly would advertise fewer rows than appear.
                            count: duplicateSections.reduce(0) { $0 + $1.displayedReclaimableCount },
                            tier: .checkFirst
                        )
                    }

                    LargeFileDuplicateStatus(duplicates: store.largeFileDuplicates)

                    ForEach(availableCategories) { category in
                        categoryChip(
                            id: category.rawValue,
                            title: category.displayName,
                            systemImage: category.symbolName,
                            count: searchMatches.filter { $0.category == category }.count
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        }
    }

    private var thresholdMenu: some View {
        Menu {
            ForEach(LargeFileSizeThreshold.allCases) { option in
                Button {
                    minSizeMB = option.rawValue
                    onScan()
                } label: {
                    if option == sizeThreshold {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            FilterChip(
                style: .dropdown,
                label: sizeThreshold.menuButtonLabel,
                leadingSystemImage: "arrow.up.forward.circle"
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Size filter")
        .accessibilityValue(sizeThreshold.menuButtonLabel)
    }

    private var ageMenu: some View {
        Menu {
            ForEach(LargeFileAgeThreshold.allCases) { option in
                Button {
                    minAgeDays = option.rawValue
                    onScan()
                } label: {
                    if option == ageThreshold {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            FilterChip(
                style: .dropdown,
                label: ageThreshold.menuButtonLabel,
                leadingSystemImage: "calendar"
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Last used filter")
        .accessibilityValue(ageThreshold.menuButtonLabel)
    }

    private func categoryChip(
        id: String,
        title: String,
        systemImage: String,
        count: Int,
        tier: FilterChipTier = .neutral
    ) -> some View {
        let isOn = categoryFilterRaw == id
        return Button {
            selectCategory(id)
        } label: {
            FilterChip(
                style: .tab,
                label: title,
                isSelected: isOn,
                tier: tier,
                leadingSystemImage: systemImage,
                count: count
            )
        }
        .buttonStyle(.plain)
    }

    private func selectCategory(_ id: String) {
        if reduceMotion {
            categoryFilterRaw = id
        } else {
            withAnimation(.easeInOut(duration: 0.15)) {
                categoryFilterRaw = id
            }
        }
    }

    private var selectAllRowChrome: some View {
        // A child view that observes the selection object, so its tri-state updates
        // on selection WITHOUT re-rendering LargeFilesView (which would revert the
        // list scroll). LargeFilesView only reads the stable object reference here.
        LargeFileSelectAllBar(
            selection: store.largeFileSelection,
            visibleIDs: visibleIDs,
            sort: sortOptionBinding,
            onToggleAll: toggleSelectAll
        )
    }

    private var listStack: some View {
        ZStack {
            listOrPlaceholder

            if store.isDeleting && !visibleFiles.isEmpty {
                CleaningOverlay()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var listOrPlaceholder: some View {
        if store.largeFiles.isEmpty {
            if isLoading {
                scanningPlaceholder
            } else {
                emptyState
            }
        } else if visibleFiles.isEmpty {
            emptyFilterState
        } else {
            resultsList
        }
    }

    /// Stable anchor pinned to the very top of the results list so a fresh scan or
    /// first appearance can reset scroll position to the first row.
    private static let topAnchorID = "large-files-top"

    /// Identity of the results List. Changes on scan completion so fresh results
    /// start at the top, and *also* when the list switches between flat rows and
    /// duplicate group containers.
    ///
    /// That second term is load-bearing. The swap changes every row's height and
    /// the total content length under a scroll offset the List otherwise keeps, so
    /// landing on Duplicates left the first group scrolled up beneath the Select
    /// All bar with the soft scroll-edge material missing — a flat dark band
    /// instead of the translucent one every other tab shows. Switching to another
    /// chip and back "fixed" it only because that rebuilt the rows by hand. A
    /// fresh identity does it properly, on the transition itself.
    private var resultsListIdentity: String {
        "\(scanGeneration)-\(isDuplicatesFilterActive ? "grouped" : "flat")"
    }

    private var resultsList: some View {
        // No ScrollViewReader/ScrollPosition binding: both revert the scroll to a
        // stale committed offset on the first re-render after a wheel/trackpad
        // scroll (verified by logging). We reset the List identity only when a scan
        // finishes so fresh results start at the top, and leave scroll alone on
        // every selection.
        resultsListContent
            .id(resultsListIdentity)
            .onChange(of: isLoading) { loading in
                guard !loading else { return }
                scanGeneration &+= 1
            }
    }

    private var resultsListContent: some View {
        List {
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .id(Self.topAnchorID)

            if isDuplicatesFilterActive {
                // One List row per *group*: the copies live inside the container,
                // so a set of duplicates reads as one thing. Iterating group ids
                // ([String]) keeps the same property that `[Int]` indices give the
                // flat list — the ForEach data is value-identical across selection
                // toggles, so the List doesn't churn and revert its scroll.
                ForEach(duplicateSections, id: \.groupID) { section in
                    DuplicateGroupCard(
                        section: section,
                        files: store.largeFiles,
                        selection: store.largeFileSelection,
                        onToggle: toggleSelection(forFileID:)
                    )
                    .listRowInsets(ScanListRowInsets.standard)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .transition(reduceMotion ? .opacity : .scanRowInsertion)
                }
            } else {
                // Iterate stable `[Int]` indices (not fresh LargeFile copies) so the
                // ForEach data doesn't churn on selection and the List stays put —
                // see `visibleIndices`.
                ForEach(visibleIndices, id: \.self) { index in
                    let file = store.largeFiles[index]
                    LargeFileRow(
                        file: file,
                        selection: store.largeFileSelection,
                        duplicateCopyCount: duplicateIndex.copyCount(forFileID: file.id),
                        onToggle: { toggleSelection(forFileID: file.id) }
                    )
                    .listRowInsets(ScanListRowInsets.standard)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .transition(reduceMotion ? .opacity : .scanRowInsertion)
                }
            }

            ScanListBottomSpacer()
        }
        .listStyle(.plain)
        // On macOS, List rows are natively selectable even with no `selection:`
        // binding: the first click engages NSTableView selection/focus and it
        // scroll-to-visibles the clicked row (worse here than the scan tabs
        // because these rows are taller). We drive selection ourselves via the
        // row's `.onTapGesture`, so disable the List's own selection to stop it.
        .disablingListSelection()
        .scrollContentBackground(.hidden)
        .background(AppColors.bgBase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.largeFilesRevision)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("No Large Files Found")
                .font(.title3)
            Text("Try a lower size threshold or a shorter last-used window.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFilterState: some View {
        VStack(spacing: 4) {
            Text("Nothing here.")
                .font(.headline)
            // Name the query when there is one: with a search field in the chrome the
            // generic "this filter" leaves the user guessing whether it was the query,
            // the category, or the size threshold that emptied the list.
            if hasActiveQuery {
                Text("No files match \"\(searchQuery)\".")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Button("Clear Search") {
                    searchQuery = ""
                }
                .buttonStyle(.link)
                .padding(.top, 2)
            } else {
                Text("No files match this filter.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var scanningPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Scanning large files")
    }

    private func toggleSelection(forFileID id: String) {
        store.setLargeFileSelected(
            id: id,
            isSelected: !store.largeFileSelection.ids.contains(id)
        )
    }

    private func toggleSelectAll() {
        let ids = visibleIDs
        guard !ids.isEmpty else { return }
        let selected = store.largeFileSelection.ids
        let allOn = ids.allSatisfy { selected.contains($0) }
        store.setAllLargeFilesSelected(!allOn, ids: ids)
    }

    private var pageSubtitle: String {
        let count = visibleFiles.count
        let bytes = visibleFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let itemLabel = count == 1 ? "file" : "files"
        return "\(count) \(itemLabel) · \(formatBytes(bytes)) to review"
    }

}

private extension View {
    /// Disables the List's own row selection (macOS 14+); a no-op on older systems.
    /// We manage selection via each row's tap gesture, so the List must not also
    /// select-and-scroll the clicked row.
    @ViewBuilder
    func disablingListSelection() -> some View {
        if #available(macOS 14.0, *) {
            selectionDisabled()
        } else {
            self
        }
    }

}

/// Delete button extracted so its count/label/enabled state observe the selection
/// object directly — updating on selection without re-rendering the results List.
private struct LargeFileDeleteButton: View {
    @EnvironmentObject private var store: PurgeStore
    @ObservedObject var selection: LargeFileSelection

    var body: some View {
        Button {
            store.presentLargeFileDeletionSheet()
        } label: {
            AnimatedDeleteActionLabel(
                inactiveTitle: "Delete Selected",
                activeTitle: "Delete Selected",
                selectedCount: store.selectedLargeFileCount,
                selectedBytes: store.selectedLargeFileBytes
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .buttonStyle(AppButtonStyle(variant: .filled, isCapsule: true))
        .disabled(store.selectedLargeFileCount == 0 || store.isDeleting)
    }
}

/// "Checking for duplicates…" status that sits at the end of the chips row while
/// the hashing pass runs.
///
/// Its own view, observing the index object directly, so the flag flipping on and
/// off doesn't re-render `LargeFilesView` — which would revert the results List's
/// scroll position for a purely cosmetic status change.
private struct LargeFileDuplicateStatus: View {
    @ObservedObject var duplicates: LargeFileDuplicateIndex

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if duplicates.isChecking {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                    Text("Checking for duplicates…")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
                .padding(.leading, 4)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: duplicates.isChecking)
    }
}

/// Select-all bar extracted from LargeFilesView so its tri-state can observe the
/// selection object directly — updating on selection without re-rendering (and thus
/// scroll-reverting) the results List.
private struct LargeFileSelectAllBar: View {
    @ObservedObject var selection: LargeFileSelection
    let visibleIDs: [String]
    @Binding var sort: SortOption
    let onToggleAll: () -> Void

    private var state: SelectAllTriState {
        guard !visibleIDs.isEmpty else { return .none }
        let selected = visibleIDs.filter { selection.ids.contains($0) }.count
        if selected == 0 { return .none }
        if selected == visibleIDs.count { return .all }
        return .mixed
    }

    var body: some View {
        HStack(alignment: .bottom) {
            TriStateCheckbox(title: "Select All", state: state) {
                onToggleAll()
            }
            .fixedSize()
            .disabled(visibleIDs.isEmpty)

            Spacer()

            // Always present, even under Duplicates where it reorders whole groups
            // rather than rows. Its absence would shrink this bar, and the scan-tab
            // scroll-edge constants (`scanTabBarSpacing`, the content-margin
            // compensation) are absolute offsets tuned against a fixed bar height —
            // a shorter bar pulls the first card up underneath it and smears the
            // soft edge into a gradient.
            AppSortMenu(selection: $sort)
        }
        .scanTabSelectAllRowLayout()
    }
}

/// Search field for the Large Files controls row. Deliberately hand-built rather
/// than `.searchable`: that modifier hangs its field off the enclosing navigation
/// chrome, which would put it outside this view entirely and give it a different
/// look on each of the two containers `LargeFilesView` renders into. Geometry and
/// tokens here are copied from `FilterChip` so it reads as one control family with
/// the size and last-used menus sitting beside it.
private struct LargeFileSearchField: View {
    @Binding var query: String

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Matches FilterChip's metrics so the row's controls share a baseline.
    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 5
    private static let labelSize: CGFloat = 13

    private var hasText: Bool { !query.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)

            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: Self.labelSize))
                .foregroundStyle(AppColors.textPrimary)
                .focused($isFocused)
                .accessibilityLabel("Search large files by name")
                // Escape clears rather than just unfocusing: an emptied field is the
                // state the user wants back, and it's the one AppKit search fields
                // give them.
                .onExitCommand {
                    if hasText {
                        query = ""
                    } else {
                        isFocused = false
                    }
                }

            // A real Button is fine here — unlike the result rows, this field lives
            // in the controls chrome and never inside the List, so it can't trigger
            // the scroll-to-clicked-row behaviour that forces rows to use tap gestures.
            if hasText {
                Button {
                    query = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("Clear search")
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .frame(width: 220)
        .background {
            Capsule(style: .continuous)
                .fill(AppColors.bgElevated)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    isFocused ? AppColors.buttonPrimaryBg : AppColors.borderSubtle,
                    lineWidth: 1
                )
        }
        .contentShape(Capsule(style: .continuous))
        // Clicking anywhere in the capsule focuses the field, not just the glyph-width
        // of text already typed.
        .onTapGesture { isFocused = true }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isFocused)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hasText)
    }
}

/// One duplicate group drawn as a container holding its copies.
///
/// This is a single List row, not a Section: the copies are the *contents* of one
/// box, and letting the List lay them out as siblings is what made a set of
/// duplicates read as unrelated files in the first place. It also keeps the
/// height arithmetic exact — see `height`.
private struct DuplicateGroupCard: View {
    /// Carries the group and its rendered members together, so the header's copy
    /// count and reclaimable figure are derived from the rows below it rather
    /// than from the index, which can briefly disagree.
    let section: LargeFileCategoryFilter.Section
    let files: [LargeFile]
    /// Observed by the child rows, not here — the container itself must not
    /// re-render on selection.
    let selection: LargeFileSelection
    let onToggle: (String) -> Void

    private static let headerHeight: CGFloat = 20
    private static let innerSpacing: CGFloat = 6
    private static let padding: CGFloat = 10

    /// Explicit, because the macOS List estimating this row's height is what
    /// makes a click scroll the list — the estimate/actual drift accumulates over
    /// the rows above. Every term is a fixed constant, so the sum is exact.
    private var height: CGFloat {
        let rows = CGFloat(section.displayedCopyCount)
        return Self.padding * 2
            + Self.headerHeight
            + Self.innerSpacing
            + rows * LargeFileRow.contentHeight
            + max(rows - 1, 0) * Self.innerSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.innerSpacing) {
            header

            ForEach(section.memberIndices, id: \.self) { index in
                let file = files[index]
                LargeFileRow(
                    file: file,
                    selection: selection,
                    // No badge inside the box: the container header already says
                    // how many copies there are, and repeating it on every card
                    // is noise.
                    duplicateCopyCount: nil,
                    isNested: true,
                    onToggle: { onToggle(file.id) }
                )
            }
        }
        .padding(Self.padding)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                .fill(AppColors.bgElevated)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(section.displayedCopyCount) identical copies, \(formatBytes(section.group.sizeBytes)) each"
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.on.square")
                .imageScale(.small)
                .foregroundStyle(AppColors.tagCheckText)
                .accessibilityHidden(true)

            Text("\(section.displayedCopyCount) identical copies · \(formatBytes(section.group.sizeBytes)) each")
                .foregroundStyle(AppColors.textSecondary)

            Spacer(minLength: 8)

            // States the prize without naming a winner: which copy to keep is the
            // user's call, so this never says "delete the one in Downloads".
            Text("Keep one to free \(formatBytes(section.displayedReclaimableBytes))")
                .foregroundStyle(AppColors.textTertiary)
        }
        .font(AppStyle.Typography.metadataEmphasis)
        .lineLimit(1)
        .frame(height: Self.headerHeight)
        .padding(.horizontal, 4)
    }
}

private struct LargeFileRow: View {
    let file: LargeFile
    /// Observed so a toggle re-renders only the (visible) rows — not the List
    /// container, whose re-render is what reverts the scroll position.
    @ObservedObject var selection: LargeFileSelection
    /// How many byte-identical copies of this file the scan found, nil when it
    /// isn't part of a duplicate group. Passed as a plain value rather than by
    /// observing the index object: it only changes when the whole index does, and
    /// `LargeFilesView` already re-renders for that.
    let duplicateCopyCount: Int?
    /// Set when the row sits inside a `DuplicateGroupCard`. The card already
    /// supplies a raised surface, so the row needs its own outline to stay
    /// legible as a distinct item rather than dissolving into the container.
    var isNested: Bool = false
    let onToggle: () -> Void

    private var isSelected: Bool { selection.ids.contains(file.id) }

    /// Copies *other than this row*. The row is itself one of the group's members,
    /// so a badge carrying the group total reads as "and this many more elsewhere"
    /// and overstates by one (issue #29). Nil for a group of one, which the index
    /// never produces but the arithmetic shouldn't assume.
    private var otherCopyCount: Int? {
        guard let duplicateCopyCount, duplicateCopyCount > 1 else { return nil }
        return duplicateCopyCount - 1
    }

    /// Fixed, uniform row height so the macOS List never has to *estimate* a row's
    /// height. Estimated-vs-actual drift is what makes a click scroll the list: the
    /// error accumulates over the off-screen rows above, so a click near the top
    /// barely moves while a click far down jumps by the whole accumulated drift
    /// (enough to throw the row out of view). Derived from the row's own font
    /// metrics + vertical padding so it matches the natural height without clipping.
    static let contentHeight: CGFloat = {
        let textBlock = ScanResultRow.headlineOneLineHeight + 4 + ScanResultRow.subheadlineOneLineHeight
        return max(AppStyle.Row.listIconFrameSize, textBlock) + 24
    }()
    @State private var isHoveringLocation = false

    private var dateText: String {
        relativeDateText(for: file.lastUsed, referenceDate: Date())
    }

    private var parentFolderPath: String {
        file.path.deletingLastPathComponent().path
    }

    private var fileURL: URL {
        file.path.standardizedFileURL
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func quickLook() {
        QuickLookPreview.show(url: fileURL)
    }

    var body: some View {
        // The WHOLE row is one tap target (not a Button, not per-subview): a Button
        // or interactive control in a macOS List row makes the List scroll the
        // clicked row into view. Just as bad, any area NOT covered by a gesture
        // (checkbox, spacer, size label) falls through to the List's own native
        // row selection, which also scrolls the row in — so the tap must blanket
        // the entire row. The thumbnail/location gestures inside rowMainContent
        // still win at their own hit points.
        HStack(alignment: .center, spacing: 12) {
            checkboxVisual

            rowMainContent

            Spacer(minLength: 12)

            Text(file.formattedSize)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(height: Self.contentHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
        .modifier(ScanRowCardChrome())
        .overlay {
            if isNested {
                RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
            }
        }
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction {
            onToggle()
        }
    }

    /// Non-interactive checkbox that only reflects selection state, so the whole
    /// row is a single tap target and the checkmark fills on the same frame as
    /// the tap (no competing hit target, no visible in-between state). An
    /// interactive Toggle here routes clicks through AppKit's control path, which
    /// scrolls the clicked row into view and shifts the whole list on select.
    private var checkboxVisual: some View {
        Toggle("", isOn: .constant(isSelected))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .tint(AppColors.buttonPrimaryBg)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var rowMainContent: some View {
        HStack(alignment: .center, spacing: 12) {
            // Tap gesture rather than a Button: a Button in a macOS List row makes
            // the List scroll the clicked row into view on click, shifting the list.
            LargeFileThumbnailIcon(file: file)
                .contentShape(Rectangle())
                .onTapGesture(perform: quickLook)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .help("Quick Look")
                .accessibilityLabel("Quick Look \(file.displayName)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, quickLook)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(file.locationLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .underline(isHoveringLocation)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: revealInFinder)
                        .onHover { isHoveringLocation = $0 }
                        .help("Show in Finder\n\(parentFolderPath)")
                        .accessibilityLabel("Reveal in Finder, \(file.locationLabel)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(.default, revealInFinder)

                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("Last used \(dateText)")
                        .foregroundStyle(.secondary)
                        .layoutPriority(-1)

                    if let otherCopyCount {
                        let noun = otherCopyCount == 1 ? "copy" : "copies"
                        AppBadge(text: "\(otherCopyCount) other \(noun)", tone: .warning)
                            .fixedSize()
                            .help("\(otherCopyCount + 1) files in this scan have identical contents, including this one.")
                            .accessibilityLabel("\(otherCopyCount) other identical \(noun) found")
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Leading icon for a Large File row: a QuickLook thumbnail when one can be generated,
/// otherwise the category icon with a small extension badge. The fallback renders immediately so
/// scrolling never blocks; the thumbnail loads off the main thread and fades in once ready, and
/// `.task` cancels in-flight generation when the row scrolls off-screen.
private struct LargeFileThumbnailIcon: View {
    let file: LargeFile

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var thumbnail: NSImage?

    private let slotSize = AppStyle.Row.listIconFrameSize
    private let cornerRadius: CGFloat = 6

    private var cacheKey: String {
        LargeFileThumbnailService.cacheKey(path: file.id, modified: file.lastUsed)
    }

    private var fileExtension: String {
        file.path.pathExtension.lowercased()
    }

    var body: some View {
        ZStack {
            fallbackIcon
                .opacity(thumbnail == nil ? 1 : 0)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: slotSize, height: slotSize)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
                    }
                    .transition(.opacity)
            }
        }
        .frame(width: slotSize, height: slotSize)
        .task(id: cacheKey) {
            await loadThumbnail()
        }
    }

    private var fallbackIcon: some View {
        AdaptiveBrandIconImage(source: .sfSymbol(file.category.symbolName))
            .overlay(alignment: .bottomTrailing) {
                extensionBadge
            }
    }

    @ViewBuilder
    private var extensionBadge: some View {
        if !fileExtension.isEmpty {
            Text(".\(fileExtension)")
                .font(.system(size: 8, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Capsule(style: .continuous).fill(.regularMaterial))
                .overlay(Capsule(style: .continuous).strokeBorder(AppColors.borderSubtle, lineWidth: 0.5))
                .fixedSize()
        }
    }

    private func loadThumbnail() async {
        let key = cacheKey

        if let cached = LargeFileThumbnailService.shared.cachedThumbnail(forKey: key) {
            thumbnail = cached
            return
        }

        let scale = displayScale > 0 ? displayScale : 2
        let image = await LargeFileThumbnailService.shared.thumbnail(
            for: file.path.standardizedFileURL,
            key: key,
            pointSize: slotSize,
            scale: scale
        )

        guard !Task.isCancelled, let image else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            thumbnail = image
        }
    }
}

struct LargeFilesHeaderActions: View {
    @EnvironmentObject private var store: PurgeStore

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Button {
                Task { await store.scanLargeFiles() }
            } label: {
                CleaningButtonLabel(
                    title: store.isScanningLargeFiles ? "Scanning..." : "Scan",
                    systemImage: store.isScanningLargeFiles ? nil : "arrow.clockwise",
                    isCleaning: store.isScanningLargeFiles
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
            .disabled(store.isScanningLargeFiles)

            LargeFileDeleteButton(selection: store.largeFileSelection)
        }
        .fixedSize()
    }
}

struct LargeFileDeletionConfirmSheet: View {
    let files: [LargeFile]
    /// Duplicate groups the selection would erase entirely. Purge never picks
    /// which copy survives — issue #17 is explicit that this is the user's call —
    /// so this only states plainly what the current selection does.
    var fullyConsumedDuplicateGroups: [DuplicateGroup] = []
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var totalBytes: Int64 {
        files.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    /// Names the copies in a fully-selected group by, well, their name: the row
    /// label of the first copy, since every copy has identical content and any of
    /// them identifies the thing being lost.
    private func groupLabel(_ group: DuplicateGroup) -> String {
        guard let fileID = group.fileIDs.first,
              let file = files.first(where: { $0.id == fileID }) else {
            return "these files"
        }
        return file.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move selected files to Trash?")
                .font(.title3.weight(.semibold))

            Text("These are personal files you selected. Purge will move only these files to Trash.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List(files.sorted { $0.sizeBytes > $1.sizeBytes }) { file in
                HStack(spacing: 10) {
                    Image(systemName: file.category.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(file.path.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(file.formattedSize)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 220)

            if !fullyConsumedDuplicateGroups.isEmpty {
                allCopiesWarning
            }

            HStack {
                Text("Total: \(formatBytes(totalBytes))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
    }

    /// How many fully-selected groups get named before the note switches to a
    /// count. A Select All over a scan full of duplicates can consume dozens of
    /// groups, and this note sits in a sheet with no maximum height — naming them
    /// all would push the buttons off the bottom of the screen.
    private static let namedConsumedGroupLimit = 3

    private var namedConsumedGroups: [DuplicateGroup] {
        Array(fullyConsumedDuplicateGroups.prefix(Self.namedConsumedGroupLimit))
    }

    private var remainingConsumedGroupCount: Int {
        max(fullyConsumedDuplicateGroups.count - Self.namedConsumedGroupLimit, 0)
    }

    /// Deliberately a note, not a blocker: deleting every copy is a legitimate
    /// thing to want. It just shouldn't happen by accident after a Select All.
    private var allCopiesWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.tagCheckText)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(namedConsumedGroups) { group in
                    Text("You're deleting all \(group.copyCount) copies of \(groupLabel(group)). No copy will remain.")
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if remainingConsumedGroupCount > 0 {
                    Text("…and \(remainingConsumedGroupCount) more sets where every copy is selected.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous)
                .fill(AppColors.tagCheckBg)
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview("Large Files") {
    LargeFilesView(isLoading: false, onScan: {}, searchQuery: .constant(""))
        .environmentObject(PurgeStore())
        .frame(width: 720, height: 560)
}
