import SwiftUI

/// "from 3 folders" after the App Uninstaller's app count (#99). Shown only
/// when an app comes from a drive or a folder the user added
/// (`AppFolderSummary.isWorthShowing`), in the subtitle's own grey, and
/// underlined only on hover, so it explains the extra apps to the people who
/// have them and pulls nobody else's eye.
struct AppFoldersHeaderLink: View {
    let summary: AppFolderSummary
    @EnvironmentObject private var store: PurgeStore
    @State private var isHovering = false
    @State private var isShowingPopover = false

    var body: some View {
        Button {
            isShowingPopover = true
        } label: {
            Text(summary.folders.count == 1
                ? String(localized: "from 1 folder")
                : String(localized: "from \(summary.folders.count) folders"))
                .font(AppStyle.Typography.metadata.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("See which folders Purge lists apps from")
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            AppFoldersPopover(summary: summary) {
                isShowingPopover = false
                store.selectedTab = .settings
            }
            .environmentObject(store)
        }
    }
}

/// Each folder the listed apps come from, with how many, and a way to add one.
struct AppFoldersPopover: View {
    let summary: AppFolderSummary
    let onOpenSettings: () -> Void
    @EnvironmentObject private var store: PurgeStore
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
            HStack(spacing: AppStyle.Spacing.xSmall) {
                Text("Purge lists apps from")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: AppStyle.Spacing.xSmall)
                Button(action: onOpenSettings) {
                    Label("Open Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.purge(.quiet, size: .small, width: .square))
                .help("Open Settings")
            }

            VStack(spacing: 0) {
                ForEach(summary.folders) { folder in
                    row(folder)
                    InsetCardDivider(horizontalInset: 0)
                }
                AddAppFolderRow {
                    AppFolderAdding.chooseFolder { folder in
                        Task { message = await AppFolderAdding.add(folder, store: store) }
                    }
                }
            }

            if let message {
                Text(message)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.statusCheckText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppStyle.Spacing.medium)
        .frame(width: 320)
    }

    private func countText(_ folder: AppFolderSummary.Folder) -> String {
        if !folder.isAvailable { return String(localized: "Not connected") }
        switch folder.appCount {
        case 0: return String(localized: "No apps")
        case 1: return String(localized: "1 app")
        default: return String(localized: "\(folder.appCount) apps")
        }
    }

    private func row(_ folder: AppFolderSummary.Folder) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Image(systemName: folder.kind == .drive ? "externaldrive" : "folder")
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text(folder.name)
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                if folder.kind != .builtIn {
                    Text((folder.path as NSString).abbreviatingWithTildeInPath)
                        .font(AppStyle.Typography.micro.weight(.regular))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: AppStyle.Spacing.small)
            Text(countText(folder))
                .font(AppStyle.Typography.metadata.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
        }
        .padding(.vertical, AppStyle.Spacing.xSmall)
        .accessibilityElement(children: .combine)
    }
}

/// "Add folder…" as the popover's last row, laid out like the folder rows
/// above it, with a hover wash so it reads as clickable.
private struct AddAppFolderRow: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppStyle.Spacing.small) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(AppColors.textPrimary)
                    .accessibilityHidden(true)
                Text("Add folder\u{2026}")
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, AppStyle.Spacing.xSmall)
            .padding(.horizontal, AppStyle.Spacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous)
                    .fill(isHovering ? AppColors.fillSecondaryHover : Color.clear)
            )
            .padding(.horizontal, -AppStyle.Spacing.xxSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
