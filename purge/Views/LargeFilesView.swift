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

    private var selectAllState: SelectAllTriState {
        let visible = visibleFiles
        guard !visible.isEmpty else { return .none }
        let selected = visible.filter(\.isSelected).count
        if selected == 0 { return .none }
        if selected == visible.count { return .all }
        return .mixed
    }

    var body: some View {
        Group {
            if usesExternalScrollContainer {
                externalScrollBody
            } else {
                standardBody
            }
        }
        .background(AppStyle.canvas)
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

            Button {
                store.presentLargeFileDeletionSheet()
            } label: {
                Label(reviewButtonTitle, systemImage: "trash.fill")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(AppButtonStyle(variant: .filled, isCapsule: true))
            .disabled(store.selectedLargeFileCount == 0 || store.isDeleting)
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
            filterDropdownLabel(
                title: sizeThreshold.menuButtonLabel,
                systemImage: "arrow.up.forward.circle"
            )
        }
        .menuStyle(.button)
        .buttonStyle(AppButtonStyle(variant: .bordered))
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
            filterDropdownLabel(
                title: ageThreshold.menuButtonLabel,
                systemImage: "calendar"
            )
        }
        .menuStyle(.button)
        .buttonStyle(AppButtonStyle(variant: .bordered))
        .fixedSize()
        .accessibilityLabel("Last used filter")
        .accessibilityValue(ageThreshold.menuButtonLabel)
    }

    private func filterDropdownLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func categoryChip(id: String, title: String, systemImage: String, count: Int) -> some View {
        let isOn = categoryFilterRaw == id
        return Button {
            categoryFilterRaw = id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(isOn ? AppStyle.accent : .secondary)
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 13, weight: isOn ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous)
                    .fill(isOn ? AppStyle.selectionFill : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous)
                    .strokeBorder(isOn ? AppStyle.selectionStroke : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var selectAllRowChrome: some View {
        HStack {
            TriStateCheckbox(title: "Select All", state: selectAllState) {
                toggleSelectAll()
            }
            .fixedSize()
            .disabled(visibleFiles.isEmpty)

            Spacer()

            AppSortMenu(selection: sortOptionBinding)
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(.vertical, AppStyle.Spacing.xSmall)
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

    private var resultsList: some View {
        List {
            ForEach(visibleFiles) { file in
                LargeFileRow(
                    file: file,
                    isSelected: Binding(
                        get: { store.largeFiles.first(where: { $0.id == file.id })?.isSelected ?? false },
                        set: { store.setLargeFileSelected(id: file.id, isSelected: $0) }
                    )
                )
                .listRowInsets(ScanListRowInsets.standard)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .transition(reduceMotion ? .opacity : .scanRowInsertion)
            }

            ScanListBottomSpacer()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppStyle.canvas)
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
        let allOn = visibleFiles.allSatisfy(\.isSelected)
        store.setAllLargeFilesSelected(!allOn, ids: ids)
    }

    private var pageSubtitle: String {
        let count = visibleFiles.count
        let bytes = visibleFiles.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let itemLabel = count == 1 ? "file" : "files"
        return "\(count) \(itemLabel) · \(formatBytes(bytes)) to review"
    }

    private var reviewButtonTitle: String {
        guard store.selectedLargeFileCount > 0 else { return "Review Selected" }
        return "Review Selected (\(formatBytes(store.selectedLargeFileBytes)))"
    }
}

private struct LargeFileRow: View {
    let file: LargeFile
    @Binding var isSelected: Bool
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
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Button {
                isSelected.toggle()
            } label: {
                rowMainContent
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            Text(file.formattedSize)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(ScanRowCardChrome())
        .contextMenu {
            Button("Quick Look") {
                quickLook()
            }

            Button("Show in Finder") {
                revealInFinder()
            }

            Button(isSelected ? "Deselect" : "Select") {
                isSelected.toggle()
            }
        }
    }

    private var rowMainContent: some View {
        HStack(alignment: .center, spacing: 12) {
            AdaptiveBrandIconImage(source: .sfSymbol(file.category.symbolName))

            VStack(alignment: .leading, spacing: 4) {
                Button(action: quickLook) {
                    Text(file.displayName)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .help("Quick Look")
                .accessibilityLabel("Quick Look \(file.displayName)")

                HStack(spacing: 6) {
                    Button(action: revealInFinder) {
                        Text(file.locationLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .underline(isHoveringLocation)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppStyle.accent)
                    .onHover { isHoveringLocation = $0 }
                    .help("Show in Finder\n\(parentFolderPath)")
                    .accessibilityLabel("Reveal in Finder, \(file.locationLabel)")

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

struct LargeFilesHeaderActions: View {
    @EnvironmentObject private var store: PurgeStore

    private var reviewButtonTitle: String {
        guard store.selectedLargeFileCount > 0 else { return "Review Selected" }
        return "Review Selected (\(formatBytes(store.selectedLargeFileBytes)))"
    }

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

            Button {
                store.presentLargeFileDeletionSheet()
            } label: {
                Label(reviewButtonTitle, systemImage: "trash.fill")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(AppButtonStyle(variant: .filled, isCapsule: true))
            .disabled(store.selectedLargeFileCount == 0 || store.isDeleting)
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
