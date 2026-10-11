import SwiftUI

struct CleanupHistorySummaryRow: View {
    let entry: CleanupHistoryEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(for: entry))
                    .font(scheduleStatusPrimaryFont)
                    .foregroundStyle(AppColors.textPrimary)

                Text(Self.historyDateFormatter.string(from: entry.date))
                    .font(scheduleStatusTertiaryFont)
                    .foregroundStyle(AppColors.textTertiary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(primaryFigure)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)

                Text(detailText)
                    .font(scheduleStatusTertiaryFont)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func title(for entry: CleanupHistoryEntry) -> LocalizedStringKey {
        if entry.kind == .appleIntelligenceModels { return LocalizedStringKey("Apple Intelligence models removed") }
        return entry.trigger == .scheduled ? LocalizedStringKey("Automatic clean") : LocalizedStringKey("Manual clean")
    }

    /// Moved bytes for a clean. For the Apple Intelligence models nothing was
    /// moved, so the measured gain leads, or says it was not measured.
    private var primaryFigure: String {
        guard entry.kind == .appleIntelligenceModels else { return formatBytes(entry.bytesMovedToTrash) }
        guard let reclaimed = entry.bytesReclaimedOnVolume else { return String(localized: "Not measured") }
        return formatBytes(reclaimed)
    }

    /// Reclaimed is shown only for entries where it was measured. Older entries and
    /// cleans that only trashed files have nothing measured to show, so they stay
    /// described as moved.
    private var detailText: String {
        if entry.kind == .appleIntelligenceModels {
            let apple = entry.deletedItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let sets = entry.deletedItems.count == 1 ? String(localized: "1 model set") : String(localized: "\(entry.deletedItems.count) model sets")
            return String(localized: "\(sets) released, Apple counted \(formatBytes(apple))")
        }
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
