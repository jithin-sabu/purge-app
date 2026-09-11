import AppKit
import SwiftUI

/// Ordering for the app grid. Separate from Large Files' `SortOption` because the
/// date here is install date, not last-used, and the labels say so.
enum AppSortOption: String, CaseIterable, Identifiable {
    case largest
    case smallest
    case nameAZ
    case recentlyInstalled
    case oldestInstalled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largest: return "Size (largest first)"
        case .smallest: return "Size (smallest first)"
        case .nameAZ: return "Name (A to Z)"
        case .recentlyInstalled: return "Recently installed"
        case .oldestInstalled: return "Oldest installed"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .largest: return "Largest"
        case .smallest: return "Smallest"
        case .nameAZ: return "Name"
        case .recentlyInstalled: return "Newest"
        case .oldestInstalled: return "Oldest"
        }
    }

    func sorted(_ apps: [InstalledApp]) -> [InstalledApp] {
        switch self {
        case .largest: return apps.sorted { $0.bundleSizeBytes > $1.bundleSizeBytes }
        case .smallest: return apps.sorted { $0.bundleSizeBytes < $1.bundleSizeBytes }
        case .nameAZ: return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recentlyInstalled: return apps.sorted { $0.dateAdded > $1.dateAdded }
        case .oldestInstalled: return apps.sorted { $0.dateAdded < $1.dateAdded }
        }
    }
}

/// The Uninstall tab: a grid of installed apps, multi-selectable. Ticking apps
/// and pressing Uninstall Selected gathers each app's leftovers and opens a
/// review sheet before anything moves to the Trash.
struct UninstallView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appSearchQuery = ""
    @AppStorage("sort.uninstaller") private var sortRaw = AppSortOption.largest.rawValue

    private var currentSort: AppSortOption {
        AppSortOption(rawValue: sortRaw) ?? .largest
    }

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 4
    )

    var body: some View {
        VStack(spacing: 8) {
            controls
            grid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColors.bgBase)
        .task {
            await store.scanInstalledAppsIfNeeded()
        }
    }

    private var filteredApps: [InstalledApp] {
        let query = appSearchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let matched: [InstalledApp]
        if query.isEmpty {
            matched = store.installedApps
        } else {
            matched = store.installedApps.filter {
                $0.name.lowercased().contains(query)
                    || ($0.bundleID?.lowercased().contains(query) ?? false)
            }
        }
        return sortedApps(matched)
    }

    /// Size sorts key on the total shown on each tile (bundle + safe leftovers),
    /// but only once every app is measured — otherwise the grid would reshuffle
    /// tile by tile as the background pass lands. Name and date never wait.
    private func sortedApps(_ apps: [InstalledApp]) -> [InstalledApp] {
        switch currentSort {
        case .largest where store.hasMeasuredAllRemovableTotals:
            return apps.sorted { store.removableBytes(for: $0) > store.removableBytes(for: $1) }
        case .smallest where store.hasMeasuredAllRemovableTotals:
            return apps.sorted { store.removableBytes(for: $0) < store.removableBytes(for: $1) }
        default:
            return currentSort.sorted(apps)
        }
    }

    // MARK: Controls

    // No Select All here on purpose: selecting every installed app for removal is
    // not something anyone means to do, and offering it invites an accident.

    private var controls: some View {
        HStack(spacing: 12) {
            AppDropdown(
                options: AppSortOption.allCases,
                selection: currentSort,
                optionLabel: { $0.displayName },
                onSelect: { sortRaw = $0.rawValue }
            ) {
                FilterChip(
                    style: .dropdown,
                    label: currentSort.shortDisplayName,
                    leadingSystemImage: "arrow.up.arrow.down"
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Sort apps")
            .accessibilityValue(currentSort.displayName)

            Spacer(minLength: 8)
            UninstallSearchField(query: $appSearchQuery)
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
    }

    // MARK: Grid

    private var isLoadingApps: Bool {
        store.isScanningInstalledApps && store.installedApps.isEmpty
    }

    @ViewBuilder
    private var grid: some View {
        if store.installedApps.isEmpty && !store.isScanningInstalledApps {
            emptyState(
                symbol: "app.badge",
                title: "No apps found",
                detail: "Purge looks in Applications and your home Applications folder."
            )
        } else {
            // Crossfade the skeleton into the real grid instead of swapping view
            // trees, so the load resolves smoothly rather than popping in.
            ScanContentCrossfade(isLoading: isLoadingApps, contentAlignment: .top) {
                skeletonGrid
            } loaded: {
                loadedGrid
            }
        }
    }

    @ViewBuilder
    private var loadedGrid: some View {
        if store.installedApps.isEmpty {
            // Held behind the skeleton while the first scan runs; nothing to show.
            Color.clear
        } else if filteredApps.isEmpty {
            emptyState(
                symbol: "magnifyingglass",
                title: "Nothing matches",
                detail: "No installed app matches \"\(appSearchQuery)\"."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(filteredApps) { app in
                        AppTile(
                            app: app,
                            totalBytes: store.removableBytes(for: app),
                            isSelected: store.selectedAppIDs.contains(app.id)
                        ) {
                            store.toggleAppSelected(id: app.id)
                        }
                    }
                }
                .padding(.horizontal, AppDetailPageLayout.horizontalInset)
                .padding(.top, 2)
                .padding(.bottom, AppStyle.Spacing.large)
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.bgBase)
        }
    }

    // MARK: Loading

    /// Shown while the first scan sizes every bundle: a grid of placeholder tiles
    /// in the real tile's shape, so the list crossfades in without a layout jump.
    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(0..<20, id: \.self) { _ in
                    SkeletonAppTile()
                }
            }
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
            .padding(.top, 2)
            .padding(.bottom, AppStyle.Spacing.large)
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bgBase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finding installed apps")
    }

    // MARK: Shared bits

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

// MARK: - App tile

/// Shared so the real tile and the loading skeleton are the exact same size.
private enum AppTileMetrics {
    /// Height of the content column (icon + name + size), before the card padding.
    static let contentHeight: CGFloat = 96
}

private struct AppTile: View {
    let app: InstalledApp
    /// Bundle plus safe leftovers once measured, bundle size until then.
    let totalBytes: Int64
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                .resizable()
                .frame(width: 56, height: 56)
                .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(app.name)
                    .font(AppStyle.Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    if app.isRunning {
                        AppBadge(text: "Open", tone: .warning)
                    }
                    Text(formatBytes(totalBytes))
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppTileMetrics.contentHeight)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .fill(AppColors.bgElevated)
                .overlay {
                    if isSelected || isHovering {
                        RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                            .fill(AppColors.bgOverlay)
                    }
                }
        }
        .overlay(alignment: .topLeading) {
            // Always shown, so an untouched tile still reads as selectable: a
            // hollow circle at rest, filled when picked, brighter on hover.
            selectionIndicator
                .padding(10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .stroke(
                    isSelected ? AppColors.buttonPrimaryBg : AppColors.borderSubtle,
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        // Full name on hover, since the tile truncates longer ones.
        .help(app.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), \(app.formattedSize)\(app.isRunning ? ", open" : "")")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onToggle)
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(AppColors.buttonPrimaryBg)
                .background(Circle().fill(AppColors.bgElevated).padding(1))
        } else {
            Image(systemName: "circle")
                .font(.system(size: 20))
                .foregroundStyle(isHovering ? AppColors.textSecondary : AppColors.textTertiary)
                .background(Circle().fill(AppColors.bgElevated).padding(1))
        }
    }
}

// MARK: - Skeleton tile

private struct SkeletonAppTile: View {
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(SkeletonOpacity.medium))
                .frame(width: 56, height: 56)

            VStack(spacing: 6) {
                SkeletonBar(width: 96, height: 12, cornerRadius: 4)
                SkeletonBar(width: 52, height: 10, cornerRadius: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppTileMetrics.contentHeight)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .fill(AppColors.bgElevated)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .stroke(AppColors.borderSubtle, lineWidth: 1)
        }
        .shimmering()
        .accessibilityHidden(true)
    }
}

// MARK: - Header actions (rendered by ContentView's page header)

struct UninstallHeaderActions: View {
    @EnvironmentObject private var store: PurgeStore

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
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

            // Same widening delete label as Large Files: compact ("Uninstall")
            // with nothing ticked, growing to carry the count and size as apps are
            // selected, so Rescan slides over to make room in one motion. While the
            // plan is being gathered it shows a spinner in place.
            Button {
                Task { await store.requestUninstallSelectedApps() }
            } label: {
                Group {
                    if store.isBuildingUninstallPlan {
                        CleaningButtonLabel(
                            title: "Preparing...",
                            systemImage: nil,
                            isCleaning: true,
                            spinnerTint: AppColors.buttonPrimaryText
                        )
                    } else {
                        AnimatedDeleteActionLabel(
                            inactiveTitle: "Uninstall",
                            activeTitle: "Uninstall",
                            selectedCount: store.selectedApps.count,
                            selectedBytes: store.selectedAppsRemovableBytes
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(AppButtonStyle(variant: .destructive, isCapsule: true))
            .disabled(store.selectedAppIDs.isEmpty || store.isBuildingUninstallPlan || store.isDeleting)
        }
        .fixedSize()
    }
}

// MARK: - Review sheet

struct UninstallReviewSheet: View {
    @State private var plan: UninstallPlan
    let onCancel: () -> Void
    let onConfirm: (UninstallPlan) -> Void

    init(
        plan: UninstallPlan,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (UninstallPlan) -> Void
    ) {
        _plan = State(initialValue: plan)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
                    ForEach($plan.apps) { $appPlan in
                        appSection($appPlan)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 280)

            footer
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 600, minHeight: 540)
        .background(AppColors.bgBase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
            Text(titleText)
                .font(AppStyle.Typography.pageTitle)
                .foregroundStyle(AppColors.textPrimary)

            Text("Purge moves each app and the items you keep ticked to the Trash. Nothing is deleted for good, so you can put anything back if you change your mind.")
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleText: String {
        let count = plan.apps.count
        if count == 1 { return "Uninstall \(plan.apps[0].app.name)?" }
        return "Uninstall \(count) apps?"
    }

    private func appSection(_ appPlan: Binding<UninstallAppPlan>) -> some View {
        let app = appPlan.wrappedValue.app
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: AppStyle.Spacing.small) {
                TriStateCheckbox(
                    title: "",
                    state: selectAllState(appPlan.wrappedValue),
                    action: { toggleAll(appPlan) }
                )
                .fixedSize()
                .accessibilityLabel("Select all \(app.name) items")

                Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(app.name)
                    .font(AppStyle.Typography.rowTitle)
                if app.isRunning {
                    Text("will be quit first")
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.tagCheckText)
                }
                Spacer()
                Text(formatBytes(appPlan.wrappedValue.selectedBytes))
                    .font(AppStyle.Typography.metadataEmphasis)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            }

            ForEach(appPlan.items) { $item in
                itemRow($item)
            }
        }
    }

    private func selectAllState(_ appPlan: UninstallAppPlan) -> SelectAllTriState {
        let total = appPlan.items.count
        guard total > 0 else { return .none }
        let selected = appPlan.selectedItems.count
        if selected == 0 { return .none }
        if selected == total { return .all }
        return .mixed
    }

    private func toggleAll(_ appPlan: Binding<UninstallAppPlan>) {
        let allOn = appPlan.wrappedValue.items.allSatisfy(\.isSelected)
        for index in appPlan.wrappedValue.items.indices {
            appPlan.wrappedValue.items[index].isSelected = !allOn
        }
    }

    private func itemRow(_ item: Binding<UninstallItem>) -> some View {
        let value = item.wrappedValue
        return HStack(spacing: AppStyle.Spacing.small) {
            Toggle("", isOn: item.isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(AppColors.buttonPrimaryBg)

            Image(systemName: value.category.symbolName)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(value.safetyInfo.headline)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(displayDirectoryPath(for: value.path))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppStyle.Spacing.xSmall)

            AppBadge(
                text: value.safetyInfo.level.displayName,
                tone: value.safetyInfo.level == .safe ? .safe : .warning
            )

            Text(value.formattedSize)
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

    private var footer: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Text("Freeing \(formatBytes(plan.totalSelectedBytes))")
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.textSecondary)

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(AppButtonStyle(variant: .bordered))
                .keyboardShortcut(.cancelAction)

            Button("Move \(plan.totalSelectedItems) to Trash") {
                onConfirm(plan)
            }
            .buttonStyle(SolidDestructiveButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(plan.totalSelectedItems == 0)
        }
    }
}

// MARK: - Search field

private struct UninstallSearchField: View {
    @Binding var query: String
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasText: Bool { !query.isEmpty }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)

            TextField("Search apps", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textPrimary)
                .focused($isFocused)
                .accessibilityLabel("Search apps by name")
                .onExitCommand {
                    if hasText { query = "" } else { isFocused = false }
                }

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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: 240)
        .background {
            Capsule(style: .continuous).fill(AppColors.bgElevated)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    isFocused ? AppColors.buttonPrimaryBg : AppColors.borderSubtle,
                    lineWidth: 1
                )
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { isFocused = true }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isFocused)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hasText)
    }
}
