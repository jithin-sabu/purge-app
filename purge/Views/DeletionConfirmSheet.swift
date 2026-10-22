import SwiftUI

struct DeletionConfirmSheet: View {
    let candidates: [PurgeStore.DeletionCandidate]
    /// Ids of the picks the engine deletes permanently instead of moving to the
    /// Trash, from `PurgeStore.permanentlyDeletedCandidateIDs(in:)`.
    let permanentIDs: Set<String>
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var totalBytes: Int64 {
        candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    /// Simulators and runtimes. `simctl` deletes them, so they never reach the
    /// Trash and are listed apart from everything that does (#170).
    var permanentCandidates: [PurgeStore.DeletionCandidate] {
        candidates.filter { permanentIDs.contains($0.id) }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var trashCandidates: [PurgeStore.DeletionCandidate] {
        candidates.filter { !permanentIDs.contains($0.id) }
    }

    private var unknownCandidates: [PurgeStore.DeletionCandidate] {
        trashCandidates.filter { $0.safetyInfo.level == .unknown }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Safe + Check First only (shown as lower-risk additions in the elevated layout).
    private var benignCandidates: [PurgeStore.DeletionCandidate] {
        trashCandidates.filter { $0.safetyInfo.level == .safe || $0.safetyInfo.level == .medium }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var showsElevatedRiskLayout: Bool {
        candidates.contains { $0.safetyInfo.level == .unknown }
    }

    /// The standard layout's title, explanation and button follow where the picks
    /// go: all to the Trash, some deleted permanently, or all deleted permanently.
    var title: String {
        if permanentCandidates.isEmpty { return String(localized: "Move selected items to Trash?") }
        if trashCandidates.isEmpty { return String(localized: "Delete selected items permanently?") }
        return String(localized: "Clean selected items?")
    }

    var message: String {
        if permanentCandidates.isEmpty {
            return String(localized: "Purge moves these to Trash. You can put anything back if you change your mind.")
        }
        if trashCandidates.isEmpty {
            return String(localized: "None of these go to the Trash. Once they're deleted, you can't put them back.")
        }
        return String(localized: "Purge moves most of these to Trash, where you can put them back. The ones under Deleted Permanently can't be put back.")
    }

    var primaryButtonTitle: String {
        if permanentCandidates.isEmpty { return String(localized: "Move \(candidates.count) to Trash") }
        if trashCandidates.isEmpty { return String(localized: "Delete \(candidates.count) Permanently") }
        return String(localized: "Clean \(candidates.count) Items")
    }

    /// Check First leads, so a pick the user may not have meant is the first thing read.
    private static let groupedSectionOrder: [SafetyLevel] = [.medium, .safe]

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
        .background(AppColors.surfaceBase)
    }

    private func locationLabel(for item: PurgeStore.DeletionCandidate) -> String {
        item.subtitle ?? item.path.lastPathComponent
    }

    // MARK: - Standard layout

    private var standardLayout: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                Text(title)
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text(message)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    permanentSection
                    ForEach(groupedBenign, id: \.0) { level, items in
                        sectionHeader(level.displayName)
                        if level == .medium {
                            checkFirstNote(count: items.count)
                        }
                        ForEach(items) { item in
                            candidateCard(item)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 260)

            footer(primaryTitle: primaryButtonTitle)
        }
    }

    /// Leads both layouts when present: the one part of the cleanup that can't be
    /// put back. Each card keeps its own safety tag.
    @ViewBuilder
    private var permanentSection: some View {
        if !permanentCandidates.isEmpty {
            sectionHeader(String(localized: "Deleted permanently"))
            warningNote(String(localized: "Xcode deletes these itself. They skip the Trash, so you can't put them back."))
            ForEach(permanentCandidates) { item in
                candidateCard(item)
            }
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

                    permanentSection

                    if !benignCandidates.isEmpty {
                        sectionHeader(String(localized: "Also in this cleanup"))
                        ForEach(benignCandidates) { item in
                            candidateCard(item)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 260)

            footer(primaryTitle: String(localized: "Continue"))
        }
    }

    private var elevatedWarningHeader: some View {
        HStack(alignment: .top, spacing: AppStyle.Spacing.small) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(AppColors.statusCheckText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                Text("Some of these aren't identified")
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Purge couldn't identify every folder you picked. Only continue if you know it's safe to remove. You'll confirm once more before anything moves.")
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shared pieces

    private func checkFirstNote(count: Int) -> some View {
        warningNote(count == 1
            ? String(localized: "This one may hold something you'd miss. If you're not sure about it, cancel and untick it.")
            : String(localized: "These may hold something you'd miss. If you're not sure about one, cancel and untick it."))
    }

    private func warningNote(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.statusCheckText)
                .accessibilityHidden(true)
            Text(text)
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: AppStyle.Spacing.xSmall)

                VStack(alignment: .trailing, spacing: AppStyle.Spacing.xxSmall) {
                    Text(item.formattedSize)
                        .font(AppStyle.Typography.metadataEmphasis.numbers)
                        .foregroundStyle(AppColors.textSecondary)
                        .monospacedDigit()
                    safetyTag(for: item.safetyInfo.level)
                }
            }

            if showsExplanation, !item.safetyInfo.explanation.isEmpty {
                Text(LocalizedStringKey(item.safetyInfo.explanation))
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
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
                .fill(AppColors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
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
            fg = AppColors.statusSafeText
            bg = AppColors.statusSafeFill
        case .medium:
            text = "Check first"
            fg = AppColors.statusCheckText
            bg = AppColors.statusCheckFill
        case .unknown:
            text = "Not sure"
            fg = AppColors.statusDangerText
            bg = AppColors.statusDangerFill
        }
        return Text(LocalizedStringKey(text))
            .font(AppStyle.Typography.metadataEmphasis)
            .foregroundStyle(fg)
            .padding(.horizontal, AppStyle.Spacing.xSmall)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(bg))
    }

    private func footer(primaryTitle: String) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Text("Freeing \(formatBytes(totalBytes))")
                .font(AppStyle.Typography.metadataEmphasis.numbers)
                .foregroundStyle(AppColors.textSecondary)

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(.purge(.secondary))
                .keyboardShortcut(.cancelAction)

            Button(primaryTitle) {
                onConfirm()
            }
            .buttonStyle(.purge(.destructive))
            .keyboardShortcut(.defaultAction)
        }
    }
}
