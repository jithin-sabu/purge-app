import AppKit
import SwiftUI

/// The Uninstall tab. Two modes in one view: a picker of installed apps, and,
/// once an app is chosen, the review of its bundle plus the files it left behind.
struct UninstallView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appSearchQuery = ""

    var body: some View {
        Group {
            if let app = store.selectedAppForUninstall {
                reviewBody(for: app)
            } else {
                pickerBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColors.bgBase)
        .task {
            await store.scanInstalledAppsIfNeeded()
        }
    }

    // MARK: Picker

    private var filteredApps: [InstalledApp] {
        let query = appSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.installedApps }
        return store.installedApps.filter {
            $0.name.lowercased().contains(query)
                || ($0.bundleID?.lowercased().contains(query) ?? false)
        }
    }

    private var pickerBody: some View {
        VStack(spacing: 8) {
            HStack {
                UninstallSearchField(query: $appSearchQuery)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)

            pickerList
        }
    }

    @ViewBuilder
    private var pickerList: some View {
        if store.installedApps.isEmpty {
            if store.isScanningInstalledApps {
                placeholder(label: "Finding installed apps")
            } else {
                emptyState(
                    symbol: "app.badge",
                    title: "No apps found",
                    detail: "Purge looks in Applications and your home Applications folder."
                )
            }
        } else if filteredApps.isEmpty {
            emptyState(
                symbol: "magnifyingglass",
                title: "Nothing matches",
                detail: "No installed app matches \"\(appSearchQuery)\"."
            )
        } else {
            List {
                ForEach(filteredApps) { app in
                    AppPickerRow(app: app) { store.selectAppForUninstall(app) }
                        .listRowInsets(ScanListRowInsets.standard)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ScanListBottomSpacer()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppColors.bgBase)
        }
    }

    // MARK: Review

    private var visibleItemIDs: [String] {
        store.uninstallItems.map(\.id)
    }

    private func reviewBody(for app: InstalledApp) -> some View {
        VStack(spacing: 8) {
            reviewHeader(for: app)
                .padding(.horizontal, AppDetailPageLayout.horizontalInset)

            selectAllBar

            ZStack {
                reviewList(for: app)
                if store.isDeleting {
                    CleaningOverlay()
                }
            }
        }
    }

    private func reviewHeader(for app: InstalledApp) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Button {
                store.backToAppPicker()
            } label: {
                Label("All apps", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
            .fixedSize()

            Image(nsImage: appIcon(for: app))
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(app.name)
                    .font(AppStyle.Typography.rowTitle)
                    .lineLimit(1)
                if app.isRunning {
                    Text("Currently open")
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.tagCheckText)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectAllBar: some View {
        HStack(alignment: .center) {
            TriStateCheckbox(title: "Select All", state: selectAllState) {
                toggleSelectAll()
            }
            .fixedSize()
            .disabled(store.uninstallItems.isEmpty)

            Spacer()
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
    }

    private var selectAllState: SelectAllTriState {
        let ids = visibleItemIDs
        guard !ids.isEmpty else { return .none }
        let selected = store.selectedUninstallItems.count
        if selected == 0 { return .none }
        if selected == ids.count { return .all }
        return .mixed
    }

    private func toggleSelectAll() {
        let allOn = store.selectedUninstallItems.count == store.uninstallItems.count
        store.setAllUninstallItemsSelected(!allOn)
    }

    @ViewBuilder
    private func reviewList(for app: InstalledApp) -> some View {
        if store.uninstallItems.isEmpty {
            if store.isScanningUninstallLeftovers {
                placeholder(label: "Scanning \(app.name) leftovers")
            } else {
                emptyState(
                    symbol: "sparkles",
                    title: "Nothing left behind",
                    detail: "Purge found no files for \(app.name) beyond the app itself."
                )
            }
        } else {
            List {
                ForEach(store.uninstallItems) { item in
                    UninstallItemRow(item: item) {
                        store.setUninstallItemSelected(id: item.id, isSelected: !item.isSelected)
                    }
                    .listRowInsets(ScanListRowInsets.standard)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ScanListBottomSpacer()
            }
            .listStyle(.plain)
            .disablingListSelection()
            .scrollContentBackground(.hidden)
            .background(AppColors.bgBase)
        }
    }

    // MARK: Shared bits

    private func appIcon(for app: InstalledApp) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.bundleURL.path)
    }

    private func placeholder(label: String) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

private extension View {
    @ViewBuilder
    func disablingListSelection() -> some View {
        if #available(macOS 14.0, *) {
            selectionDisabled()
        } else {
            self
        }
    }
}

// MARK: - Rows

private struct AppPickerRow: View {
    let app: InstalledApp
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(AppStyle.Typography.rowTitle)
                    .lineLimit(1)
                if let bundleID = app.bundleID {
                    Text(bundleID)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: AppStyle.Spacing.xSmall)

            if app.isRunning {
                AppBadge(text: "Open", tone: .warning)
            }

            Text(app.formattedSize)
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, 10)
        .frame(minHeight: AppStyle.Row.listRowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .background {
            RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                .fill(AppColors.bgElevated)
                .overlay {
                    if isHovering {
                        RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                            .fill(AppColors.bgOverlay)
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
                .stroke(AppColors.borderSubtle)
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), \(app.formattedSize)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onSelect)
    }
}

private struct UninstallItemRow: View {
    let item: UninstallItem
    let onToggle: () -> Void

    private var badgeTone: AppBadge.Tone {
        switch item.safetyInfo.level {
        case .safe: return .safe
        case .medium: return .warning
        case .unknown: return .neutral
        }
    }

    var body: some View {
        // Whole row is one tap target, and the checkbox is a non-interactive
        // visual, for the same reason as LargeFileRow: an interactive control in
        // a macOS List row scrolls the clicked row into view on click.
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: .constant(item.isSelected))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(AppColors.buttonPrimaryBg)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Image(systemName: item.category.symbolName)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.safetyInfo.headline)
                    .font(AppStyle.Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(displayDirectoryPath(for: item.path))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Text(item.formattedSize)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                AppBadge(text: item.safetyInfo.level.displayName, tone: badgeTone)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: AppStyle.Row.listRowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .modifier(ScanRowCardChrome())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.safetyInfo.headline), \(item.formattedSize), \(item.safetyInfo.level.displayName)")
        .accessibilityValue(item.isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .accessibilityAction(.default, onToggle)
    }
}

// MARK: - Header actions (rendered by ContentView's page header)

struct UninstallHeaderActions: View {
    @EnvironmentObject private var store: PurgeStore

    var body: some View {
        if store.selectedAppForUninstall == nil {
            Button {
                Task { await store.scanInstalledApps() }
            } label: {
                CleaningButtonLabel(
                    title: store.isScanningInstalledApps ? "Scanning..." : "Rescan",
                    systemImage: store.isScanningInstalledApps ? nil : "arrow.clockwise",
                    isCleaning: store.isScanningInstalledApps
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
            .disabled(store.isScanningInstalledApps)
            .fixedSize()
        } else {
            Button {
                store.requestUninstall()
            } label: {
                AnimatedDeleteActionLabel(
                    inactiveTitle: "Uninstall",
                    activeTitle: "Uninstall",
                    selectedCount: store.selectedUninstallItems.count,
                    selectedBytes: store.selectedUninstallBytes
                )
            }
            .buttonStyle(SolidDestructiveButtonStyle())
            .disabled(store.selectedUninstallItems.isEmpty || store.isDeleting)
            .fixedSize()
        }
    }
}

// MARK: - Confirm sheet

struct UninstallConfirmSheet: View {
    let app: InstalledApp
    let items: [UninstallItem]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var totalBytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var sortedItems: [UninstallItem] {
        items.sorted { lhs, rhs in
            if lhs.category.sortOrder != rhs.category.sortOrder {
                return lhs.category.sortOrder < rhs.category.sortOrder
            }
            return lhs.sizeBytes > rhs.sizeBytes
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text("Uninstall \(app.name)?")
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text("Purge moves the app and the items you picked to the Trash. Nothing is deleted for good, so you can put them back if you change your mind.")
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if app.isRunning {
                runningNote
            }

            ScrollView {
                LazyVStack(spacing: AppStyle.Spacing.small) {
                    ForEach(sortedItems) { item in
                        itemCard(item)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 240)

            HStack(spacing: AppStyle.Spacing.small) {
                Text("Freeing \(formatBytes(totalBytes))")
                    .font(AppStyle.Typography.metadataEmphasis)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(AppButtonStyle(variant: .bordered))
                    .keyboardShortcut(.cancelAction)

                Button("Move \(items.count) to Trash", action: onConfirm)
                    .buttonStyle(SolidDestructiveButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 580, minHeight: 480)
        .background(AppColors.bgBase)
    }

    private var runningNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.tagCheckText)
                .accessibilityHidden(true)
            Text("\(app.name) is open. Purge will quit it before moving it to the Trash.")
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

    private func itemCard(_ item: UninstallItem) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Image(systemName: item.category.symbolName)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.safetyInfo.headline)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(displayDirectoryPath(for: item.path))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppStyle.Spacing.xSmall)

            Text(item.formattedSize)
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .fill(AppColors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Search field

private struct UninstallSearchField: View {
    @Binding var query: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search apps", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous)
                .fill(AppColors.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
    }
}
