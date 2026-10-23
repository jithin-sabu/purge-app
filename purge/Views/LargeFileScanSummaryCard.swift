import AppKit
import SwiftUI

/// The heading an empty Large Files list gets, from what the scan skipped (#230).
/// One state at a time, the most urgent first: a folder the scan couldn't open
/// beats everything, because the result may be missing files.
nonisolated enum LargeFileEmptyState: Equatable {
    case nothingLarge
    case cloudOnly
    case library
    case incomplete

    static func resolve(_ summary: LargeFileScanSummary?) -> LargeFileEmptyState {
        guard let summary else { return .nothingLarge }
        if !summary.unreadableRoots.isEmpty { return .incomplete }
        if summary.cloudOnlyCount > 0 { return .cloudOnly }
        if !summary.skippedLibraries.isEmpty { return .library }
        return .nothingLarge
    }

    var title: String {
        switch self {
        case .nothingLarge, .library: return String(localized: "No Large Files Found")
        case .cloudOnly: return String(localized: "No Large Files on This Mac")
        case .incomplete: return String(localized: "Scan Incomplete")
        }
    }

    var symbol: String {
        switch self {
        case .nothingLarge: return "tray.full"
        case .cloudOnly: return "icloud"
        case .library: return "photo.on.rectangle"
        case .incomplete: return "exclamationmark.triangle"
        }
    }

    var symbolColor: Color {
        switch self {
        case .nothingLarge, .cloudOnly, .library: return AppColors.textSecondary
        case .incomplete: return AppColors.statusCheckText
        }
    }
}

/// One card that says where the files over the threshold are: on this Mac, with
/// a cloud provider, or inside a media library. A bar in the Overview colours,
/// a legend row per place, then footer rows for the filters, a folder that
/// couldn't be read, and the folders checked.
///
/// Under a list with rows it drops the heading and the empty-list footers and
/// shows the same bar with a real "On this Mac" segment.
struct LargeFileScanSummaryCard: View {
    /// The filters and actions only an empty list shows.
    struct EmptyListFooters {
        let ageLabel: String
        /// The next step down from the current size filter, or nil at the lowest.
        let lowerThreshold: LargeFileSizeThreshold?
        let onTryLowerThreshold: () -> Void
    }

    let summary: LargeFileScanSummary
    let onThisMacCount: Int
    let onThisMacBytes: Int64
    var emptyListFooters: EmptyListFooters?

    private static let thisMacID = "thisMac"
    private static let swatchSize: CGFloat = 10
    /// Providers take the Overview's cool colours in a fixed order, so iCloud is
    /// always the first blue. Libraries take the Leftovers pink.
    private static let providerColors: [Color] = [
        AppColors.Chart.appCaches, AppColors.Chart.devTools,
        AppColors.Chart.appCachesTile, AppColors.Chart.devToolsTile
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text("Files over \(thresholdLabel)")
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: AppStyle.Spacing.xSmall)
                Text(Self.countText(count: totalCount, bytes: totalBytes))
                    .font(AppStyle.Typography.callout.numbers)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            }

            OverviewDiskBar(segments: segments)
                .background(Capsule(style: .continuous).fill(AppColors.fillSecondary))

            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                legendRow(
                    color: onThisMacBytes > 0 ? AppColors.Chart.largeFiles : nil,
                    label: String(localized: "On this Mac"),
                    value: Self.countText(count: onThisMacCount, bytes: onThisMacBytes)
                )
                ForEach(Array(summary.cloudOnly.enumerated()), id: \.element.id) { index, group in
                    legendRow(
                        color: Self.providerColor(index),
                        label: String(localized: "\(group.provider.displayName), not downloaded"),
                        value: Self.countText(count: group.count, bytes: group.bytes)
                    )
                }
                ForEach(summary.skippedLibraries) { library in
                    legendRow(
                        color: AppColors.Chart.leftovers,
                        label: String(localized: "Inside \(library.name)"),
                        caption: String(localized: "Purge never lists files inside a library"),
                        value: formatBytes(library.bytes),
                        button: library.appName.map { app in
                            (String(localized: "Open \(app)"), { NSWorkspace.shared.open(library.path) })
                        }
                    )
                }
            }

            if let footers = emptyListFooters {
                footerRow(
                    symbol: "calendar",
                    tint: AppColors.textSecondary,
                    text: footers.ageLabel,
                    button: footers.lowerThreshold.map { lower in
                        (String(localized: "Try \(lower.label)"), footers.onTryLowerThreshold)
                    }
                )
            }
            // Large Files only scans with Full Disk Access, so a root that still
            // can't be read failed for another reason: macOS's own words say which.
            ForEach(summary.unreadableRoots) { root in
                footerRow(
                    symbol: "exclamationmark.triangle",
                    tint: AppColors.statusCheckText,
                    text: Self.unreadableText(root),
                    button: nil
                )
            }
            if emptyListFooters != nil, !summary.checkedRoots.isEmpty {
                footerRow(
                    symbol: "checkmark",
                    tint: AppColors.textSecondary,
                    text: String(localized: "Checked \(checkedList)"),
                    button: nil
                )
            }
        }
        .padding(AppStyle.Spacing.medium)
        .overviewCard()
        .accessibilityElement(children: .contain)
    }

    // MARK: Pieces

    private func legendRow(
        color: Color?,
        label: String,
        caption: String? = nil,
        value: String,
        button: (title: String, action: () -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: AppStyle.Spacing.xSmall) {
            swatch(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textPrimary)
                if let caption {
                    Text(caption)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: AppStyle.Spacing.xSmall)
            Text(value)
                .font(AppStyle.Typography.callout.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
            if let button {
                Button(button.title, action: button.action)
                    .buttonStyle(.purge(.secondary, size: .small))
            }
        }
    }

    /// A filled square for a place that holds bytes, a dashed one for "On this
    /// Mac" when nothing is here: the bar has no segment to point at.
    @ViewBuilder
    private func swatch(_ color: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppStyle.Radius.xs, style: .continuous)
        if let color {
            shape.fill(color).frame(width: Self.swatchSize, height: Self.swatchSize)
        } else {
            shape.strokeBorder(AppColors.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: Self.swatchSize, height: Self.swatchSize)
        }
    }

    private func footerRow(
        symbol: String,
        tint: Color,
        text: String,
        button: (title: String, action: () -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            InsetCardDivider(horizontalInset: 0)
            HStack(spacing: AppStyle.Spacing.xSmall) {
                Image(systemName: symbol)
                    .font(AppStyle.Typography.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: Self.swatchSize + 4)
                Text(text)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: AppStyle.Spacing.xSmall)
                if let button {
                    Button(button.title, action: button.action)
                        .buttonStyle(.purge(.secondary, size: .small))
                }
            }
        }
    }

    // MARK: Data

    private var segments: [OverviewDiskBar.Segment] {
        var segments = [OverviewDiskBar.Segment(
            id: Self.thisMacID,
            label: String(localized: "On this Mac"),
            bytes: onThisMacBytes,
            color: AppColors.Chart.largeFiles
        )]
        for (index, group) in summary.cloudOnly.enumerated() {
            segments.append(OverviewDiskBar.Segment(
                id: "cloud-\(group.id)",
                label: group.provider.displayName,
                bytes: group.bytes,
                color: Self.providerColor(index)
            ))
        }
        for library in summary.skippedLibraries {
            segments.append(OverviewDiskBar.Segment(
                id: "library-\(library.id)",
                label: library.name,
                bytes: library.bytes,
                color: AppColors.Chart.leftovers
            ))
        }
        return segments
    }

    private static func providerColor(_ index: Int) -> Color {
        providerColors[index % providerColors.count]
    }

    private var totalCount: Int { onThisMacCount + summary.cloudOnlyCount }
    private var totalBytes: Int64 { onThisMacBytes + summary.cloudOnlyBytes + summary.libraryBytes }

    private var thresholdLabel: String {
        LargeFileSizeThreshold.allCases.first { $0.bytes == summary.minBytes }?.label
            ?? formatBytes(summary.minBytes)
    }

    private var checkedList: String {
        let names = summary.checkedRoots.map(LargeFileScanSummary.rootName)
        return ListFormatter.localizedString(byJoining: names)
    }

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
