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
        switch entry.kind {
        case .appleIntelligenceModels?:
            return LocalizedStringKey("Apple Intelligence models removed")
        case .iCloudDownloadsRemoved?:
            return LocalizedStringKey("Kept only in iCloud")
        case nil:
            return entry.trigger == .scheduled ? LocalizedStringKey("Automatic clean") : LocalizedStringKey("Manual clean")
        }
    }

    /// Moved bytes for a clean, plus what it deleted permanently. For the Apple
    /// Intelligence models nothing was moved, so the measured gain leads, or says
    /// it was not measured. Removed iCloud downloads show what they freed here.
    var primaryFigure: String {
        switch entry.kind {
        case nil:
            return formatBytes(entry.bytesMovedToTrash + entry.bytesDeletedPermanently)
        case .appleIntelligenceModels?:
            guard let reclaimed = entry.bytesReclaimedOnVolume else { return String(localized: "Not measured") }
            return formatBytes(reclaimed)
        case .iCloudDownloadsRemoved?:
            return formatBytes(entry.bytesFreedByRemovedDownloads)
        }
    }

    /// Reclaimed is shown only for entries where it was measured. Older entries and
    /// cleans that only trashed files have nothing measured to show, so they stay
    /// described as moved. Simulators and runtimes are counted as deleted, never as
    /// moved to the Trash (#170). Removed iCloud downloads say the files stay in
    /// iCloud, so nobody looks for them in the Trash (#106).
    var detailText: String {
        switch entry.kind {
        case .appleIntelligenceModels?:
            let apple = entry.deletedItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let sets = entry.deletedItems.count == 1 ? String(localized: "1 model set") : String(localized: "\(entry.deletedItems.count) model sets")
            return String(localized: "\(sets) released, Apple counted \(formatBytes(apple))")
        case .iCloudDownloadsRemoved?:
            let count = entry.deletedItems.count
            return count == 1
                ? String(localized: "1 file, still in iCloud Drive")
                : String(localized: "\(count) files, still in iCloud Drive")
        case nil:
            break
        }
        let trashed = entry.trashedItems.count
        let deleted = entry.permanentlyDeletedItems.count
        let noun = trashed == 1 ? String(localized: "item") : String(localized: "items")
        let toTrash = String(localized: "\(trashed) \(noun) to trash")
        let permanent = String(localized: "\(deleted) deleted permanently")
        let items: String
        if deleted == 0 {
            items = toTrash
        } else if trashed == 0 {
            items = permanent
        } else {
            items = String(localized: "\(toTrash), \(permanent)")
        }
        guard let reclaimed = entry.bytesReclaimedOnVolume else { return items }
        return String(localized: "\(items), \(formatBytes(reclaimed)) reclaimed")
    }

    static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var scheduleStatusPrimaryFont: AppStyle.TextStyle {
        AppStyle.Typography.body
    }

    private var scheduleStatusTertiaryFont: AppStyle.TextStyle {
        AppStyle.Typography.metadata
    }
}
