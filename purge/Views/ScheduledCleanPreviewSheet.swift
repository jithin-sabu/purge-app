import SwiftUI

/// The first scheduled clean, shown before anything moves (#331). Lists every
/// Safe item the clean would move to the Trash, with its path and size, and
/// waits. Clean moves them and counts as this period's scheduled clean; Not Now
/// moves nothing, and the list comes back later.
struct ScheduledCleanPreviewSheet: View {
    let preview: ScheduledCleanPreview
    let onNotNow: () -> Void
    let onClean: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text("Your first scheduled clean")
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text("Purge is about to clean on a schedule for the first time. These Safe items would move to the Trash, where you can put them back. Nothing moves until you choose Move to Trash.")
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    ForEach(preview.sortedCandidates) { item in
                        row(item)
                    }
                }
                .padding(.vertical, AppStyle.Spacing.xxxSmall)
            }
            .frame(minHeight: 260)

            Text("After this, scheduled cleans move Safe items to the Trash on their own. You can turn them off in Settings.")
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            RemovalSheetFooter(
                sizeLine: RemovalSizeLine.text(toTrash: preview.totalBytes),
                cancelTitle: "Not Now",
                confirmTitle: String(localized: "Move \(preview.candidates.count) to Trash"),
                itemCount: preview.candidates.count,
                onCancel: onNotNow,
                onConfirm: onClean
            )
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 580, minHeight: 500)
        .background(AppColors.surfaceBase)
    }

    /// One item: its name, the folder it would move, and its size.
    private func row(_ item: PurgeStore.DeletionCandidate) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text(item.title)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((item.path.path as NSString).abbreviatingWithTildeInPath)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path.path)
            }

            Spacer(minLength: AppStyle.Spacing.xSmall)

            VStack(alignment: .trailing, spacing: AppStyle.Spacing.xxSmall) {
                Text(item.formattedSize)
                    .font(AppStyle.Typography.metadataEmphasis.numbers)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
                AppBadge(level: item.safetyInfo.level)
            }
        }
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .fill(AppColors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
    }
}
