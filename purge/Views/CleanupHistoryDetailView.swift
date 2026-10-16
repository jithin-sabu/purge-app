import SwiftUI

struct CleanupHistoryDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let entry: CleanupHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summarySection
                    if entry.kind == .appleIntelligenceModels {
                        itemsSection(String(localized: "Released"), items: entry.deletedItems)
                    } else {
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
                .padding(.top, 16)
                .padding(.bottom, AppDetailPageLayout.verticalPadding)
            }
            .scrollContentBackground(.hidden)
        }
        .background(AppColors.surfaceBase)
        .frame(minWidth: 480, minHeight: 320, maxHeight: 560)
    }

    private var sheetHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(CleanupHistorySummaryRow.title(for: entry))
                .font(AppStyle.Typography.headline)

            Spacer(minLength: 12)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var summarySection: some View {
        historySectionCard {
            CleanupHistorySummaryRow(entry: entry)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private func itemsSection(_ title: String, items: [CleanupHistoryDeletedItemDTO]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(title)

            historySectionCard {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        InsetCardDivider()
                    }
                    deletedItemRow(item)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private var skippedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(String(localized: "Skipped"))

            historySectionCard {
                ForEach(Array(entry.skippedItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        InsetCardDivider()
                    }
                    skippedItemRow(item)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
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

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isModelSet ? item.path : fileURL.lastPathComponent)
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                if !isModelSet {
                    Text(displayDirectoryPath(for: fileURL.deletingLastPathComponent()))
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if item.sizeBytes > 0 {
                Text(formatBytes(item.sizeBytes))
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func skippedItemRow(_ item: CleanupHistorySkippedItemDTO) -> some View {
        let fileURL = URL(fileURLWithPath: item.path).standardizedFileURL

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fileURL.lastPathComponent)
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                Text(Bundle.main.localizedString(forKey: item.reason, value: item.reason, table: nil))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(displayDirectoryPath(for: fileURL.deletingLastPathComponent()))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
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
