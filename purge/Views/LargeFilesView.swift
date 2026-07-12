import AppKit
import SwiftUI

struct LargeFilesView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isLoading: Bool
    let onScan: () -> Void
    var showsPageHeader = true
    var usesExternalScrollContainer = false

    @AppStorage("filter.largeFiles") private var categoryFilterRaw: String = "all"
    @AppStorage("sort.largeFiles") private var sortRaw: String = SortOption.sizeDesc.rawValue
    @AppStorage(LargeFileSizeThreshold.userDefaultsKey) private var minSizeMB: Int = LargeFileSizeThreshold.defaultOption.rawValue
    @AppStorage(LargeFileAgeThreshold.userDefaultsKey) private var minAgeDays: Int = LargeFileAgeThreshold.defaultOption.rawValue

    /// Bumped when a scan finishes to reset the results List's identity (and thus
    /// its scroll to the top). Kept out of selection so toggles never reset scroll.
    @State private var scanGeneration = 0

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

    private var availableCategories: [LargeFileCategory] {
        let present = Set(store.largeFiles.map(\.category))
        return LargeFileCategory.allCases.filter { present.contains($0) }
    }

    private var visibleFiles: [LargeFile] {
        let filtered = store.largeFiles.filter { file in
            categoryFilterRaw == "all" || file.category.rawValue == categoryFilterRaw
        }

        switch currentSort {
        case .sizeDesc: return filtered.sorted { $0.sizeBytes > $1.sizeBytes }
        case .sizeAsc: return filtered.sorted { $0.sizeBytes < $1.sizeBytes }
        case .dateNewest: return filtered.sorted { $0.lastUsed > $1.lastUsed }
        case .dateOldest: return filtered.sorted { $0.lastUsed < $1.lastUsed }
        case .nameAZ:
            return filtered.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
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
        let filtered = files.indices.filter { i in
            categoryFilterRaw == "all" || files[i].category.rawValue == categoryFilterRaw
        }

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
                Spacer()
            }
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    categoryChip(id: "all", title: "All", systemImage: "square.grid.2x2", count: store.largeFiles.count)
                    ForEach(availableCategories) { category in
                        categoryChip(
                            id: category.rawValue,
                            title: category.displayName,
                            systemImage: category.symbolName,
                            count: store.largeFiles.filter { $0.category == category }.count
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

    private func categoryChip(id: String, title: String, systemImage: String, count: Int) -> some View {
        let isOn = categoryFilterRaw == id
        return Button {
            selectCategory(id)
        } label: {
            FilterChip(
                style: .tab,
                label: title,
                isSelected: isOn,
                tier: .neutral,
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

    private var resultsList: some View {
        // No ScrollViewReader/ScrollPosition binding: both revert the scroll to a
        // stale committed offset on the first re-render after a wheel/trackpad
        // scroll (verified by logging). We reset the List identity only when a scan
        // finishes so fresh results start at the top, and leave scroll alone on
        // every selection.
        resultsListContent
            .id(scanGeneration)
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

            // Iterate stable `[Int]` indices (not fresh LargeFile copies) so the
            // ForEach data doesn't churn on selection and the List stays put —
            // see `visibleIndices`.
            ForEach(visibleIndices, id: \.self) { index in
                let file = store.largeFiles[index]
                LargeFileRow(
                    file: file,
                    selection: store.largeFileSelection,
                    onToggle: {
                        let id = file.id
                        store.setLargeFileSelected(
                            id: id,
                            isSelected: !store.largeFileSelection.ids.contains(id)
                        )
                    }
                )
                .listRowInsets(ScanListRowInsets.standard)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .transition(reduceMotion ? .opacity : .scanRowInsertion)
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.largeFiles.map(\.id))
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
            Text("No files match this filter.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Scanning large files")
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

            AppSortMenu(selection: $sort)
        }
        .scanTabSelectAllRowLayout()
    }
}

private struct LargeFileRow: View {
    let file: LargeFile
    /// Observed so a toggle re-renders only the (visible) rows — not the List
    /// container, whose re-render is what reverts the scroll position.
    @ObservedObject var selection: LargeFileSelection
    let onToggle: () -> Void

    private var isSelected: Bool { selection.ids.contains(file.id) }

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
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var totalBytes: Int64 {
        files.reduce(Int64(0)) { $0 + $1.sizeBytes }
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
}

#Preview("Large Files") {
    LargeFilesView(isLoading: false, onScan: {})
        .environmentObject(PurgeStore())
        .frame(width: 720, height: 560)
}
