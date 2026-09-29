import SwiftUI

/// The whole disk at a glance: how much of it each thing Purge finds takes up, and
/// the rest. Used, free and total come from the volume, so they match System Settings.
/// Cleaning happens on each tab; this page only shows where the space is.
struct OverviewView: View {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    @EnvironmentObject private var trashStore: TrashStore
    @ObservedObject private var schedule = ScheduledCleaningPreferenceStore.shared

    var body: some View {
        // Relative times ("Scanned 3h ago") move on their own.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let breakdown = store.overviewBreakdown(
            totalBytes: diskStore.totalDiskBytes,
            freeBytes: diskStore.freeDiskBytes
        )
        VStack(alignment: .leading, spacing: AppStyle.Spacing.large) {
            if breakdown.totalBytes > 0 {
                VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                    diskSummary(breakdown)
                    OverviewDiskBar(segments: barSegments(breakdown))
                }
            }

            categoriesCard(breakdown, now: now)

            if breakdown.totalBytes > 0 {
                restOfDiskCard(breakdown)
            }

            footnotes(now: now)
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(.bottom, AppStyle.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Disk summary

    private func diskSummary(_ breakdown: OverviewBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
            Text("\(formatStorageBytes(breakdown.usedBytes)) used")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("of \(formatStorageBytes(breakdown.totalBytes)) · \(formatStorageBytes(breakdown.freeBytes)) free")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func barSegments(_ breakdown: OverviewBreakdown) -> [OverviewDiskBar.Segment] {
        var segments = OverviewCategory.allCases.map { category in
            OverviewDiskBar.Segment(
                id: category.rawValue,
                label: OverviewCategoryStyle.name(category),
                bytes: breakdown.bytes(for: category),
                color: OverviewCategoryStyle.color(category)
            )
        }
        segments.append(OverviewDiskBar.Segment(
            id: "everythingElse",
            label: "Everything else",
            bytes: breakdown.everythingElseBytes,
            color: AppColors.overviewEverythingElse
        ))
        segments.append(OverviewDiskBar.Segment(
            id: "free",
            label: "Free",
            bytes: breakdown.freeBytes,
            color: AppColors.storageBarFree
        ))
        return segments
    }

    // MARK: Categories

    private func categoriesCard(_ breakdown: OverviewBreakdown, now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(OverviewCategory.allCases.enumerated()), id: \.element) { index, category in
                if index > 0 {
                    InsetCardDivider()
                }
                OverviewCategoryRow(
                    category: category,
                    bytes: breakdown.bytes(for: category),
                    share: breakdown.share(of: breakdown.bytes(for: category)),
                    now: now
                )
            }
        }
        .background(cardBackground)
    }

    private func restOfDiskCard(_ breakdown: OverviewBreakdown) -> some View {
        VStack(spacing: 0) {
            OverviewPlainRow(
                color: AppColors.overviewEverythingElse,
                title: "Everything else",
                detail: "macOS, your documents and photos, and files Purge doesn't sort",
                bytes: breakdown.everythingElseBytes,
                share: breakdown.share(of: breakdown.everythingElseBytes)
            )
            InsetCardDivider()
            OverviewPlainRow(
                color: AppColors.storageBarFree,
                title: "Free",
                detail: "Available for new files",
                bytes: breakdown.freeBytes,
                share: breakdown.share(of: breakdown.freeBytes)
            )
        }
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
            .fill(AppColors.bgCard)
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle)
            }
    }

    // MARK: Footnotes

    @ViewBuilder
    private func footnotes(now: Date) -> some View {
        let lines = footnoteLines(now: now)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                }
            }
            .font(AppStyle.Typography.metadata)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footnoteLines(now: Date) -> [String] {
        var lines: [String] = []
        // Trash is plural (iCloud Drive keeps its own), and emptying it is the user's
        // call in Finder, so this only says where the space is.
        if trashStore.access == .readable, trashStore.trashBytes > 0 {
            lines.append(
                "\(formatBytes(trashStore.trashBytes)) of the used space is already in the Trash, "
                    + "including iCloud Drive. Emptying it in Finder frees it."
            )
        }
        if schedule.isEnabled {
            let next = ScheduledCleaningRegistrar.shared.nextCleanDate(referenceDate: now)
            let day = relativeDateText(for: next, referenceDate: now)
            let time = next.formatted(date: .omitted, time: .shortened)
            lines.append("Next scheduled clean: \(day) at \(time)")
        }
        return lines
    }
}

// MARK: - Category row

private struct OverviewCategoryRow: View {
    let category: OverviewCategory
    let bytes: Int64
    let share: Double
    let now: Date

    @EnvironmentObject private var store: PurgeStore
    @State private var isHovering = false

    private var phase: OverviewCategoryPhase { store.overviewPhase(for: category) }
    private var record: ScanRecord? { store.scanRecords[category] }
    private var isRecorded: Bool { store.isShowingRecordedFigure(for: category) }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            OverviewCategoryIcon(category: category)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(OverviewCategoryStyle.name(category))
                        .font(.system(size: 13, weight: .semibold))
                    if OverviewCategoryStyle.isReview(category), showsFigure {
                        AppBadge(text: "Review first", tone: .warning)
                    }
                }
                statusLine
            }

            Spacer(minLength: AppStyle.Spacing.small)

            trailing
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, 11)
        .background(isHovering ? AppColors.bgElevated.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { open() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private var showsFigure: Bool {
        phase == .ready || phase == .scanning || isRecorded
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 5) {
            if phase == .scanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            }
            Text(statusText)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case .needsAccess:
            // The header's Look deeper and the sidebar notice already ask; a button on
            // every locked row would repeat the same ask three times.
            Image(systemName: "lock")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 2)
        case .notScanned where !isRecorded:
            Button("Scan") { store.requestScan(category.step) }
                .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
        case .waiting where !isRecorded && bytes == 0:
            // Nothing found yet and no earlier figure: a "0 bytes" here would read as a result.
            EmptyView()
        default:
            HStack(spacing: AppStyle.Spacing.small) {
                Text(OverviewCategoryStyle.shareText(share))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Text(formatStorageBytes(bytes))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isRecorded || phase == .waiting ? .secondary : .primary)
                    .frame(minWidth: 64, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusText: String {
        switch phase {
        case .needsAccess:
            return "Needs Full Disk Access"
        case .scanning:
            if category == .apps, !store.isScanningInstalledApps {
                return "Measuring each app and its files…"
            }
            return "Scanning…"
        case .waiting:
            if let record, isRecorded {
                return "Up next · last scan \(compactAgoText(from: record.completedAt, to: now))"
            }
            return "Up next"
        case .notScanned:
            if let record, isRecorded {
                return "\(recordedDetail(record)) · scanned \(compactAgoText(from: record.completedAt, to: now))"
            }
            return "Not scanned yet"
        case .ready:
            return liveDetail
        }
    }

    private var liveDetail: String {
        let totals = store.totals(for: category)
        switch category {
        case .appCaches:
            return cacheDetail(count: totals.count, safeBytes: store.safeCleanupSummary.appCacheBytes)
        case .devTools:
            let summary = store.safeCleanupSummary
            return cacheDetail(count: totals.count, safeBytes: summary.devToolBytes + summary.projectArtifactBytes)
        case .largeFiles:
            let size = LargeFileSizeThreshold.current()
            let age = LargeFileAgeThreshold.current()
            let base = "\(totals.count) \(totals.count == 1 ? "file" : "files") larger than \(size.label)"
            return age == .anyTime ? base : "\(base), last used \(age.label.lowercased())"
        case .apps:
            let unused = store.installedApps.filter { app in
                guard let opened = app.lastOpened else { return false }
                return now.timeIntervalSince(opened) > 90 * 24 * 60 * 60
            }.count
            let base = "\(totals.count) \(totals.count == 1 ? "app" : "apps") and their files"
            return unused > 0 ? "\(base), \(unused) not opened in 90 days" : base
        case .leftovers:
            guard totals.count > 0 else { return "Nothing left behind by deleted apps" }
            return "\(totals.count) \(totals.count == 1 ? "item" : "items") left by apps you deleted"
        }
    }

    private func cacheDetail(count: Int, safeBytes: Int64) -> String {
        let base = "\(count) \(count == 1 ? "item" : "items")"
        return safeBytes > 0 ? "\(base), \(formatBytes(safeBytes)) safe to clean" : base
    }

    private func recordedDetail(_ record: ScanRecord) -> String {
        switch category {
        case .appCaches, .devTools, .leftovers:
            return "\(record.count) \(record.count == 1 ? "item" : "items")"
        case .largeFiles:
            return "\(record.count) \(record.count == 1 ? "file" : "files")"
        case .apps:
            return "\(record.count) \(record.count == 1 ? "app" : "apps")"
        }
    }

    private func open() {
        if phase == .needsAccess {
            store.isLookDeeperPresented = true
            return
        }
        switch category {
        case .appCaches:
            store.selectedTab = .appCaches
        case .devTools:
            store.selectedTab = .devTools
        case .largeFiles:
            store.selectedTab = .largeFiles
        case .apps:
            store.uninstallSection = .installedApps
            store.selectedTab = .uninstaller
        case .leftovers:
            store.uninstallSection = store.orphanLeftovers.isEmpty ? .installedApps : .leftovers
            store.selectedTab = .uninstaller
        }
    }
}

private struct OverviewCategoryIcon: View {
    let category: OverviewCategory

    var body: some View {
        Image(systemName: OverviewCategoryStyle.symbol(category))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(OverviewCategoryStyle.color(category))
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous)
                    .fill(AppColors.bgElevated)
            )
            .accessibilityHidden(true)
    }
}

private struct OverviewPlainRow: View {
    let color: Color
    let title: String
    let detail: String
    let bytes: Int64
    let share: Double

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AppStyle.Spacing.small)
            Text(OverviewCategoryStyle.shareText(share))
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Text(formatStorageBytes(bytes))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
            // Keeps sizes aligned with the chevron column in the card above.
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .hidden()
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Styling shared with the sidebar

enum OverviewCategoryStyle {
    static func name(_ category: OverviewCategory) -> String {
        switch category {
        case .appCaches: return "App Caches"
        case .devTools: return "Dev Tools"
        case .largeFiles: return "Large Files"
        // "Installed apps", not "Apps": System Settings has an Applications row that
        // counts only the apps themselves, and this total includes their files.
        case .apps: return "Installed apps"
        case .leftovers: return "Leftovers from deleted apps"
        }
    }

    static func symbol(_ category: OverviewCategory) -> String {
        switch category {
        case .appCaches: return "internaldrive"
        case .devTools: return "hammer"
        case .largeFiles: return "tray.full"
        case .apps: return "app"
        case .leftovers: return "shippingbox"
        }
    }

    static func color(_ category: OverviewCategory) -> Color {
        switch category {
        case .appCaches: return AppColors.overviewAppCaches
        case .devTools: return AppColors.overviewDevTools
        case .largeFiles: return AppColors.overviewLargeFiles
        case .apps: return AppColors.overviewApps
        case .leftovers: return AppColors.overviewLeftovers
        }
    }

    /// The user's own files and apps: Purge never cleans these on its own.
    static func isReview(_ category: OverviewCategory) -> Bool {
        switch category {
        case .appCaches, .devTools: return false
        case .largeFiles, .apps, .leftovers: return true
        }
    }

    static func shareText(_ share: Double) -> String {
        if share <= 0 { return "0%" }
        if share < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", share * 100)
    }
}

// MARK: - Disk bar

/// One bar for the whole disk. Small segments get a minimum width so a 3 GB cache
/// folder on a 500 GB disk is still visible; the space comes out of the largest one.
struct OverviewDiskBar: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]

    private static let height: CGFloat = 14
    private static let gap: CGFloat = 2
    private static let minimumWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let visible = segments.filter { $0.bytes > 0 }
            let widths = Self.widths(for: visible.map(\.bytes), in: geometry.size.width)
            HStack(spacing: Self.gap) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, segment in
                    segmentShape(isFirst: index == 0, isLast: index == visible.count - 1)
                        .fill(segment.color)
                        .frame(width: widths[index])
                        .help("\(segment.label): \(formatStorageBytes(segment.bytes))")
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private func segmentShape(isFirst: Bool, isLast: Bool) -> UnevenRoundedRectangle {
        let radius = Self.height / 2
        return UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? radius : 0,
            bottomLeadingRadius: isFirst ? radius : 0,
            bottomTrailingRadius: isLast ? radius : 0,
            topTrailingRadius: isLast ? radius : 0,
            style: .continuous
        )
    }

    private var accessibilityText: String {
        segments
            .filter { $0.bytes > 0 }
            .map { "\($0.label) \(formatStorageBytes($0.bytes))" }
            .joined(separator: ", ")
    }

    static func widths(for bytes: [Int64], in totalWidth: CGFloat) -> [CGFloat] {
        guard !bytes.isEmpty else { return [] }
        let available = max(0, totalWidth - gap * CGFloat(bytes.count - 1))
        let sum = bytes.reduce(0, +)
        guard sum > 0 else { return bytes.map { _ in 0 } }
        var widths = bytes.map { max(minimumWidth, available * CGFloat($0) / CGFloat(sum)) }
        let overflow = widths.reduce(0, +) - available
        if overflow > 0, let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[largest] = max(minimumWidth, widths[largest] - overflow)
        }
        return widths
    }
}

// MARK: - Header button

/// Scan Everything, or Stop while the queue runs. A running App Caches and Dev Tools
/// step always finishes (it takes seconds), so once only that is left the button just
/// shows it is scanning.
struct OverviewScanButton: View {
    @EnvironmentObject private var store: PurgeStore

    static func name(for step: ScanStep) -> String {
        switch step {
        case .cachesAndDevTools: return "App Caches and Dev Tools"
        case .largeFiles: return "Large Files"
        case .apps: return "installed apps"
        case .leftovers: return "leftovers from deleted apps"
        }
    }

    private var queue: ScanQueueState { store.scanQueue }

    private var isFinishingCacheScan: Bool {
        (queue.active == .cachesAndDevTools && queue.pending.isEmpty)
            || (!queue.isRunning && store.isScanningAll)
    }

    var body: some View {
        Button {
            if queue.isRunning {
                store.stopScans()
            } else {
                store.scanEverything()
            }
        } label: {
            CleaningButtonLabel(
                title: title,
                systemImage: systemImage,
                isCleaning: isFinishingCacheScan
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(isFinishingCacheScan || store.isDeleting)
        .help(queue.isRunning ? "Stop scanning" : "Scan App Caches, Dev Tools, Large Files and apps, one after another")
    }

    private var title: String {
        if isFinishingCacheScan { return "Scanning..." }
        return queue.isRunning ? "Stop" : "Scan Everything"
    }

    private var systemImage: String? {
        if isFinishingCacheScan { return nil }
        return queue.isRunning ? "stop.fill" : "arrow.clockwise"
    }
}
