import AppKit
import SwiftUI

/// Ordering for the app grid. Separate from Large Files' `SortOption` because the
/// date here is install date, not last-used, and the labels say so.
///
/// Default is name: leftover sizes must never reshuffle the list. Size order is
/// offered only after every app's total has been measured, and is not persisted.
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

    /// Size order keys on leftover-inclusive totals, which are not known until
    /// the background pass finishes. Name and date never wait.
    var needsFullMeasurement: Bool {
        switch self {
        case .largest, .smallest: return true
        case .nameAZ, .recentlyInstalled, .oldestInstalled: return false
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

private enum UninstallAppViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .grid: return "Grid"
        }
    }

    var symbolName: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

/// The Uninstall tab: a list or grid of installed apps, multi-selectable. Ticking apps
/// and pressing Uninstall Selected gathers each app's leftovers and opens a
/// review sheet before anything moves to the Trash.
struct UninstallView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appSearchQuery = ""
    /// Session-only: leaving this tab rebuilds the view, and a launch starts
    /// fresh, so size sort never survives a trip away from Uninstall.
    @State private var selectedSort = AppSortOption.nameAZ
    /// Grid is the first-run default; after that, honor the user's preferred
    /// density across tab changes and launches.
    @AppStorage("view.uninstaller.mode") private var viewMode = UninstallAppViewMode.grid
    @AppStorage("sort.leftovers") private var leftoversSortRaw = SortOption.sizeDesc.rawValue

    /// The active view lives on the store so the tab header can swap its action
    /// button to match; this view reads and writes it through `store`.
    private var section: UninstallSection { store.uninstallSection }

    /// The Leftovers segment appears only once a scan has found something, so the
    /// tab looks exactly as before for the common case of no orphans.
    private var showsLeftoversSegment: Bool {
        !store.orphanLeftovers.isEmpty
    }

    private var currentSort: AppSortOption {
        if selectedSort.needsFullMeasurement, !store.hasMeasuredAllRemovableTotals {
            return .nameAZ
        }
        return selectedSort
    }

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 4
    )

    /// Soft, near-critically damped spring so tiles glide to their new slots
    /// without a hard snap or an under-damped overshoot.
    private let tileReorderAnimation: Animation = .spring(response: 0.38, dampingFraction: 0.92)

    /// Shared geometry for sort reorders so the same app slides to its new slot
    /// instead of fading out in one place and in from another.
    @Namespace private var listReorderNamespace
    @Namespace private var gridReorderNamespace

    var body: some View {
        VStack(spacing: 8) {
            controls
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColors.bgBase)
        .task {
            await store.scanInstalledAppsIfNeeded()
            await store.scanOrphanLeftoversIfNeeded()
        }
        // The Leftovers segment can vanish (all removed, or a rescan finds none)
        // while it is the active view; fall back to the apps so the tab never
        // shows a segment that is no longer there.
        .onChange(of: showsLeftoversSegment) { shows in
            if !shows { store.uninstallSection = .installedApps }
        }
        .onChange(of: store.hasMeasuredAllRemovableTotals) { measured in
            if !measured, selectedSort.needsFullMeasurement {
                selectedSort = .nameAZ
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .installedApps:
            appsContent
        case .leftovers:
            leftoversScroll
        }
    }

    private var leftoversSort: SortOption {
        SortOption(rawValue: leftoversSortRaw) ?? .sizeDesc
    }

    private var sortedOrphans: [UninstallItem] {
        let items = store.orphanLeftovers
        switch leftoversSort {
        case .sizeDesc: return items.sorted { $0.sizeBytes > $1.sizeBytes }
        case .sizeAsc: return items.sorted { $0.sizeBytes < $1.sizeBytes }
        case .dateNewest: return items.sorted { $0.lastModified > $1.lastModified }
        case .dateOldest: return items.sorted { $0.lastModified < $1.lastModified }
        case .nameAZ:
            return items.sorted {
                $0.safetyInfo.headline.localizedCaseInsensitiveCompare($1.safetyInfo.headline) == .orderedAscending
            }
        }
    }

    /// The leftovers segment: a pinned Select All + sort row (matching the App
    /// Caches / Dev Tools chrome), then the rows in their own scroll below.
    @ViewBuilder
    private var leftoversScroll: some View {
        if store.orphanLeftovers.isEmpty {
            // Only reachable in the brief window between the last item being
            // removed and the segment falling back to Installed Apps.
            Color.clear
        } else {
            VStack(spacing: 0) {
                leftoversToolbar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(sortedOrphans) { item in
                            orphanRow(item)
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
    }

    private var leftoversSelectAllState: SelectAllTriState {
        let items = store.orphanLeftovers
        guard !items.isEmpty else { return .none }
        let selected = items.filter { store.orphanSelectedIDs.contains($0.id) }.count
        if selected == 0 { return .none }
        if selected == items.count { return .all }
        return .mixed
    }

    private var leftoversToolbar: some View {
        HStack(alignment: .bottom) {
            TriStateCheckbox(title: "Select All", state: leftoversSelectAllState) {
                let ids = store.orphanLeftovers.map(\.id)
                store.setAllOrphansSelected(leftoversSelectAllState != .all, ids: ids)
            }
            .fixedSize()
            Spacer()
            AppSortMenu(selection: Binding(
                get: { leftoversSort },
                set: { leftoversSortRaw = $0.rawValue }
            ))
        }
        .scanTabSelectAllRowLayout()
    }

    private func orphanRow(_ item: UninstallItem) -> some View {
        let isSelected = store.orphanSelectedIDs.contains(item.id)
        return HStack(spacing: AppStyle.Spacing.small) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in store.toggleOrphanSelected(id: item.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .tint(AppColors.buttonPrimaryBg)

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
        .contentShape(Rectangle())
        .onTapGesture { store.toggleOrphanSelected(id: item.id) }
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

    /// Size sorts key on the total shown on each tile (bundle + all leftovers),
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
            if showsLeftoversSegment {
                sectionSegments
            }

            // Sort, search and view mode apply to installed apps only; hide
            // them on the
            // leftovers view so its controls (Select all, Remove) stand alone.
            if section == .installedApps {
                AppDropdown(
                    options: AppSortOption.allCases,
                    selection: currentSort,
                    optionLabel: { $0.displayName },
                    isOptionEnabled: { option in
                        !option.needsFullMeasurement || store.hasMeasuredAllRemovableTotals
                    },
                    onSelect: { option in
                        guard option != selectedSort else { return }
                        if reduceMotion {
                            selectedSort = option
                        } else {
                            withAnimation(tileReorderAnimation) { selectedSort = option }
                        }
                    }
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
                viewModePicker
            } else {
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
    }

    /// The Installed Apps / Leftovers switcher, reusing the tab-style chip the
    /// App Caches safety filter uses so it reads as a first-class view switch.
    private var sectionSegments: some View {
        HStack(spacing: 4) {
            segmentChip(.installedApps, count: nil)
            segmentChip(.leftovers, count: store.orphanLeftovers.count)
        }
    }

    private func segmentChip(_ target: UninstallSection, count: Int?) -> some View {
        let isOn = section == target
        return Button {
            if reduceMotion {
                store.uninstallSection = target
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { store.uninstallSection = target }
            }
        } label: {
            FilterChip(
                style: .tab,
                label: target.label,
                isSelected: isOn,
                tier: target == .leftovers ? .checkFirst : .neutral,
                leadingSystemImage: target.symbolName,
                count: count
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(target.label), \($0) items" } ?? target.label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var viewModePicker: some View {
        UninstallViewModeSwitcher(selection: $viewMode)
    }

    // MARK: App collection

    private var isLoadingApps: Bool {
        store.isScanningInstalledApps && store.installedApps.isEmpty
    }

    @ViewBuilder
    private var appsContent: some View {
        if store.installedApps.isEmpty && !store.isScanningInstalledApps {
            emptyState(
                symbol: "app.badge",
                title: "No apps found",
                detail: "Purge looks in Applications and your home Applications folder."
            )
        } else {
            // Crossfade the skeleton into the real collection instead of swapping view
            // trees, so the load resolves smoothly rather than popping in.
            ScanContentCrossfade(isLoading: isLoadingApps, contentAlignment: .top) {
                loadingApps
            } loaded: {
                loadedApps
            }
        }
    }

    @ViewBuilder
    private var loadedApps: some View {
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
            switch viewMode {
            case .list:
                loadedList
            case .grid:
                loadedGrid
            }
        }
    }

    private var loadedList: some View {
        ScrollView {
            // Non-lazy so every row stays in the hierarchy and can slide to its
            // new index on sort. LazyVStack treats reorders as remove + insert.
            VStack(spacing: 6) {
                ForEach(filteredApps) { app in
                    AppListRow(
                        app: app,
                        totalBytes: store.removableBytes(for: app),
                        isSizePending: store.removableBytes(for: app) == 0
                            && !store.hasMeasuredAllRemovableTotals,
                        isSelected: store.selectedAppIDs.contains(app.id)
                    ) {
                        store.toggleAppSelected(id: app.id)
                    }
                    .matchedGeometryEffect(id: app.id, in: listReorderNamespace)
                }
            }
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
            .padding(.top, 2)
            .padding(.bottom, AppStyle.Spacing.large)
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bgBase)
        // Layout animations may draw a moving row beyond its final slot.
        // Keep that intermediate drawing inside the visible collection viewport.
        .clipped()
    }

    private var loadedGrid: some View {
        ScrollView {
            // Non-lazy so tiles keep identity across sort and slide in place.
            // LazyVGrid recycles cells and makes reorders look like fly-ins.
            VStack(spacing: 12) {
                ForEach(gridRows, id: \.startIndex) { row in
                    HStack(spacing: 12) {
                        ForEach(row.apps) { app in
                            AppTile(
                                app: app,
                                totalBytes: store.removableBytes(for: app),
                                isSizePending: store.removableBytes(for: app) == 0
                                    && !store.hasMeasuredAllRemovableTotals,
                                isSelected: store.selectedAppIDs.contains(app.id)
                            ) {
                                store.toggleAppSelected(id: app.id)
                            }
                            .matchedGeometryEffect(id: app.id, in: gridReorderNamespace)
                            .frame(maxWidth: .infinity)
                        }

                        // Keep the last row's columns aligned with the ones above.
                        ForEach(0..<row.leadingPad, id: \.self) { _ in
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
            .padding(.top, 2)
            .padding(.bottom, AppStyle.Spacing.large)
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bgBase)
        // Reordering edge tiles must not paint over the surrounding window.
        .clipped()
    }

    private struct AppGridRow: Identifiable {
        let startIndex: Int
        let apps: ArraySlice<InstalledApp>
        var id: Int { startIndex }
        var leadingPad: Int { max(0, 4 - apps.count) }
    }

    private var gridRows: [AppGridRow] {
        let apps = filteredApps
        var rows: [AppGridRow] = []
        var index = 0
        while index < apps.count {
            let end = min(index + 4, apps.count)
            rows.append(AppGridRow(startIndex: index, apps: apps[index..<end]))
            index = end
        }
        return rows
    }

    // MARK: Loading

    @ViewBuilder
    private var loadingApps: some View {
        switch viewMode {
        case .list:
            skeletonList
        case .grid:
            skeletonGrid
        }
    }

    private var skeletonList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(0..<12, id: \.self) { _ in
                    SkeletonAppListRow()
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

    /// Shown while the first scan discovers app bundles. It normally lasts only
    /// until the first app is emitted; sizes continue to settle in the real view.
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

// MARK: - View mode switcher

/// One pill, two segments — same idea as a segmented control, but the active
/// thumb uses a quiet overlay instead of the native white highlight.
private struct UninstallViewModeSwitcher: View {
    @Binding var selection: UninstallAppViewMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let segmentWidth: CGFloat = 30
    private static let inset: CGFloat = 2

    var body: some View {
        HStack(spacing: 0) {
            ForEach(UninstallAppViewMode.allCases) { mode in
                segment(mode)
            }
        }
        .padding(Self.inset)
        .background {
            Capsule(style: .continuous)
                .fill(AppColors.bgElevated)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App view")
    }

    private func segment(_ mode: UninstallAppViewMode) -> some View {
        let isOn = selection == mode
        return Button {
            guard selection != mode else { return }
            if reduceMotion {
                selection = mode
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { selection = mode }
            }
        } label: {
            Image(systemName: mode.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? AppColors.textPrimary : AppColors.textSecondary)
                .frame(width: Self.segmentWidth, height: AppStyle.Control.height - (Self.inset * 2))
                .background {
                    if isOn {
                        Capsule(style: .continuous)
                            // Quiet lift over the track — avoids the native white thumb.
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(mode.label)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - App list row

private struct AppListRow: View {
    let app: InstalledApp
    let totalBytes: Int64
    let isSizePending: Bool
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            // Same pattern as App Caches: a native checkbox for appearance, with
            // selection driven by the whole-row tap so AppKit doesn't steal focus.
            Toggle("", isOn: .constant(isSelected))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(AppColors.buttonPrimaryBg)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Image(nsImage: BrandIconService.shared.installedAppIcon(at: app.bundleURL))
                .resizable()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(app.bundleURL.deletingLastPathComponent().path)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppStyle.Spacing.small)

            Text(isSizePending ? "…" : formatBytes(totalBytes))
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .fill(isSelected || isHovering ? AppColors.bgOverlay : AppColors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        .help(app.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(app.name), \(isSizePending ? "calculating size" : formatBytes(totalBytes))"
        )
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onToggle)
    }
}

private struct SkeletonAppListRow: View {
    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.secondary.opacity(SkeletonOpacity.medium), lineWidth: 1)
                .frame(width: 14, height: 14)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(SkeletonOpacity.medium))
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 6) {
                SkeletonBar(width: 120, height: 12, cornerRadius: 4)
                SkeletonBar(width: 180, height: 9, cornerRadius: 4)
            }

            Spacer()
            SkeletonBar(width: 54, height: 10, cornerRadius: 4)
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .fill(AppColors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
        .shimmering()
        .accessibilityHidden(true)
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
    /// Bundle plus all matched leftovers once measured, bundle size until then.
    let totalBytes: Int64
    /// True while this tile still has no size to show (Spotlight and `du` pending).
    let isSizePending: Bool
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: BrandIconService.shared.installedAppIcon(at: app.bundleURL))
                .resizable()
                .frame(width: 56, height: 56)
                .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(app.name)
                    .font(AppStyle.Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(isSizePending ? "…" : formatBytes(totalBytes))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
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
        .accessibilityLabel("\(app.name), \(isSizePending ? "calculating size" : formatBytes(totalBytes))")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var onLeftovers: Bool { store.uninstallSection == .leftovers }

    /// Rescan refreshes both lists on this tab, so the button reflects either scan.
    private var isScanning: Bool {
        store.isScanningInstalledApps || store.isScanningOrphans
    }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Button {
                Task {
                    await store.scanInstalledApps()
                    await store.scanOrphanLeftovers()
                }
            } label: {
                CleaningButtonLabel(
                    title: isScanning ? "Scanning..." : "Rescan",
                    systemImage: isScanning ? nil : "arrow.clockwise",
                    isCleaning: isScanning
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
            .disabled(isScanning)

            // One destructive button whose job follows the active segment: Uninstall
            // for the app grid, Remove for leftovers. Crossfading between them keeps
            // the header from jumping as the user switches views.
            ZStack {
                if onLeftovers {
                    removeLeftoversButton
                } else {
                    uninstallAppsButton
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: onLeftovers)
        }
        .fixedSize()
    }

    // Same widening delete label as Large Files: compact ("Uninstall") with
    // nothing ticked, growing to carry the count and size as apps are selected.
    // While the plan is being gathered it shows a spinner in place.
    private var uninstallAppsButton: some View {
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
                        selectedBytes: nil
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .buttonStyle(AppButtonStyle(variant: .destructive, isCapsule: true))
        .disabled(store.selectedAppIDs.isEmpty || store.isBuildingUninstallPlan || store.isDeleting)
        .transition(.opacity)
    }

    private var removeLeftoversButton: some View {
        Button {
            store.requestOrphanCleanup()
        } label: {
            AnimatedDeleteActionLabel(
                inactiveTitle: "Remove",
                activeTitle: "Remove",
                selectedCount: store.selectedOrphanCount,
                selectedBytes: store.selectedOrphanBytes
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .buttonStyle(AppButtonStyle(variant: .destructive, isCapsule: true))
        .disabled(store.selectedOrphanCount == 0 || store.isDeleting)
        .transition(.opacity)
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

                Image(nsImage: BrandIconService.shared.installedAppIcon(at: app.bundleURL))
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

    /// Tri-state over the items the user can actually tick. Items kept for a
    /// surviving app are locked off, so they never count toward "all".
    private func selectAllState(_ appPlan: UninstallAppPlan) -> SelectAllTriState {
        let toggleable = appPlan.items.filter { !$0.isKeptForOtherApp }
        guard !toggleable.isEmpty else { return .none }
        let selected = toggleable.filter(\.isSelected).count
        if selected == 0 { return .none }
        if selected == toggleable.count { return .all }
        return .mixed
    }

    private func toggleAll(_ appPlan: Binding<UninstallAppPlan>) {
        let indices = appPlan.wrappedValue.items.indices.filter {
            !appPlan.wrappedValue.items[$0].isKeptForOtherApp
        }
        let allOn = indices.allSatisfy { appPlan.wrappedValue.items[$0].isSelected }
        for index in indices {
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
                // Locked off: while the other app is installed, the deletion pass
                // holds this file back regardless, so the tick must not imply
                // otherwise.
                .disabled(value.isKeptForOtherApp)

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
                if let keptForApp = value.keptForApp {
                    Text("Kept, still used by \(keptForApp)")
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.tagCheckText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: AppStyle.Spacing.xSmall)

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

// MARK: - Orphan review sheet

struct OrphanReviewSheet: View {
    @State private var plan: OrphanCleanupPlan
    let onCancel: () -> Void
    let onConfirm: (OrphanCleanupPlan) -> Void

    init(
        plan: OrphanCleanupPlan,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (OrphanCleanupPlan) -> Void
    ) {
        _plan = State(initialValue: plan)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach($plan.items) { $item in
                        itemRow($item)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 260)

            footer
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 600, minHeight: 520)
        .background(AppColors.bgBase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
            Text("Remove leftovers from removed apps?")
                .font(AppStyle.Typography.pageTitle)
                .foregroundStyle(AppColors.textPrimary)
            Text("These folders belong to apps you no longer have installed. This is app data, not a rebuildable cache, so it will not come back on its own. Everything moves to the Trash, so you can put it back until you empty it.")
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
    /// Local mouse-down monitor installed only while focused; see
    /// `installOutsideClickResign`.
    @State private var outsideClickMonitor: Any?

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
                .focusEffectDisabledIfAvailable()
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
        .frame(width: 180)
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
        .onChange(of: isFocused) { focused in
            if focused { installOutsideClickResign() } else { removeOutsideClickResign() }
        }
        .onDisappear { removeOutsideClickResign() }
    }

    /// SwiftUI leaves a focused TextField's first responder in place when a click
    /// lands on anything non-focusable (tiles, empty space), so the capsule border
    /// and caret used to stick. While focused, a local monitor resigns first
    /// responder for any mouse-down that didn't land on the field editor itself.
    private func installOutsideClickResign() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let hitView = window.contentView?.hitTest(event.locationInWindow),
                  hitView !== window.firstResponder
            else { return event }
            window.makeFirstResponder(nil)
            return event
        }
    }

    private func removeOutsideClickResign() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}

private extension View {
    @ViewBuilder
    func focusEffectDisabledIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}
