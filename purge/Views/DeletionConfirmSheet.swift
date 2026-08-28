import SwiftUI

struct DeletionConfirmSheet: View {
    let candidates: [PurgeStore.DeletionCandidate]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var totalBytes: Int64 {
        candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    private var unknownCandidates: [PurgeStore.DeletionCandidate] {
        candidates.filter { $0.safetyInfo.level == .unknown }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Safe + Check First only (shown as lower-risk additions in the elevated layout).
    private var benignCandidates: [PurgeStore.DeletionCandidate] {
        candidates.filter { $0.safetyInfo.level == .safe || $0.safetyInfo.level == .medium }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var showsElevatedRiskLayout: Bool {
        !unknownCandidates.isEmpty
    }

    private static let groupedSectionOrder: [SafetyLevel] = [.safe, .medium]

    private var groupedBenign: [(SafetyLevel, [PurgeStore.DeletionCandidate])] {
        let grouped = Dictionary(grouping: benignCandidates, by: { $0.safetyInfo.level })
        return Self.groupedSectionOrder.compactMap { level in
            guard let values = grouped[level], !values.isEmpty else { return nil }
            return (level, values.sorted { $0.sizeBytes > $1.sizeBytes })
        }
    }

    var body: some View {
        Group {
            if showsElevatedRiskLayout {
                elevatedRiskLayout
            } else {
                standardLayout
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(minWidth: 580, minHeight: showsElevatedRiskLayout ? 520 : 500)
        .background(AppColors.bgBase)
    }

    private func locationLabel(for item: PurgeStore.DeletionCandidate) -> String {
        item.subtitle ?? item.path.lastPathComponent
    }

    // MARK: - Standard layout

    private var standardLayout: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text("Move selected items to Trash?")
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text("Purge moves these to Trash. You can put anything back if you change your mind.")
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    ForEach(groupedBenign, id: \.0) { level, items in
                        sectionHeader(level.displayName)
                        ForEach(items) { item in
                            candidateCard(item)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 260)

            footer(primaryTitle: "Move \(candidates.count) to Trash")
        }
    }

    // MARK: - Elevated (unknown present) layout

    private var elevatedRiskLayout: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            elevatedWarningHeader

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    if !unknownCandidates.isEmpty {
                        sectionHeader(SafetyLevel.unknown.displayName)
                        Text("Purge couldn't work out what these folders are. Only continue if you know what they hold.")
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(unknownCandidates) { item in
                            candidateCard(item, showsExplanation: true)
                        }
                    }

                    if !benignCandidates.isEmpty {
                        sectionHeader("Also in this cleanup")
                        ForEach(benignCandidates) { item in
                            candidateCard(item)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 260)

            footer(primaryTitle: "Continue")
        }
    }

    private var elevatedWarningHeader: some View {
        HStack(alignment: .top, spacing: AppStyle.Spacing.small) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(AppColors.tagCheckText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                Text("Some of these aren't identified")
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Purge couldn't identify every folder you picked. Only continue if you know it's safe to remove. You'll confirm once more before anything moves.")
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shared pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppStyle.Typography.metadataEmphasis)
            .foregroundStyle(AppColors.textTertiary)
            .textCase(.uppercase)
            .padding(.top, AppStyle.Spacing.xSmall)
    }

    /// One deletion candidate as a card: its name, folder, and size, plus a safety
    /// tag and the reinstall hint when there is one. `showsExplanation` adds the
    /// safety explanation, used for the unknown items in the elevated layout.
    private func candidateCard(
        _ item: PurgeStore.DeletionCandidate,
        showsExplanation: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
            HStack(spacing: AppStyle.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(AppStyle.Typography.rowTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(locationLabel(for: item))
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let command = item.reinstallCommand, !command.isEmpty {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AppColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: AppStyle.Spacing.xSmall)

                VStack(alignment: .trailing, spacing: AppStyle.Spacing.xxSmall) {
                    Text(item.formattedSize)
                        .font(AppStyle.Typography.metadataEmphasis)
                        .foregroundStyle(AppColors.textSecondary)
                        .monospacedDigit()
                    safetyTag(for: item.safetyInfo.level)
                }
            }

            if showsExplanation, !item.safetyInfo.explanation.isEmpty {
                Text(item.safetyInfo.explanation)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    private func safetyTag(for level: SafetyLevel) -> some View {
        let text: String
        let fg: Color
        let bg: Color
        switch level {
        case .safe:
            text = "Safe"
            fg = AppColors.tagSafeText
            bg = AppColors.tagSafeBg
        case .medium:
            text = "Check first"
            fg = AppColors.tagCheckText
            bg = AppColors.tagCheckBg
        case .unknown:
            text = "Not sure"
            fg = AppColors.tagDangerText
            bg = AppColors.tagDangerBg
        }
        return Text(text)
            .font(AppStyle.Typography.metadataEmphasis)
            .foregroundStyle(fg)
            .padding(.horizontal, AppStyle.Spacing.xSmall)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(bg))
    }

    private func footer(primaryTitle: String) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Text("Freeing \(formatBytes(totalBytes))")
                .font(AppStyle.Typography.metadataEmphasis)
                .foregroundStyle(AppColors.textSecondary)

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(AppButtonStyle(variant: .bordered))
                .keyboardShortcut(.cancelAction)

            Button(primaryTitle) {
                onConfirm()
            }
            .buttonStyle(SolidDestructiveButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }
}
