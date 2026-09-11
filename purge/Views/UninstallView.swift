import AppKit
import SwiftUI

/// The Uninstall tab: a grid of installed apps, multi-selectable. Ticking apps
/// and pressing Uninstall Selected gathers each app's leftovers and opens a
/// review sheet before anything moves to the Trash.
struct UninstallView: View {
    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appSearchQuery = ""

    private static let columns = [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 12)]

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
        guard !query.isEmpty else { return store.installedApps }
        return store.installedApps.filter {
            $0.name.lowercased().contains(query)
                || ($0.bundleID?.lowercased().contains(query) ?? false)
        }
    }

    private var visibleIDs: [String] { filteredApps.map(\.id) }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            UninstallSelectAllBar(
                selectedCount: selectedVisibleCount,
                visibleCount: filteredApps.count,
                onToggleAll: toggleSelectAll
            )
            Spacer(minLength: 8)
            UninstallSearchField(query: $appSearchQuery)
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
    }

    private var selectedVisibleCount: Int {
        visibleIDs.filter { store.selectedAppIDs.contains($0) }.count
    }

    private func toggleSelectAll() {
        let ids = visibleIDs
        guard !ids.isEmpty else { return }
        let allOn = ids.allSatisfy { store.selectedAppIDs.contains($0) }
        store.setAllAppsSelected(!allOn, ids: ids)
    }

    // MARK: Grid

    @ViewBuilder
    private var grid: some View {
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
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(filteredApps) { app in
                        AppTile(
                            app: app,
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

    // MARK: Shared bits

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

// MARK: - App tile

private struct AppTile: View {
    let app: InstalledApp
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                    .resizable()
                    .frame(width: 56, height: 56)
                    .frame(maxWidth: .infinity)

                selectionMark
                    .offset(x: 4, y: -4)
            }

            VStack(spacing: 2) {
                Text(app.name)
                    .font(AppStyle.Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    if app.isRunning {
                        AppBadge(text: "Open", tone: .warning)
                    }
                    Text(app.formattedSize)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), \(app.formattedSize)\(app.isRunning ? ", open" : "")")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onToggle)
    }

    @ViewBuilder
    private var selectionMark: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(AppColors.buttonPrimaryBg)
                .background(Circle().fill(AppColors.bgElevated).padding(2))
        }
    }
}

// MARK: - Select all bar

private struct UninstallSelectAllBar: View {
    let selectedCount: Int
    let visibleCount: Int
    let onToggleAll: () -> Void

    private var state: SelectAllTriState {
        guard visibleCount > 0 else { return .none }
        if selectedCount == 0 { return .none }
        if selectedCount == visibleCount { return .all }
        return .mixed
    }

    var body: some View {
        HStack(spacing: 10) {
            TriStateCheckbox(title: "Select All", state: state, action: onToggleAll)
                .fixedSize()
                .disabled(visibleCount == 0)

            if selectedCount > 0 {
                Text("\(selectedCount) selected")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
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

            Button {
                Task { await store.requestUninstallSelectedApps() }
            } label: {
                CleaningButtonLabel(
                    title: uninstallTitle,
                    systemImage: store.isBuildingUninstallPlan ? nil : "trash",
                    isCleaning: store.isBuildingUninstallPlan,
                    spinnerTint: AppColors.buttonPrimaryText
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(AppButtonStyle(variant: .destructive, isCapsule: true))
            .disabled(store.selectedAppIDs.isEmpty || store.isBuildingUninstallPlan || store.isDeleting)
        }
        .fixedSize()
    }

    private var uninstallTitle: String {
        if store.isBuildingUninstallPlan { return "Preparing..." }
        let count = store.selectedApps.count
        if count == 0 { return "Uninstall" }
        return "Uninstall \(count) \(count == 1 ? "app" : "apps")"
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
