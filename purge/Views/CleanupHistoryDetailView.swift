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
                    movedToTrashSection
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
        .background(AppColors.bgBase)
        .frame(minWidth: 480, minHeight: 320, maxHeight: 560)
    }

    private var sheetHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(entry.trigger == .scheduled ? "Automatic clean" : "Manual clean")
                .font(.headline)

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

    private var movedToTrashSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Moved to Trash")

            historySectionCard {
                ForEach(Array(entry.deletedItems.enumerated()), id: \.element.id) { index, item in
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
            sectionLabel("Skipped")

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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func deletedItemRow(_ item: CleanupHistoryDeletedItemDTO) -> some View {
        let fileURL = URL(fileURLWithPath: item.path).standardizedFileURL

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(displayDirectoryPath(for: fileURL.deletingLastPathComponent()))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if item.sizeBytes > 0 {
                Text(formatBytes(item.sizeBytes))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func skippedItemRow(_ item: CleanupHistorySkippedItemDTO) -> some View {
        let fileURL = URL(fileURLWithPath: item.path).standardizedFileURL

        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.reason)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(displayDirectoryPath(for: fileURL.deletingLastPathComponent()))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
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
                AppColors.bgElevated,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
            }
    }
}
