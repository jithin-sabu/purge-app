import SwiftUI

/// The whole disk at a glance: how much of it each thing Purge finds takes up, and
/// the rest. Used, free and total come from the volume, so they match System Settings.
/// The header's Clean button moves the safe part of App Caches and Dev Tools in one
/// go; everything else is cleaned by hand on its tab.
struct OverviewView: View {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    @EnvironmentObject private var trashStore: TrashStore
    @ObservedObject private var schedule = ScheduledCleaningPreferenceStore.shared
    @ObservedObject private var snapshotStore = LocalSnapshotStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bar segment under the pointer. Its row lifts and the others fade.
    @State private var highlightedID: String?

    var body: some View {
        // Relative times ("Scanned 3h ago") move on their own.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .task { await snapshotStore.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await snapshotStore.refresh() }
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
                restOfDiskCard(breakdown, now: now)
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
                .font(AppStyle.Typography.title.weight(.bold))
                .overviewNumberTransition(breakdown.usedBytes, reduceMotion: reduceMotion)
            Text("of \(formatStorageBytes(breakdown.totalBytes))")
                .font(AppStyle.Typography.rowTitle)
                .foregroundStyle(AppColors.textSecondary)
                .overviewNumberTransition(breakdown.totalBytes, reduceMotion: reduceMotion)
            Spacer(minLength: AppStyle.Spacing.small)
            // Right end, above the free part of the bar.
            Text("\(formatStorageBytes(breakdown.freeBytes)) free")
                .font(AppStyle.Typography.rowTitle)
                .foregroundStyle(AppColors.textSecondary)
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
            label: String(localized: "Everything else"),
            bytes: breakdown.everythingElseBytes,
            color: AppColors.Chart.everythingElse
        ))
        segments.append(OverviewDiskBar.Segment(
            id: OverviewDiskBar.freeID,
            label: String(localized: "Free"),
            bytes: breakdown.freeBytes,
            color: AppColors.Chart.freeSpace
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

    private func restOfDiskCard(_ breakdown: OverviewBreakdown, now: Date) -> some View {
        VStack(spacing: 0) {
            OverviewPlainRow(
                symbol: "ellipsis",
                color: AppColors.Chart.everythingElse,
                title: String(localized: "Everything else"),
                detail: String(localized: "macOS, your documents and photos, and files Purge doesn't sort"),
                bytes: breakdown.everythingElseBytes,
                share: breakdown.share(of: breakdown.everythingElseBytes),
                linkedState: linkedRowState(OverviewDiskBar.everythingElseID)
            )
            // Part of the used space above, but no tool says how much, so it is a
            // row of its own with no size and no place in the bar.
            // Always shown, even with none, so people learn these exist and where
            // to find them when they do.
            InsetCardDivider()
            OverviewSnapshotRow(
                snapshotStore: snapshotStore,
                now: now,
                linkedState: linkedRowState(OverviewSnapshotRow.id)
            )
            InsetCardDivider()
            OverviewPlainRow(
                color: AppColors.Chart.freeSpace,
                title: String(localized: "Free"),
                detail: String(localized: "Available for new files"),
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
            .foregroundStyle(AppColors.textTertiary)
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
                String(localized: "\(formatBytes(trashStore.trashBytes)) of the used space is already in the Trash, including iCloud Drive. Emptying it in Finder frees it.")
            )
        }
        if schedule.isEnabled {
            let next = ScheduledCleaningRegistrar.shared.nextCleanDate(referenceDate: now)
            let day = relativeDateText(for: next, referenceDate: now)
            let time = next.formatted(date: .omitted, time: .shortened)
            lines.append(String(localized: "Next scheduled clean: \(day) at \(time)"))
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
                        .font(AppStyle.Typography.headline)
                    if OverviewCategoryStyle.isReview(category), showsFigure {
                        AppBadge(text: String(localized: "Review first"), tone: .warning)
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
        .background(isHovering || linkedState == .emphasized ? AppColors.fillSecondary.opacity(0.5) : .clear)
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
        return String(localized: "Scanned \(compactAgoText(from: record.completedAt, to: now))")
    }

    private var showsFigure: Bool {
        phase == .ready || phase == .scanning || isRecorded
    }

    /// While scanning, the text itself shimmers; a spinner beside it would come and
    /// go with every pass of the scan.
    private var statusLine: some View {
        Text(statusText)
            .lineLimit(1)
            .font(AppStyle.Typography.callout)
            .foregroundStyle(AppColors.textSecondary)
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
                .foregroundStyle(AppColors.textTertiary)
                .padding(.trailing, 2)
        case .notScanned where !isRecorded:
            Button("Scan") { store.requestScan(category.step) }
                .buttonStyle(.purge(.secondary))
        case .waiting:
            // About to be measured again: no figure, not even the last one, until it scans.
            EmptyView()
        default:
            HStack(spacing: AppStyle.Spacing.small) {
                Text(OverviewCategoryStyle.shareText(share))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textTertiary)
                    .overviewNumberTransition(share, reduceMotion: reduceMotion)
                Text(formatStorageBytes(bytes))
                    .font(AppStyle.Typography.sectionTitle)
                    .overviewNumberTransition(bytes, reduceMotion: reduceMotion)
                    .foregroundStyle(isRecorded ? AppColors.textSecondary : AppColors.textPrimary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
    }

    private var statusText: String {
        switch phase {
        case .needsAccess:
            return String(localized: "Needs Full Disk Access")
        case .scanning:
            if category == .apps, !store.isScanningInstalledApps {
                return String(localized: "Measuring each app and its files…")
            }
            return String(localized: "Scanning…")
        case .waiting:
            return String(localized: "Up next")
        case .notScanned:
            if let record, isRecorded {
                return recordedDetail(record)
            }
            return String(localized: "Not scanned yet")
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
                ? String(localized: "\(unused) not opened in 90 days")
                : String(localized: "\(totals.count) \(totals.count == 1 ? String(localized: "app") : String(localized: "apps"))")
        case .leftovers:
            guard totals.count > 0 else { return String(localized: "Nothing left behind") }
            return String(localized: "\(totals.count) \(totals.count == 1 ? String(localized: "item") : String(localized: "items"))")
        }
    }

    private func largeFilesDetail(count: Int) -> String {
        String(localized: "\(count) \(count == 1 ? String(localized: "file") : String(localized: "files")) over \(LargeFileSizeThreshold.current().label)")
    }

    private func cacheDetail(safeBytes: Int64) -> String {
        safeBytes > 0 ? String(localized: "\(formatBytes(safeBytes)) safe to clean") : String(localized: "Nothing safe to clean")
    }

    /// The same fact as the live line, where the record holds it.
    private func recordedDetail(_ record: ScanRecord) -> String {
        switch category {
        case .appCaches, .devTools:
            if let safeBytes = record.safeBytes {
                return cacheDetail(safeBytes: safeBytes)
            }
            return String(localized: "\(record.count) \(record.count == 1 ? String(localized: "item") : String(localized: "items"))")
        case .leftovers:
            guard record.count > 0 else { return String(localized: "Nothing left behind") }
            return String(localized: "\(record.count) \(record.count == 1 ? String(localized: "item") : String(localized: "items"))")
        case .largeFiles:
            return largeFilesDetail(count: record.count)
        case .apps:
            return String(localized: "\(record.count) \(record.count == 1 ? String(localized: "app") : String(localized: "apps"))")
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
    private static let shape = RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous)

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
                Text(LocalizedStringKey(title))
                    .font(AppStyle.Typography.headline)
                Text(LocalizedStringKey(detail))
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AppStyle.Spacing.small)
            Text(OverviewCategoryStyle.shareText(share))
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textTertiary)
                .overviewNumberTransition(share, reduceMotion: reduceMotion)
            Text(formatStorageBytes(bytes))
                .font(AppStyle.Typography.sectionTitle)
                .overviewNumberTransition(bytes, reduceMotion: reduceMotion)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, 11)
        .overviewLinked(linkedState)
        .background(linkedState == .emphasized ? AppColors.fillSecondary.opacity(0.5) : .clear)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Time Machine snapshots

/// Local Time Machine snapshots: Finder never shows them and macOS counts them as
/// System Data. A count and a date, since nothing reports their size. Remove deletes
/// all but the ones Time Machine may still need, with no password; after that the row
/// says what went.
private struct OverviewSnapshotRow: View {
    @ObservedObject var snapshotStore: LocalSnapshotStore
    let now: Date
    let linkedState: OverviewLinkedRowState

    @EnvironmentObject private var diskStore: DiskSummaryStore
    /// The snapshots the open confirmation names, nil while it's closed. Fixed when it
    /// opens, so the list changing underneath can't change what the click deletes. It
    /// drives the popover itself: a separate flag would show the popover built from
    /// the value before the click.
    @State private var plan: SnapshotRemovalPlan?
    @State private var isShowingInfo = false

    /// What the row is about, for the many people who have never heard of snapshots.
    private static let info = String(localized: "Time Machine saves a snapshot every hour so you can get files back without your backup disk. Old ones keep deleted files around and count as System Data. Remove keeps the newest and the one from your last backup, which Time Machine may still need.")

    /// Not a bar segment, so the bar never highlights it; it only fades with the rest.
    static let id = "timeMachineSnapshots"

    private var snapshots: LocalSnapshots? { snapshotStore.snapshots }
    private var removable: [LocalSnapshot] { snapshots?.removable ?? [] }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            OverviewIconTile(symbol: "clock.arrow.circlepath", color: AppColors.Chart.everythingElse)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Time Machine snapshots")
                        .font(AppStyle.Typography.headline)
                    infoButton
                }
                Text(LocalizedStringKey(detail))
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AppStyle.Spacing.small)
            trailing
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, 11)
        .overviewLinked(linkedState)
        .accessibilityElement(children: .contain)
    }

    private var infoButton: some View {
        Button {
            isShowingInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textTertiary)
        }
        .buttonStyle(.plain)
        .help("What are Time Machine snapshots?")
        .accessibilityLabel("About Time Machine snapshots")
        .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
            Text(Self.info)
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(AppStyle.Spacing.medium)
                .frame(width: 320)
        }
    }

    /// Remove whenever there is something to remove, including after a removal that
    /// failed or couldn't be checked, so it can always be tried again. Otherwise Disk
    /// Utility, when the kept ones may be stuck or a removal left some behind.
    @ViewBuilder
    private var trailing: some View {
        if !removable.isEmpty || snapshotStore.isRemoving {
            removeButton
        } else if showsDiskUtility {
            Button("Open Disk Utility") { Self.openDiskUtility() }
                .buttonStyle(.purge(.secondary, size: .small))
                .help(String(localized: "Purge keeps the newest snapshot, which Time Machine may need. If you're sure you don't, choose View > Show APFS Snapshots in Disk Utility to delete it."))
        }
    }

    private var showsDiskUtility: Bool {
        switch snapshotStore.currentRemovalOutcome {
        case .someLeft, .noneRemoved: return true
        case .removed, .unverified, nil: return snapshots?.newestIsOld(now: now) ?? false
        }
    }

    private var removeButton: some View {
        Button {
            plan = SnapshotRemovalPlan(snapshots: removable)
        } label: {
            CleaningButtonLabel(
                title: snapshotStore.isRemoving ? "Removing..." : "Remove",
                systemImage: nil,
                isCleaning: snapshotStore.isRemoving
            )
        }
        .buttonStyle(.purge(.secondary, size: .small))
        .disabled(snapshotStore.isRemoving)
        .help("Remove the snapshots Time Machine no longer needs")
        .popover(item: $plan, arrowEdge: .bottom) { plan in
            OverviewSnapshotConfirmation(
                count: plan.snapshots.count,
                onCancel: { self.plan = nil },
                onOpenDiskUtility: {
                    self.plan = nil
                    Self.openDiskUtility()
                },
                onConfirm: {
                    self.plan = nil
                    Task {
                        await snapshotStore.remove(plan.snapshots)
                        diskStore.refresh()
                    }
                }
            )
        }
    }

    private var detail: String {
        switch snapshotStore.currentRemovalOutcome {
        case .removed(let removed, let freedBytes):
            var text = removed == 1 ? String(localized: "Removed 1") : String(localized: "Removed \(removed)")
            if let freedBytes { text += String(localized: " and freed \(formatBytes(freedBytes))") }
            return text + String(localized: ", kept the newest")
        case .someLeft(let removed, let left):
            return String(localized: "Removed \(removed), but \(left) couldn't be removed")
        case .noneRemoved:
            return String(localized: "These couldn't be removed. Try again, or use Disk Utility.")
        case .unverified:
            return String(localized: "Couldn't check what was removed. Try again in a moment.")
        case nil:
            break
        }
        guard let snapshots else {
            return snapshotStore.hasTriedReading ? String(localized: "Couldn't check right now") : String(localized: "Checking...")
        }
        guard let oldest = snapshots.oldest else {
            return String(localized: "None on this Mac right now")
        }
        let when = Self.dayText(oldest, now: now)
        if snapshots.count == 1 {
            return String(localized: "1 on this Mac, from \(when), kept for the next backup")
        }
        return String(localized: "\(snapshots.count) on this Mac, the oldest from \(when)")
    }

    /// "today", "yesterday", or a short date.
    static func dayText(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "yesterday")
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func openDiskUtility() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// What one open confirmation will delete.
private struct SnapshotRemovalPlan: Identifiable {
    let id = UUID()
    let snapshots: [LocalSnapshot]
}

/// Snapshots can't be put back, so removing them asks first and says what they hold:
/// most people have never heard of them.
private struct OverviewSnapshotConfirmation: View {
    let count: Int
    let onCancel: () -> Void
    let onOpenDiskUtility: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                Text(count == 1 ? "Remove 1 Time Machine snapshot?" : "Remove \(count) Time Machine snapshots?")
                    .font(AppStyle.Typography.sectionTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Snapshots may hold the only copy of files you changed or deleted since your last backup. Removed snapshots can't be put back. Purge keeps the newest, which Time Machine may need for your next backup. Backups on your backup disk aren't touched.")
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AppStyle.Spacing.xSmall) {
                Button("Open Disk Utility", action: onOpenDiskUtility)
                    .buttonStyle(.purge(.quiet, size: .small))
                    .help("In Disk Utility, choose View > Show APFS Snapshots to pick which ones to delete.")
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.purge(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Remove Snapshots", action: onConfirm)
                    .buttonStyle(.purge(.destructive))
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(width: 460)
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
        let shape = RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
        return self
            .background(shape.fill(AppColors.surfaceCard))
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
        case .appCaches: return String(localized: "App Caches")
        case .devTools: return String(localized: "Dev Tools")
        case .largeFiles: return String(localized: "Large Files")
        // "Installed apps", not "Apps": System Settings has an Applications row that
        // counts only the apps themselves, and this total includes their files.
        case .apps: return String(localized: "Installed apps")
        case .leftovers: return String(localized: "Leftovers from deleted apps")
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
        case .appCaches: return AppColors.Chart.appCachesTile
        case .devTools: return AppColors.Chart.devToolsTile
        case .leftovers: return AppColors.Chart.leftoversTile
        case .largeFiles, .apps: return color(category)
        }
    }

    static func color(_ category: OverviewCategory) -> Color {
        switch category {
        case .appCaches: return AppColors.Chart.appCaches
        case .devTools: return AppColors.Chart.devTools
        case .largeFiles: return AppColors.Chart.largeFiles
        case .apps: return AppColors.Chart.apps
        case .leftovers: return AppColors.Chart.leftovers
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
            .map { String(localized: "\($0.label) \(formatStorageBytes($0.bytes))") }
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
        case .cachesAndDevTools: return String(localized: "App Caches and Dev Tools")
        case .largeFiles: return String(localized: "Large Files")
        case .apps: return String(localized: "installed apps")
        case .leftovers: return String(localized: "leftovers from deleted apps")
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
        }
        .buttonStyle(.purge(.secondary))
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(isFinishingCacheScan || store.isDeleting)
        .help(queue.isRunning ? "Stop scanning" : "Scan App Caches, Dev Tools, Large Files and apps, one after another")
    }

    private var title: String {
        if isFinishingCacheScan { return String(localized: "Scanning...") }
        return queue.isRunning ? String(localized: "Stop") : String(localized: "Scan Everything")
    }

    private var systemImage: String? {
        if isFinishingCacheScan { return nil }
        return queue.isRunning ? "stop.fill" : "arrow.clockwise"
    }
}

// MARK: - Clean safe items

/// Moves every safe App Caches and Dev Tools item to the Trash, after a short
/// confirmation: the same set the menu bar and the scheduled clean move. The tabs'
/// Clean Selected is for picking by hand; this is the one click for the safe part.
/// Hidden when there is nothing safe to clean.
///
/// The title carries no size on purpose. Beside the category totals on this page a
/// smaller figure reads as a mistake; the popover gives the amount next to the
/// total it comes from.
struct OverviewCleanSafeButton: View {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirming = false

    private var bytes: Int64 { store.safeRecoverableBytes }
    private var isCleaning: Bool { store.isInteractiveSafeCleanupInProgress }

    /// The figure moves while either scan runs, so the button waits for both.
    private var isReady: Bool {
        store.isSettled(.appCaches) && store.isSettled(.devTools)
    }

    var body: some View {
        if bytes > 0 || isCleaning {
            Button {
                isConfirming = true
            } label: {
                CleaningButtonLabel(
                    title: isCleaning ? "Cleaning..." : "Clean Safe Items",
                    // The same glyph as Clean Selected and Uninstall on the other tabs.
                    systemImage: isCleaning ? nil : "trash.fill",
                    isCleaning: isCleaning
                )
            }
            .buttonStyle(.purge(.primary))
            .disabled(!isReady || store.isDeleting || isCleaning)
            .help(isReady
                ? "Move every Safe item in App Caches and Dev Tools to the Trash"
                : "Waiting for App Caches and Dev Tools to finish scanning")
            .popover(isPresented: $isConfirming, arrowEdge: .bottom) {
                OverviewCleanSafeConfirmation(
                    breakdown: store.overviewBreakdown(
                        totalBytes: diskStore.totalDiskBytes,
                        freeBytes: diskStore.freeDiskBytes
                    ),
                    onCancel: { isConfirming = false },
                    onConfirm: {
                        isConfirming = false
                        store.cleanSafeItemsFromOverview(reduceMotion: reduceMotion)
                    },
                    onReview: { category in
                        isConfirming = false
                        store.openFromOverview(category)
                    }
                )
                .environmentObject(store)
            }
        }
    }
}

/// What the Clean button will move, by tab, with a way to look first. Review opens
/// the tab on its Safe list with exactly these items selected.
private struct OverviewCleanSafeConfirmation: View {
    @EnvironmentObject private var store: PurgeStore
    /// The Overview's own figures, so each "of" total matches its row.
    let breakdown: OverviewBreakdown
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onReview: (OverviewCategory) -> Void

    private static let categories: [OverviewCategory] = [.appCaches, .devTools]

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                Text("Move \(formatBytes(store.safeRecoverableBytes)) to the Trash?")
                    .font(AppStyle.Typography.sectionTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Only items marked Safe. They rebuild when needed, and you can put anything back from the Trash.")
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: AppStyle.Spacing.xSmall) {
                ForEach(Self.categories, id: \.self) { category in
                    let bytes = store.safeCleanupBytes(for: category) ?? 0
                    if bytes > 0 {
                        row(category, bytes: bytes)
                    }
                }
            }

            HStack(spacing: AppStyle.Spacing.xSmall) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.purge(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", action: onConfirm)
                    .buttonStyle(.purge(.destructive))
            }
        }
        .padding(AppStyle.Spacing.large)
        .frame(width: 400)
    }

    private func row(_ category: OverviewCategory, bytes: Int64) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            OverviewIconTile(
                symbol: OverviewCategoryStyle.symbol(category),
                color: OverviewCategoryStyle.tileColor(category)
            )
            Text(OverviewCategoryStyle.name(category))
                .font(AppStyle.Typography.headline)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: AppStyle.Spacing.small)
            (Text(formatBytes(bytes)).foregroundColor(AppColors.textPrimary)
                + Text(" of \(formatStorageBytes(breakdown.bytes(for: category)))"))
                .font(AppStyle.Typography.body)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Button("Review") { onReview(category) }
                .buttonStyle(.purge(.quiet, size: .small))
        }
        .accessibilityElement(children: .contain)
    }
}
