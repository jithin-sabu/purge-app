import SwiftUI

struct CleanupHistorySummaryRow: View {
    let entry: CleanupHistoryEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.trigger == .scheduled ? "Automatic clean" : "Manual clean")
                    .font(scheduleStatusPrimaryFont)
                    .foregroundStyle(AppColors.textPrimary)

                Text(Self.historyDateFormatter.string(from: entry.date))
                    .font(scheduleStatusTertiaryFont)
                    .foregroundStyle(AppColors.textTertiary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(formatBytes(entry.bytesMovedToTrash))
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text(detailText)
                    .font(scheduleStatusTertiaryFont)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Reclaimed is shown only for entries where it was measured. Older entries and
    /// cleans that only trashed files have nothing measured to show, so they stay
    /// described as moved.
    private var detailText: String {
        let noun = entry.deletedItems.count == 1 ? String(localized: "item") : String(localized: "items")
        let items = String(localized: "\(entry.deletedItems.count) \(noun) to trash")
        guard let reclaimed = entry.bytesReclaimedOnVolume else { return items }
        return String(localized: "\(items), \(formatBytes(reclaimed)) reclaimed")
    }

    static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var scheduleStatusPrimaryFont: Font {
        AppStyle.Typography.body
    }

    private var scheduleStatusTertiaryFont: Font {
        AppStyle.Typography.metadata
    }
}
