import SwiftUI

/// The whole disk at a glance: how much of it each thing Purge finds takes up, and
/// the rest. Used, free and total come from the volume, so they match System Settings.
/// Cleaning happens on each tab; this page only shows where the space is.
struct OverviewView: View {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    @EnvironmentObject private var trashStore: TrashStore
    @ObservedObject private var schedule = ScheduledCleaningPreferenceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bar segment under the pointer. Its row lifts and the others fade.
    @State private var highlightedID: String?

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
                    OverviewDiskBar(
                        segments: barSegments(breakdown),
                        highlightedID: highlightedID,
                        onHover: { highlightedID = $0 }
                    )
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: highlightedID)
    }

    private func linkedRowState(_ id: String) -> OverviewLinkedRowState {
        guard let highlightedID else { return .normal }
        return highlightedID == id ? .emphasized : .dimmed
    }

    // MARK: Disk summary

    private func diskSummary(_ breakdown: OverviewBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
            Text("\(formatStorageBytes(breakdown.usedBytes)) used")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .overviewNumberTransition(breakdown.usedBytes, reduceMotion: reduceMotion)
            Text("of \(formatStorageBytes(breakdown.totalBytes))")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .overviewNumberTransition(breakdown.totalBytes, reduceMotion: reduceMotion)
            Spacer(minLength: AppStyle.Spacing.small)
            // Right end, above the free part of the bar.
            Text("\(formatStorageBytes(breakdown.freeBytes)) free")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .overviewNumberTransition(breakdown.freeBytes, reduceMotion: reduceMotion)
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
            id: OverviewDiskBar.everythingElseID,
            label: "Everything else",
            bytes: breakdown.everythingElseBytes,
            color: AppColors.overviewEverythingElse
        ))
        segments.append(OverviewDiskBar.Segment(
            id: OverviewDiskBar.freeID,
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
                    now: now,
                    linkedState: linkedRowState(category.rawValue)
                )
            }
        }
        .overviewCard()
    }

    private func restOfDiskCard(_ breakdown: OverviewBreakdown) -> some View {
        VStack(spacing: 0) {
            OverviewPlainRow(
                symbol: "ellipsis",
                color: AppColors.overviewEverythingElse,
                title: "Everything else",
                detail: "macOS, your documents and photos, and files Purge doesn't sort",
                bytes: breakdown.everythingElseBytes,
                share: breakdown.share(of: breakdown.everythingElseBytes),
                linkedState: linkedRowState(OverviewDiskBar.everythingElseID)
            )
            InsetCardDivider()
            OverviewPlainRow(
                color: AppColors.storageBarFree,
                title: "Free",
                detail: "Available for new files",
                bytes: breakdown.freeBytes,
                share: breakdown.share(of: breakdown.freeBytes),
                linkedState: linkedRowState(OverviewDiskBar.freeID)
            )
        }
        .overviewCard()
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

    static let trashNoteThresholdBytes: Int64 = 1_000_000_000

    private func footnoteLines(now: Date) -> [String] {
        var lines: [String] = []
        // Trash is plural (iCloud Drive keeps its own), and emptying it is the user's
        // call in Finder, so this only says where the space is. Below a gigabyte,
        // emptying it would not change anything the page shows.
        if trashStore.access == .readable, trashStore.trashBytes >= Self.trashNoteThresholdBytes {
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
    let linkedState: OverviewLinkedRowState

    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var phase: OverviewCategoryPhase { store.overviewPhase(for: category) }
    private var record: ScanRecord? { store.scanRecords[category] }
    private var isRecorded: Bool { store.isShowingRecordedFigure(for: category) }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            OverviewIconTile(
                symbol: OverviewCategoryStyle.symbol(category),
                color: OverviewCategoryStyle.tileColor(category)
            )

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
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: phase)
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, 11)
        .overviewLinked(linkedState)
        .background(isHovering || linkedState == .emphasized ? AppColors.bgElevated.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        // When the figure was measured. Only on hover: App Caches and Dev Tools rescan
        // every launch, so a time on every row would mostly say "just now".
        .help(scanTimeHelp)
        // No chevron: the hover fill and the pointing hand say the row opens its tab.
        .onHover(perform: setHovering)
        .onDisappear { setHovering(false) }
        .onTapGesture { open() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    /// Pushes the pointing hand once per hover and always pops it, so a row that
    /// goes away under the pointer cannot leave the cursor stuck.
    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private var scanTimeHelp: String {
        guard phase == .ready || phase == .notScanned, let record else { return "" }
        return "Scanned \(compactAgoText(from: record.completedAt, to: now))"
    }

    private var showsFigure: Bool {
        phase == .ready || phase == .scanning || isRecorded
    }

    /// While scanning, the text itself shimmers; a spinner beside it would come and
    /// go with every pass of the scan.
    private var statusLine: some View {
        Text(statusText)
            .lineLimit(1)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : OverviewMotion.number, value: statusText)
            .shimmeringText(phase == .scanning)
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
        case .waiting:
            // About to be measured again: no figure, not even the last one, until it scans.
            EmptyView()
        default:
            HStack(spacing: AppStyle.Spacing.small) {
                Text(OverviewCategoryStyle.shareText(share))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(.tertiary)
                    .overviewNumberTransition(share, reduceMotion: reduceMotion)
                Text(formatStorageBytes(bytes))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .overviewNumberTransition(bytes, reduceMotion: reduceMotion)
                    .foregroundStyle(isRecorded ? .secondary : .primary)
                    .frame(minWidth: 64, alignment: .trailing)
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
            return "Up next"
        case .notScanned:
            if let record, isRecorded {
                return recordedDetail(record)
            }
            return "Not scanned yet"
        case .ready:
            return liveDetail
        }
    }

    /// One fact per row, the one worth acting on. Item counts live on each tab.
    private var liveDetail: String {
        let totals = store.totals(for: category)
        switch category {
        case .appCaches, .devTools:
            return cacheDetail(safeBytes: store.safeCleanupBytes(for: category) ?? 0)
        case .largeFiles:
            return largeFilesDetail(count: totals.count)
        case .apps:
            let unused = store.installedApps.filter { app in
                guard let opened = app.lastOpened else { return false }
                return now.timeIntervalSince(opened) > 90 * 24 * 60 * 60
            }.count
            return unused > 0
                ? "\(unused) not opened in 90 days"
                : "\(totals.count) \(totals.count == 1 ? "app" : "apps")"
        case .leftovers:
            guard totals.count > 0 else { return "Nothing left behind" }
            return "\(totals.count) \(totals.count == 1 ? "item" : "items")"
        }
    }

    private func largeFilesDetail(count: Int) -> String {
        "\(count) \(count == 1 ? "file" : "files") over \(LargeFileSizeThreshold.current().label)"
    }

    private func cacheDetail(safeBytes: Int64) -> String {
        safeBytes > 0 ? "\(formatBytes(safeBytes)) safe to clean" : "Nothing safe to clean"
    }

    /// The same fact as the live line, where the record holds it.
    private func recordedDetail(_ record: ScanRecord) -> String {
        switch category {
        case .appCaches, .devTools:
            if let safeBytes = record.safeBytes {
                return cacheDetail(safeBytes: safeBytes)
            }
            return "\(record.count) \(record.count == 1 ? "item" : "items")"
        case .leftovers:
            guard record.count > 0 else { return "Nothing left behind" }
            return "\(record.count) \(record.count == 1 ? "item" : "items")"
        case .largeFiles:
            return largeFilesDetail(count: record.count)
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
        case .appCaches, .devTools:
            // The row's line is the safe-to-clean figure, so the tab opens on that
            // list with it selected, for this visit only.
            store.openFromOverview(category)
        case .largeFiles:
            store.selectedTab = .largeFiles
        case .apps:
            store.uninstallSection = .installedApps
            store.selectedTab = .uninstaller
        case .leftovers:
            store.uninstallSection = store.overviewLeftoversSection
            store.selectedTab = .uninstaller
        }
    }
}

/// A System Settings style tile: the category color with a soft top-to-bottom
/// gradient, a hairline rim, and a white filled glyph. Leave `symbol` out for an
/// empty tile, which is how free space is drawn.
private struct OverviewIconTile: View {
    var symbol: String?
    let color: Color

    static let size: CGFloat = 28
    private static let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                    .frame(width: Self.size, height: Self.size)
                    .background {
                        Self.shape
                            .fill(color)
                            // Lighter at the top, a touch darker at the bottom.
                            .overlay(Self.shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .top, endPoint: .bottom)))
                            .overlay(Self.shape.fill(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)))
                    }
                    .overlay {
                        Self.shape.strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5
                        )
                    }
            } else {
                // Free space: an empty tile, outlined in the bar's free color.
                Self.shape
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                    .frame(width: Self.size, height: Self.size)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct OverviewPlainRow: View {
    var symbol: String?
    let color: Color
    let title: String
    let detail: String
    let bytes: Int64
    let share: Double
    let linkedState: OverviewLinkedRowState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            OverviewIconTile(symbol: symbol, color: color)
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
                .overviewNumberTransition(share, reduceMotion: reduceMotion)
            Text(formatStorageBytes(bytes))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .overviewNumberTransition(bytes, reduceMotion: reduceMotion)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, 11)
        .overviewLinked(linkedState)
        .background(linkedState == .emphasized ? AppColors.bgElevated.opacity(0.5) : .clear)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bar and row highlight

/// How a row looks while the pointer is on the bar: the matching row lifts, the
/// others lose their color and fade, so the eye goes straight to the one that
/// matches. It only runs this way: hovering a row leaves the bar alone.
enum OverviewLinkedRowState: Equatable {
    case normal
    case emphasized
    case dimmed
}

private extension View {
    func overviewLinked(_ state: OverviewLinkedRowState) -> some View {
        self
            .saturation(state == .dimmed ? 0 : 1)
            .opacity(state == .dimmed ? 0.4 : 1)
    }
}

// MARK: - Card

private extension View {
    /// The card surface. Rows are clipped to its rounded shape so a row's hover fill
    /// stays inside the corners, and the border is drawn over them so the fill
    /// can't cover it.
    func overviewCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
        return self
            .background(shape.fill(AppColors.bgCard))
            .clipShape(shape)
            .overlay(shape.strokeBorder(AppColors.borderSubtle))
    }
}

// MARK: - Number transitions

extension View {
    /// Rolls a size or share to its new value the way figures do elsewhere in the
    /// app, instead of snapping on each scan update.
    func overviewNumberTransition<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        self
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : OverviewMotion.number, value: value)
    }
}

enum OverviewMotion {
    /// The app's number roll (see the page header subtitle).
    static let number = Animation.easeInOut(duration: 0.45)
    /// The disk bar's segments. A little longer than the scan's publish beat, so each
    /// update picks up from the last one mid-glide and the bar fills without steps.
    static let bar = Animation.easeOut(duration: 0.6)
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
        case .appCaches: return "internaldrive.fill"
        case .devTools: return "hammer.fill"
        case .largeFiles: return "doc.fill"
        case .apps: return "square.grid.2x2.fill"
        case .leftovers: return "shippingbox.fill"
        }
    }

    /// The icon tile's color: the bar color, deepened where white would not show or
    /// the two blues would run together.
    static func tileColor(_ category: OverviewCategory) -> Color {
        switch category {
        case .appCaches: return AppColors.overviewAppCachesTile
        case .devTools: return AppColors.overviewDevToolsTile
        case .leftovers: return AppColors.overviewLeftoversTile
        case .largeFiles, .apps: return color(category)
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
    /// The segment to keep at full strength; the rest fade. Nil shows them all.
    var highlightedID: String?
    /// The segment under the pointer, or nil when it leaves the bar.
    var onHover: (String?) -> Void = { _ in }

    static let everythingElseID = "everythingElse"
    static let freeID = "free"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 14
    private static let fadedOpacity: Double = 0.3
    private nonisolated static let gap: CGFloat = 2
    private nonisolated static let minimumWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let layout = Self.layout(for: segments.map(\.bytes), in: geometry.size.width)
            // Every segment stays in the bar, empty ones at zero width, so a category
            // that turns up mid-scan grows out of its neighbour instead of popping in,
            // and the widths animate as one. The capsule clip rounds whichever
            // segments happen to sit at the ends.
            ZStack(alignment: .leading) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Rectangle()
                        .fill(segment.color)
                        .opacity(highlightedID == nil || highlightedID == segment.id ? 1 : Self.fadedOpacity)
                        .frame(width: layout[index].width)
                        .offset(x: layout[index].x)
                }
            }
            .frame(width: geometry.size.width, height: Self.height, alignment: .leading)
            .clipShape(Capsule(style: .continuous))
            .animation(reduceMotion ? nil : OverviewMotion.bar, value: layout)
            // One hover for the whole bar, read by position: the 2 pt gaps between
            // segments then belong to the nearest one instead of flickering to nothing.
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    onHover(Self.segmentIndex(at: location.x, in: layout).map { segments[$0].id })
                case .ended:
                    onHover(nil)
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    /// The visible segment under `x`, or the nearest one when `x` falls in a gap.
    nonisolated static func segmentIndex(at x: CGFloat, in layout: [Placement]) -> Int? {
        let visible = layout.indices.filter { layout[$0].width > 0 }
        if let hit = visible.first(where: { x >= layout[$0].x && x <= layout[$0].x + layout[$0].width }) {
            return hit
        }
        return visible.min { distance(x, to: layout[$0]) < distance(x, to: layout[$1]) }
    }

    private nonisolated static func distance(_ x: CGFloat, to placement: Placement) -> CGFloat {
        x < placement.x ? placement.x - x : x - (placement.x + placement.width)
    }

    nonisolated struct Placement: Equatable, Sendable {
        let x: CGFloat
        let width: CGFloat
    }

    /// Where each segment sits, empty ones included at zero width. The gap goes
    /// before every visible segment but the first.
    nonisolated static func layout(for bytes: [Int64], in totalWidth: CGFloat) -> [Placement] {
        let visibleIndices = bytes.indices.filter { bytes[$0] > 0 }
        let visibleWidths = widths(for: visibleIndices.map { bytes[$0] }, in: totalWidth)
        var placements = [Placement]()
        placements.reserveCapacity(bytes.count)
        var x: CGFloat = 0
        var visibleIndex = 0
        for index in bytes.indices {
            guard bytes[index] > 0 else {
                placements.append(Placement(x: x, width: 0))
                continue
            }
            if visibleIndex > 0 { x += gap }
            let width = visibleWidths[visibleIndex]
            placements.append(Placement(x: x, width: width))
            x += width
            visibleIndex += 1
        }
        return placements
    }

    private var accessibilityText: String {
        segments
            .filter { $0.bytes > 0 }
            .map { "\($0.label) \(formatStorageBytes($0.bytes))" }
            .joined(separator: ", ")
    }

    nonisolated static func widths(for bytes: [Int64], in totalWidth: CGFloat) -> [CGFloat] {
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
