import SwiftUI

struct CleanupHistoryDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let entry: CleanupHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
                    summarySection
                    switch entry.kind {
                    case .appleIntelligenceModels?:
                        itemsSection(String(localized: "Released"), items: entry.deletedItems)
                    case .iCloudDownloadsRemoved?:
                        // Not "Moved to Trash": the files are where they were, as
                        // cloud placeholders, and the Trash has nothing of them (#106).
                        itemsSection(String(localized: "Removed from this Mac, still in iCloud Drive"), items: entry.deletedItems)
                    case nil:
                        // Simulators and runtimes never reach the Trash, so they get
                        // their own list instead of sitting under "Moved to Trash" (#170).
                        let permanent = entry.permanentlyDeletedItems
                        let trashed = entry.trashedItems
                        if !permanent.isEmpty {
                            itemsSection(String(localized: "Deleted permanently"), items: permanent)
                        }
                        if !trashed.isEmpty || permanent.isEmpty {
                            itemsSection(String(localized: "Moved to Trash"), items: trashed)
                        }
                    }
                    if !entry.skippedItems.isEmpty {
                        skippedSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppDetailPageLayout.horizontalInset)
                .padding(.top, AppStyle.Spacing.medium)
                .padding(.bottom, AppDetailPageLayout.verticalPadding)
            }
            .scrollContentBackground(.hidden)
        }
        .background(AppColors.surfaceBase)
        .frame(minWidth: 480, minHeight: 320, maxHeight: 560)
    }

    private var sheetHeader: some View {
        HStack(alignment: .center, spacing: AppStyle.Spacing.small) {
            Text(CleanupHistorySummaryRow.title(for: entry))
                .font(AppStyle.Typography.headline)

            Spacer(minLength: AppStyle.Spacing.small)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(.top, AppStyle.Spacing.large)
        .padding(.bottom, AppStyle.Spacing.small)
    }

    private var summarySection: some View {
        historySectionCard {
            CleanupHistorySummaryRow(entry: entry)
                .padding(.horizontal, AppStyle.Spacing.medium)
                .padding(.vertical, AppStyle.Spacing.small)
        }
    }

    private func itemsSection(_ title: String, items: [CleanupHistoryDeletedItemDTO]) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            sectionLabel(title)

            historySectionCard {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        InsetCardDivider()
                    }
                    deletedItemRow(item)
                        .padding(.horizontal, AppStyle.Spacing.medium)
                        .padding(.vertical, AppStyle.Spacing.small)
                }
            }
        }
    }

    private var skippedSection: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            sectionLabel(String(localized: "Skipped"))

            historySectionCard {
                ForEach(Array(entry.skippedItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        InsetCardDivider()
                    }
                    skippedItemRow(item)
                        .padding(.horizontal, AppStyle.Spacing.medium)
                        .padding(.vertical, AppStyle.Spacing.small)
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(AppStyle.Typography.metadata.weight(.semibold))
            .foregroundStyle(AppColors.textSecondary)
            .textCase(.uppercase)
    }

    private func deletedItemRow(_ item: CleanupHistoryDeletedItemDTO) -> some View {
        // An Apple Intelligence entry's items are model sets by name, not files.
        let isModelSet = entry.kind == .appleIntelligenceModels
        let fileURL = URL(fileURLWithPath: item.path).standardizedFileURL

        return HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.small) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text(isModelSet ? item.path : fileURL.lastPathComponent)
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                if !isModelSet {
                    Text(locationText(for: fileURL))
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: AppStyle.Spacing.small)

            if item.sizeBytes > 0 {
                Text(formatBytes(item.sizeBytes))
                    .font(AppStyle.Typography.rowTitle.numbers)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func skippedItemRow(_ item: CleanupHistorySkippedItemDTO) -> some View {
        let fileURL = URL(fileURLWithPath: item.path).standardizedFileURL

        return HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.small) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text(fileURL.lastPathComponent)
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                Text(Bundle.main.localizedString(forKey: item.reason, value: item.reason, table: nil))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(locationText(for: fileURL))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    /// The item's folder, with iCloud Drive's own folder named as Finder names it.
    private func locationText(for fileURL: URL) -> String {
        let folder = fileURL.deletingLastPathComponent()
        return LargeFile.iCloudDriveLocation(for: folder) ?? displayDirectoryPath(for: folder)
    }

    private func historySectionCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppColors.fillSecondary,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
            }
    }
}
