import SwiftUI

struct UnknownDeleteConfirmSheet: View {
    let candidates: [PurgeStore.DeletionCandidate]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var primaryTitle: String {
        candidates.first?.title ?? ""
    }

    private var totalBytes: Int64 {
        candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var sharedExplanation: String {
        candidates.first?.safetyInfo.explanation ?? ""
    }

    private func locationLabel(for item: PurgeStore.DeletionCandidate) -> String {
        item.subtitle ?? item.path.lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            header

            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text(primaryTitle)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)

                if candidates.count > 1 {
                    Text("\(candidates.count) locations will be removed.")
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }

            ScrollView {
                LazyVStack(spacing: AppStyle.Spacing.small) {
                    ForEach(candidates, id: \.path) { item in
                        locationCard(item)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 200)

            explanationCard

            HStack(spacing: AppStyle.Spacing.small) {
                Text("Freeing \(formatBytes(totalBytes))")
                    .font(AppStyle.Typography.metadataEmphasis)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(AppButtonStyle(variant: .bordered))
                    .keyboardShortcut(.cancelAction)

                Button("Continue") {
                    onConfirm()
                }
                .buttonStyle(SolidDestructiveButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 520, minHeight: 460)
        .background(AppColors.bgBase)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppStyle.Spacing.small) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(AppColors.tagCheckText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                Text("We're not sure what this is")
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Purge couldn't identify this file. Only delete it if you know what it is. It can't be put back afterward.")
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func locationCard(_ item: PurgeStore.DeletionCandidate) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Text(locationLabel(for: item))
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

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

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
            Text(SafetyLevel.unknown.displayName)
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.tagDangerText)

            if !sharedExplanation.isEmpty {
                Text(sharedExplanation)
                    .font(.callout)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppStyle.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous)
                .fill(AppColors.tagDangerBg)
        )
    }
}
