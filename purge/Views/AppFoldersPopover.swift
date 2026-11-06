import SwiftUI

/// "· from 3 folders" after the App Uninstaller's subtitle (#99). Shown only
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
            Text("· from \(summary.folders.count) folders")
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
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            Text("Purge lists apps from")
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textSecondary)

            VStack(spacing: 0) {
                ForEach(Array(summary.folders.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 {
                        InsetCardDivider(horizontalInset: 0)
                    }
                    row(folder)
                }
            }

            if let message {
                Text(message)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.statusCheckText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AppStyle.Spacing.small) {
                Button {
                    AppFolderAdding.chooseFolder { folder in
                        Task { message = await AppFolderAdding.add(folder, store: store) }
                    }
                } label: {
                    Label("Add folder\u{2026}", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.purge(.secondary, size: .small))
                .fixedSize()

                Spacer(minLength: AppStyle.Spacing.small)

                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.purge(.quiet, size: .small))
                    .fixedSize()
            }
        }
        .padding(AppStyle.Spacing.medium)
        .frame(width: 320)
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
            Text(folder.appCount == 1 ? String(localized: "1 app") : String(localized: "\(folder.appCount) apps"))
                .font(AppStyle.Typography.metadata.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
        }
        .padding(.vertical, AppStyle.Spacing.xSmall)
        .accessibilityElement(children: .combine)
    }
}
