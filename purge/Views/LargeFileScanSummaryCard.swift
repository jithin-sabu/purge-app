import SwiftUI

/// The heading an empty Large Files list gets, from what the scan skipped (#230).
/// One state at a time, the most urgent first: a folder the scan couldn't open
/// beats everything, because the result may be missing files.
nonisolated enum LargeFileEmptyState: Equatable {
    case nothingLarge
    case cloudOnly
    case incomplete

    static func resolve(_ summary: LargeFileScanSummary?) -> LargeFileEmptyState {
        guard let summary else { return .nothingLarge }
        if !summary.unreadableRoots.isEmpty { return .incomplete }
        if summary.cloudOnlyCount > 0 { return .cloudOnly }
        return .nothingLarge
    }

    var title: String {
        switch self {
        case .nothingLarge: return String(localized: "No Large Files Found")
        case .cloudOnly: return String(localized: "No Large Files on This Mac")
        case .incomplete: return String(localized: "Scan Incomplete")
        }
    }

    var symbol: String {
        switch self {
        case .nothingLarge: return "tray.full"
        case .cloudOnly: return "icloud"
        case .incomplete: return "exclamationmark.triangle"
        }
    }

    var symbolColor: Color {
        switch self {
        case .nothingLarge, .cloudOnly: return AppColors.textSecondary
        case .incomplete: return AppColors.statusCheckText
        }
    }
}

/// Where the files over the threshold went when none of them are on this Mac:
/// a folder the scan couldn't open or a cloud provider. One plain row per
/// place, with its size. Only an empty list shows it. A media library is left
/// out: it is no file of its own, and Purge never lists what is inside one.
struct LargeFileScanSummaryCard: View {
    let summary: LargeFileScanSummary

    /// Whether the summary has a row to show. With none the card is left out.
    static func hasRows(_ summary: LargeFileScanSummary) -> Bool {
        !summary.unreadableRoots.isEmpty || !summary.cloudOnly.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            // Large Files only scans with Full Disk Access, so a root that still
            // can't be read failed for another reason: macOS's own words say which.
            ForEach(summary.unreadableRoots) { root in
                HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(AppStyle.Typography.callout.weight(.semibold))
                        .foregroundStyle(AppColors.statusCheckText)
                    Text(Self.unreadableText(root))
                        .font(AppStyle.Typography.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                }
            }
            ForEach(summary.cloudOnly) { group in
                row(
                    label: String(localized: "\(group.provider.displayName), not downloaded"),
                    value: Self.countText(count: group.count, bytes: group.bytes)
                )
            }
        }
        .padding(AppStyle.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overviewCard()
        .accessibilityElement(children: .contain)
    }

    private func row(label: String, value: String) -> some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Text(label)
                .font(AppStyle.Typography.body)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppStyle.Spacing.xSmall)
            Text(value)
                .font(AppStyle.Typography.callout.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    // MARK: Data

    /// "Documents couldn't be read. You don't have permission to access the folder."
    static func unreadableText(_ root: LargeFileScanSummary.UnreadableRoot) -> String {
        let lead = String(localized: "\(root.name) couldn't be read.")
        let reason = root.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? lead : "\(lead) \(reason)"
    }

    /// "14 files · 9.8 GB", or "0 files" when there is no size to give.
    static func countText(count: Int, bytes: Int64) -> String {
        let size = formatBytes(bytes)
        switch (count, bytes > 0) {
        case (1, true): return String(localized: "1 file · \(size)")
        case (1, false): return String(localized: "1 file")
        case (_, true): return String(localized: "\(count) files · \(size)")
        case (_, false): return String(localized: "\(count) files")
        }
    }
}
