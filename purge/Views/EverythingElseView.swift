import AppKit
import SwiftUI

// MARK: - Style

/// Names, glyphs, colours and explanations for the Everything else groups (#220).
/// Shared by the Overview's expanded row, the drill-in list and the map.
enum EverythingElseStyle {
    static func name(_ group: EverythingElseGroup) -> String {
        switch group {
        case .appsOutsideApplications: return String(localized: "Apps outside Applications")
        case .managedLibraries: return String(localized: "Mail, Messages and media libraries")
        case .uncleanableCaches: return String(localized: "Caches Purge won't clean")
        case .appData: return String(localized: "App data")
        case .yourFiles: return String(localized: "Your files")
        case .hiddenToolFolders: return String(localized: "Hidden tool folders")
        case .otherUsers: return String(localized: "Other users and Shared")
        case .macOS: return String(localized: "macOS")
        case .notMeasured: return String(localized: "Not measured")
        }
    }

    /// One line on what the group measures.
    static func detail(_ group: EverythingElseGroup) -> String {
        switch group {
        case .appsOutsideApplications: return String(localized: "Steam, JetBrains Toolbox, Epic and itch installs")
        case .managedLibraries: return String(localized: "Mail, Messages, Photos, Music, TV and iMovie keep these")
        case .uncleanableCaches: return String(localized: "Caches in ~/Library/Caches that aren't on Purge's list")
        case .appData: return String(localized: "Application Support, Containers and Group Containers")
        case .yourFiles: return String(localized: "Documents, Desktop, Downloads, Movies, Music and Pictures")
        case .hiddenToolFolders: return String(localized: "Dot folders in your home folder that Dev Tools doesn't cover")
        case .otherUsers: return String(localized: "Other home folders on this Mac, and the Shared folder")
        case .macOS: return String(localized: "The system, the same figure System Settings shows")
        case .notMeasured: return String(localized: "Used space the walk didn't reach")
        }
    }

    /// The answer to "Why isn't this cleanable?" for a folder in the group.
    static func whyNotCleanable(_ group: EverythingElseGroup) -> String {
        switch group {
        case .appsOutsideApplications:
            return String(localized: "This is an installed app or game. The store that installed it knows how to remove it cleanly and keep your saves, so Purge leaves that to it.")
        case .managedLibraries:
            return String(localized: "An app manages this library and expects every file in it. Removing parts of it from outside the app can corrupt the library, so Purge only ever shows it.")
        case .uncleanableCaches:
            return String(localized: "Purge cleans a cache only when it is on the list of caches known to rebuild themselves. This folder isn't on that list, so it could hold things the app can't get back.")
        case .appData:
            return String(localized: "App data holds settings, documents, databases and offline downloads. Only the cache folders inside it are known to be safe, and App Caches already lists those.")
        case .yourFiles:
            return String(localized: "These are your own files. Purge never cleans them on its own; Large Files lists the biggest so you can decide one by one.")
        case .hiddenToolFolders:
            return String(localized: "Tool folders mix caches with installed packages, keys and settings. Dev Tools lists the parts that are safe to clean; the rest stays.")
        case .otherUsers:
            return String(localized: "This belongs to another user on this Mac. Only that user, or an administrator in System Settings, can remove it.")
        case .macOS:
            return String(localized: "This is the operating system itself, on a sealed volume nothing can change.")
        case .notMeasured:
            return String(localized: "Purge didn't measure this part of the disk, so it can't say what is in it.")
        }
    }

    static func symbol(_ group: EverythingElseGroup) -> String {
        switch group {
        case .appsOutsideApplications: return "gamecontroller.fill"
        case .managedLibraries: return "photo.on.rectangle"
        case .uncleanableCaches: return "tray.full.fill"
        case .appData: return "shippingbox.fill"
        case .yourFiles: return "folder.fill"
        case .hiddenToolFolders: return "terminal.fill"
        case .otherUsers: return "person.2.fill"
        case .macOS: return "apple.logo"
        case .notMeasured: return "questionmark.circle"
        }
    }

    /// Each measured group keeps its own lightness step, whatever its size, so
    /// a re-measure never swaps the greys around.
    static func color(_ group: EverythingElseGroup) -> Color {
        switch group {
        case .macOS: return AppColors.Chart.everythingElseMacOS
        case .notMeasured: return AppColors.Chart.everythingElseRemainder
        case .appsOutsideApplications, .managedLibraries, .uncleanableCaches, .appData,
             .yourFiles, .hiddenToolFolders, .otherUsers:
            return AppColors.Chart.everythingElseShades[shadeIndex(group)]
        }
    }

    static func labelColor(_ group: EverythingElseGroup) -> Color {
        switch group {
        case .macOS, .notMeasured: return AppColors.textPrimary
        case .appsOutsideApplications, .managedLibraries, .uncleanableCaches, .appData,
             .yourFiles, .hiddenToolFolders, .otherUsers:
            return AppColors.Chart.everythingElseShadeLabels[shadeIndex(group)]
        }
    }

    private static func shadeIndex(_ group: EverythingElseGroup) -> Int {
        let index = EverythingElseGroup.measured.firstIndex(of: group) ?? 0
        return min(index, AppColors.Chart.everythingElseShades.count - 1)
    }

    /// The bar segment id, shared by the Overview and the drill-in.
    static func segmentID(_ group: EverythingElseGroup) -> String {
        "everythingElse.\(group.rawValue)"
    }

    static func folderCountText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 folder") : String(localized: "\(count) folders")
    }

    /// "41 smaller folders · 40.2 GB", with the loose files folded in.
    static func smallerLine(count: Int, bytes: Int64) -> String {
        if count == 0 {
            return String(localized: "Loose files · \(formatStorageBytes(bytes))")
        }
        let folders = count == 1 ? String(localized: "1 smaller folder") : String(localized: "\(count) smaller folders")
        return "\(folders) · \(formatStorageBytes(bytes))"
    }
}

// MARK: - Page

/// Everything else as its own page (#220): a bar of just the unsorted space, a card
/// of measured groups that open to their biggest folders, and a card for macOS and
/// the remainder. Read only: no checkbox, no count toward cleaning, and no way to
/// `FileDeleter` from anything on it.
struct EverythingElseView: View {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The one group open to its folders. The map shows the same level.
    @State private var openGroup: EverythingElseGroup?
    /// The folder picked in the list or on the map.
    @State private var selectedFolderPath: String?
    @State private var highlightedID: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let overview = store.overviewBreakdown(totalBytes: diskStore.totalDiskBytes, freeBytes: diskStore.freeDiskBytes)
        let breakdown = store.everythingElseBreakdown(totalBytes: diskStore.totalDiskBytes, freeBytes: diskStore.freeDiskBytes)
        VStack(alignment: .leading, spacing: AppStyle.Spacing.large) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
                summary(overview: overview)
                OverviewDiskBar(
                    segments: barSegments(breakdown, everythingElseBytes: overview.everythingElseBytes),
                    highlightedID: highlightedID,
                    onHover: { highlightedID = $0 }
                )
            }

            if let breakdown {
                switch store.everythingElseViewMode {
                case .list:
                    groupsCard(breakdown)
                case .map:
                    EverythingElseMapCard(
                        breakdown: breakdown,
                        openGroup: $openGroup,
                        selectedFolderPath: $selectedFolderPath,
                        linkedState: linkedRowState
                    )
                }
                restCard(breakdown)
            } else {
                notMeasuredCard
            }

            footnotes(breakdown, now: now)
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(.bottom, AppStyle.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: highlightedID)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: openGroup)
        .onAppear { store.requestScanIfNeeded(.everythingElse) }
    }

    private func linkedRowState(_ id: String) -> OverviewLinkedRowState {
        guard let highlightedID else { return .normal }
        return highlightedID == id ? .emphasized : .dimmed
    }

    // MARK: Summary and bar

    private func summary(overview: OverviewBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
            Text("\(formatStorageBytes(overview.everythingElseBytes)) not sorted by Purge")
                .font(AppStyle.Typography.title.weight(.bold))
                .overviewNumberTransition(overview.everythingElseBytes, reduceMotion: reduceMotion)
            Text("of \(formatStorageBytes(overview.usedBytes)) used")
                .font(AppStyle.Typography.rowTitle)
                .foregroundStyle(AppColors.textSecondary)
                .overviewNumberTransition(overview.usedBytes, reduceMotion: reduceMotion)
        }
        .accessibilityElement(children: .combine)
    }

    /// The groups biggest first, then macOS, then what was not measured, so the
    /// bar is the unsorted space alone.
    private func barSegments(_ breakdown: EverythingElseBreakdown?, everythingElseBytes: Int64) -> [OverviewDiskBar.Segment] {
        guard let breakdown else {
            return [OverviewDiskBar.Segment(
                id: EverythingElseStyle.segmentID(.notMeasured),
                label: EverythingElseStyle.name(.notMeasured),
                bytes: everythingElseBytes,
                color: EverythingElseStyle.color(.notMeasured)
            )]
        }
        var segments = breakdown.measuredGroupsBySize.map { group in
            OverviewDiskBar.Segment(
                id: EverythingElseStyle.segmentID(group),
                label: EverythingElseStyle.name(group),
                bytes: breakdown.bytes(for: group),
                color: EverythingElseStyle.color(group)
            )
        }
        for group in [EverythingElseGroup.macOS, .notMeasured] {
            segments.append(OverviewDiskBar.Segment(
                id: EverythingElseStyle.segmentID(group),
                label: EverythingElseStyle.name(group),
                bytes: breakdown.bytes(for: group),
                color: EverythingElseStyle.color(group)
            ))
        }
        return segments
    }

    // MARK: Cards

    private func groupsCard(_ breakdown: EverythingElseBreakdown) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(breakdown.measuredGroupsBySize.enumerated()), id: \.element) { index, group in
                if index > 0 {
                    InsetCardDivider()
                }
                EverythingElseGroupRow(
                    breakdown: breakdown,
                    group: group,
                    isOpen: openGroup == group,
                    selectedFolderPath: $selectedFolderPath,
                    linkedState: linkedRowState(EverythingElseStyle.segmentID(group)),
                    onToggle: { toggle(group) }
                )
            }
        }
        .overviewCard()
    }

    private func toggle(_ group: EverythingElseGroup) {
        if openGroup == group {
            openGroup = nil
        } else {
            openGroup = group
            selectedFolderPath = nil
        }
    }

    private func restCard(_ breakdown: EverythingElseBreakdown) -> some View {
        VStack(spacing: 0) {
            OverviewPlainRow(
                symbol: EverythingElseStyle.symbol(.macOS),
                color: EverythingElseStyle.color(.macOS),
                title: EverythingElseStyle.name(.macOS),
                detail: breakdown.macOSBytes == nil ? String(localized: "Couldn't read the system volume") : EverythingElseStyle.detail(.macOS),
                bytes: breakdown.macOSBytes ?? 0,
                share: share(breakdown.macOSBytes ?? 0, of: breakdown.everythingElseBytes),
                linkedState: linkedRowState(EverythingElseStyle.segmentID(.macOS))
            )
            InsetCardDivider()
            OverviewPlainRow(
                symbol: EverythingElseStyle.symbol(.notMeasured),
                color: EverythingElseStyle.color(.notMeasured),
                title: EverythingElseStyle.name(.notMeasured),
                detail: breakdown.isComplete ? EverythingElseStyle.detail(.notMeasured) : String(localized: "Shrinks as the groups fill in"),
                bytes: breakdown.notMeasuredBytes,
                share: share(breakdown.notMeasuredBytes, of: breakdown.everythingElseBytes),
                linkedState: linkedRowState(EverythingElseStyle.segmentID(.notMeasured))
            )
        }
        .overviewCard()
    }

    private func share(_ bytes: Int64, of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(total)))
    }

    /// Before the first walk, or after Stop ended one before it began.
    private var notMeasuredCard: some View {
        VStack(spacing: AppStyle.Spacing.small) {
            Text(store.everythingElsePhase == .waiting ? "Up next" : "Not measured yet")
                .font(AppStyle.Typography.sectionTitle)
            Text("Measuring walks all of your home folder and Library. It can take a few minutes on a full disk, and nothing is changed.")
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if store.everythingElsePhase == .notMeasured {
                Button("Measure") { store.measureEverythingElseAgain() }
                    .buttonStyle(.purge(.secondary))
            }
        }
        .frame(maxWidth: 420)
        .padding(AppStyle.Spacing.large)
        .frame(maxWidth: .infinity)
        .overviewCard()
    }

    // MARK: Footnotes

    @ViewBuilder
    private func footnotes(_ breakdown: EverythingElseBreakdown?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sizes are as counted on disk. Clones and purgeable files can make a folder read larger than what removing it would free.")
            if let breakdown, breakdown.isComplete, let completedAt = breakdown.completedAt {
                Text("Measured \(compactAgoText(from: completedAt, to: now)). Hard links are counted once within each folder.")
            } else if store.everythingElsePhase == .measuring {
                Text("Measuring. Groups fill in as their folders finish, biggest first.")
            }
            if !store.hasFullDiskAccess {
                Text("Without Full Disk Access, Documents, Desktop, Downloads, Mail, Messages and app containers are skipped and counted as not measured.")
            }
        }
        .font(AppStyle.Typography.metadata)
        .foregroundStyle(AppColors.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Group row

/// One measured group on the drill-in. Opens to its biggest folders.
private struct EverythingElseGroupRow: View {
    let breakdown: EverythingElseBreakdown
    let group: EverythingElseGroup
    let isOpen: Bool
    @Binding var selectedFolderPath: String?
    let linkedState: OverviewLinkedRowState
    let onToggle: () -> Void

    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var figures: EverythingElseGroupBreakdown? { breakdown[group] }
    private var isMeasuring: Bool { figures?.isFinished == false && store.everythingElsePhase == .measuring }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isOpen, let figures {
                folderList(figures)
            }
        }
    }

    private var header: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            OverviewIconTile(symbol: EverythingElseStyle.symbol(group), color: EverythingElseStyle.color(group))
            VStack(alignment: .leading, spacing: 2) {
                Text(EverythingElseStyle.name(group))
                    .font(AppStyle.Typography.headline)
                Text(statusText)
                    .lineLimit(1)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .shimmeringText(isMeasuring)
            }
            Spacer(minLength: AppStyle.Spacing.small)
            trailing
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, 11)
        .overviewLinked(linkedState)
        .background(isHovering || linkedState == .emphasized ? AppColors.fillSecondary.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOpen ? String(localized: "Expanded") : String(localized: "Collapsed"))
        .accessibilityAction { onToggle() }
    }

    @ViewBuilder
    private var trailing: some View {
        if figures?.isLocked == true, figures?.bytes == 0 {
            Image(systemName: "lock")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.textTertiary)
                .accessibilityLabel("Needs Full Disk Access")
        } else {
            let bytes = figures?.bytes ?? 0
            HStack(spacing: AppStyle.Spacing.small) {
                Text(OverviewCategoryStyle.shareText(share(bytes)))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textTertiary)
                    .overviewNumberTransition(bytes, reduceMotion: reduceMotion)
                Text(formatStorageBytes(bytes))
                    .font(AppStyle.Typography.sectionTitle)
                    .overviewNumberTransition(bytes, reduceMotion: reduceMotion)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
    }

    private func share(_ bytes: Int64) -> Double {
        guard breakdown.everythingElseBytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(breakdown.everythingElseBytes))
    }

    private var statusText: String {
        guard let figures else { return EverythingElseStyle.detail(group) }
        if figures.isLocked, figures.bytes == 0 {
            return String(localized: "Needs Full Disk Access")
        }
        if isMeasuring {
            return String(localized: "Measuring…")
        }
        if figures.isEmpty {
            return String(localized: "Nothing here")
        }
        var parts: [String] = []
        if !figures.folders.isEmpty {
            parts.append(String(localized: "\(EverythingElseStyle.folderCountText(figures.folders.count)) over \(formatStorageBytes(EverythingElseBreakdown.defaultFloorBytes))"))
        } else {
            parts.append(EverythingElseStyle.detail(group))
        }
        if figures.isLocked {
            parts.append(String(localized: "part needs Full Disk Access"))
        }
        return parts.joined(separator: " · ")
    }

    private func folderList(_ figures: EverythingElseGroupBreakdown) -> some View {
        VStack(spacing: 0) {
            ForEach(figures.folders) { folder in
                InsetCardDivider(horizontalInset: EverythingElseFolderRow.leadingInset)
                EverythingElseFolderRow(
                    folder: folder,
                    hint: store.everythingElseFolderHint(for: folder),
                    isSelected: selectedFolderPath == folder.path,
                    onSelect: { selectedFolderPath = folder.path }
                )
            }
            if figures.smallerFolderCount > 0 || figures.smallerBytes > 0 {
                InsetCardDivider(horizontalInset: EverythingElseFolderRow.leadingInset)
                HStack {
                    Text(EverythingElseStyle.smallerLine(count: figures.smallerFolderCount, bytes: figures.smallerBytes))
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                }
                .padding(.leading, EverythingElseFolderRow.leadingInset)
                .padding(.trailing, AppStyle.Row.scanCardHorizontalPadding)
                .padding(.vertical, AppStyle.Spacing.xSmall)
                .accessibilityElement(children: .combine)
            }
            if figures.folders.isEmpty, figures.smallerFolderCount == 0, figures.smallerBytes == 0 {
                InsetCardDivider(horizontalInset: EverythingElseFolderRow.leadingInset)
                Text(figures.isLocked ? "Needs Full Disk Access to look inside" : "Nothing to list")
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, EverythingElseFolderRow.leadingInset)
                    .padding(.vertical, AppStyle.Spacing.xSmall)
            }
        }
        .padding(.bottom, AppStyle.Spacing.xxSmall)
        .transition(.opacity)
    }
}

// MARK: - Folder row

/// One folder over the floor. Show in Finder on hover, and where the owning app has
/// its own way to free the space, the steps and a button to open it. The context
/// menu adds Copy Path, "Why isn't this cleanable?" and Hide from Everything else.
/// There is no Move to Trash here, by design (#220).
struct EverythingElseFolderRow: View {
    let folder: EverythingElseFolder
    let hint: EverythingElseFolderHint?
    let isSelected: Bool
    let onSelect: () -> Void

    @EnvironmentObject private var store: PurgeStore
    @State private var isHovering = false
    @State private var isContextMenuActive = false
    @State private var isShowingWhy = false

    /// Lines up folder text with the group title beside its tile.
    static let leadingInset: CGFloat = AppStyle.Row.scanCardHorizontalPadding + OverviewIconTile.size + AppStyle.Spacing.small

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(AppStyle.Typography.rowTitle)
                        .lineLimit(1)
                    Text(displayDirectoryPath(for: folder.url))
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: AppStyle.Spacing.small)
                if isHovering || isSelected {
                    Button("Show in Finder") { FinderReveal.show(folder.url) }
                        .buttonStyle(.purge(.quiet, size: .small))
                }
                Text(formatStorageBytes(folder.bytes))
                    .font(AppStyle.Typography.headline)
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
            if let hint {
                HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
                    Text(hint.steps)
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: AppStyle.Spacing.small)
                    if let action = hint.action {
                        Button(actionTitle(action)) { store.performEverythingElseHint(action) }
                            .buttonStyle(.purge(.secondary, size: .small))
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, AppStyle.Spacing.xSmall)
        .background(isSelected ? AppColors.surfaceCardHover : (isHovering || isContextMenuActive ? AppColors.fillSecondary.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .overlay {
            ScanRowContextMenu(isMenuActive: $isContextMenuActive, entries: contextMenuEntries)
        }
        .popover(isPresented: $isShowingWhy, arrowEdge: .bottom) {
            Text(EverythingElseStyle.whyNotCleanable(folder.group))
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(AppStyle.Spacing.medium)
                .frame(width: 340)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: Text("Show in Finder")) { FinderReveal.show(folder.url) }
        .accessibilityAction(named: Text("Copy Path")) { FinderReveal.copyPaths([folder.url]) }
        .accessibilityAction(named: Text("Why isn't this cleanable?")) { isShowingWhy = true }
        .accessibilityAction(named: Text("Hide from Everything else")) { store.hideFromEverythingElse(folder) }
    }

    private func actionTitle(_ action: EverythingElseFolderHint.Action) -> String {
        switch action {
        case .openApp(_, let title): return title
        case .openURL(_, let title): return title
        case .showInLargeFiles: return String(localized: "Show in Large Files")
        }
    }

    /// Built on right-click, never during `body`.
    private func contextMenuEntries() -> [ScanRowMenuEntry] {
        var entries = FinderReveal.menuEntries(for: [ScanRowLocation(url: folder.url, sizeBytes: folder.bytes)])
        if let action = hint?.action {
            entries.append(.action(title: actionTitle(action)) { store.performEverythingElseHint(action) })
        } else if let app = store.everythingElseOwningApp(for: folder) {
            entries.append(.action(title: String(localized: "Open \(app.name)")) { store.performEverythingElseHint(.openApp(bundleID: app.bundleID, title: app.name)) })
        }
        entries.append(.separator)
        entries.append(.action(title: String(localized: "Why isn't this cleanable?")) { isShowingWhy = true })
        entries.append(.action(title: String(localized: "Hide from Everything else")) { store.hideFromEverythingElse(folder) })
        return entries
    }
}

// MARK: - Header actions

/// Back to the Overview, the List and Map switch, and Measure again.
struct EverythingElseHeaderActions: View {
    @EnvironmentObject private var store: PurgeStore

    private var isMeasuring: Bool { store.everythingElsePhase == .measuring }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Button {
                store.showOverviewSummary()
            } label: {
                Label("Overview", systemImage: "chevron.left")
            }
            .buttonStyle(.purge(.quiet))
            .keyboardShortcut("[", modifiers: [.command])
            .help("Back to the Overview")

            EverythingElseViewModeSwitcher(selection: $store.everythingElseViewMode)

            Button {
                if isMeasuring {
                    store.stopScans()
                } else {
                    store.measureEverythingElseAgain()
                }
            } label: {
                CleaningButtonLabel(
                    title: isMeasuring ? "Stop" : "Measure again",
                    systemImage: isMeasuring ? "stop.fill" : "arrow.clockwise",
                    isCleaning: false
                )
            }
            .buttonStyle(.purge(.secondary))
            .disabled(store.everythingElsePhase == .waiting)
            .help(isMeasuring ? LocalizedStringKey("Stop measuring") : LocalizedStringKey("Walk the unsorted folders again"))
        }
    }
}

/// One pill, two segments, like the uninstaller's view switcher: the active
/// segment gets a quiet lift instead of the native white thumb.
struct EverythingElseViewModeSwitcher: View {
    @Binding var selection: EverythingElseViewMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let inset: CGFloat = 2

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EverythingElseViewMode.allCases) { mode in
                segment(mode)
            }
        }
        .padding(Self.inset)
        .background {
            RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                .fill(AppColors.fillSecondary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    private func segment(_ mode: EverythingElseViewMode) -> some View {
        let isOn = selection == mode
        return Button {
            guard selection != mode else { return }
            if reduceMotion {
                selection = mode
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { selection = mode }
            }
        } label: {
            Text(Self.label(mode))
                .font(AppStyle.Typography.callout.weight(.semibold))
                .foregroundStyle(isOn ? AppColors.textPrimary : AppColors.textSecondary)
                .padding(.horizontal, AppStyle.Spacing.small)
                .frame(height: AppStyle.Control.height - (Self.inset * 2))
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous)
                            .fill(AppColors.surfaceRaised)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    static func label(_ mode: EverythingElseViewMode) -> String {
        switch mode {
        case .list: return String(localized: "List")
        case .map: return String(localized: "Map")
        }
    }
}

// MARK: - Store helpers for the rows

extension PurgeStore {
    /// The app that owns a folder, when its name is a bundle id (a container) and
    /// the app is installed. Asked on right-click only: it is a LaunchServices call.
    func everythingElseOwningApp(for folder: EverythingElseFolder) -> (bundleID: String, name: String)? {
        let name = folder.name
        guard name.contains("."), !name.hasPrefix("."),
              let appName = appDisplayName(forBundleID: name)
        else { return nil }
        return (name, appName)
    }

    func everythingElseFolderHint(for folder: EverythingElseFolder) -> EverythingElseFolderHint? {
        EverythingElseFolderHint.hint(
            for: folder.path,
            group: folder.group,
            home: FileManager.default.homeDirectoryForCurrentUser,
            steamGames: everythingElseMeasurement?.steamGames ?? [:]
        )
    }

    /// Opens an app, a link the app handles, or the Large Files tab. Nothing here
    /// touches a file.
    func performEverythingElseHint(_ action: EverythingElseFolderHint.Action) {
        switch action {
        case .openApp(let bundleID, _):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .openURL(let url, _):
            NSWorkspace.shared.open(url)
        case .showInLargeFiles:
            selectedTab = .largeFiles
        }
    }
}
