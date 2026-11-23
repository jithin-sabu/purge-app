import AppKit
import SwiftUI

// MARK: - Style

/// Names, explanations and colours for the Everything else page (#159). The
/// groups say where the space is; the buckets say what you can do about it, and
/// the colours follow the buckets.
enum EverythingElseStyle {
    static func name(_ group: EverythingElseGroup) -> String {
        switch group {
        case .otherApps: return String(localized: "Other Apps")
        case .mediaLibraries: return String(localized: "Media Libraries")
        case .mailAndMessages: return String(localized: "Mail & Messages")
        case .protectedCaches: return String(localized: "Protected Caches")
        case .developer: return String(localized: "Developer")
        case .appData: return String(localized: "App Data")
        case .documents: return String(localized: "Documents")
        case .otherUsers: return String(localized: "Other Users")
        case .trash: return String(localized: "Trash")
        case .macOS: return String(localized: "macOS")
        case .systemData: return String(localized: "System Data")
        }
    }

    /// What kinds of files the group holds. Shown on hover.
    static func detail(_ group: EverythingElseGroup) -> String {
        switch group {
        case .otherApps:
            return String(localized: "Apps and games that Steam, Epic, itch or JetBrains Toolbox installed.")
        case .mediaLibraries:
            return String(localized: "The libraries Photos, Music, TV, iMovie and GarageBand keep.")
        case .mailAndMessages:
            return String(localized: "Mail's messages and attachments, and the photos and videos people send you in Messages.")
        case .protectedCaches:
            return String(localized: "Cache folders that aren't on Purge's list of caches known to rebuild themselves, so Purge leaves them alone.")
        case .developer:
            return String(localized: "Code projects, Xcode's other data, and the toolchains, packages and AI agent data that developer tools keep in hidden folders in your home folder.")
        case .appData:
            return String(localized: "Application Support, Containers and the rest of your Library that no installed app claims.")
        case .documents:
            return String(localized: "Your files in Documents, Desktop, Downloads, Movies, Music, Pictures and your other home folders, apart from what Large Files lists.")
        case .otherUsers:
            return String(localized: "Other accounts on this Mac, and the Shared folder.")
        case .trash:
            return String(localized: "Files you moved to the Trash. They take up space until you empty it.")
        case .macOS:
            return String(localized: "The operating system, on its own read-only volume. It can't be changed or removed.")
        case .systemData:
            return String(localized: "Snapshots, virtual memory, logs and other space macOS manages itself, plus anything Purge couldn't read.")
        }
    }

    /// The answer to "Why isn't this cleanable?" for a folder in the group.
    static func whyNotCleanable(_ group: EverythingElseGroup) -> String {
        switch group {
        case .otherApps:
            return String(localized: "This is an installed app or game. The store that installed it knows how to remove it, so Purge leaves that to it.")
        case .mediaLibraries, .mailAndMessages:
            return String(localized: "An app manages this library and expects every file in it. Removing parts of it from outside the app can corrupt the library, so Purge only ever shows it.")
        case .protectedCaches:
            return String(localized: "Purge cleans a cache only when it is on the list of caches known to rebuild themselves. This folder isn't on that list, so it could hold things the app can't get back.")
        case .appData:
            return String(localized: "App data holds settings, documents, databases and offline downloads. Only the cache folders inside it are known to be safe, and App Caches already lists those.")
        case .documents:
            return String(localized: "These are your own files. Purge never cleans them on its own; Large Files lists the biggest so you can decide one by one.")
        case .developer:
            return String(localized: "Projects and tool folders mix caches with source code, installed packages, keys and settings. Dev Tools lists the parts that are safe to clean; the rest stays.")
        case .otherUsers:
            return String(localized: "This belongs to another user on this Mac. Only that user, or an administrator in System Settings, can remove it.")
        case .trash, .macOS, .systemData:
            return detail(group)
        }
    }

    static func name(_ bucket: EverythingElseBucket) -> String {
        switch bucket {
        case .managedInApps: return String(localized: "Managed in Apps")
        case .yourFiles: return String(localized: "Your Files")
        case .leftAlone: return String(localized: "Left Alone")
        case .managedByMacOS: return String(localized: "Managed by macOS")
        }
    }

    static func explanation(_ bucket: EverythingElseBucket) -> String {
        switch bucket {
        case .managedInApps:
            return String(localized: "Free this space from inside the app that keeps it.")
        case .yourFiles:
            return String(localized: "Yours to keep or remove. Purge shows where they are and doesn't decide.")
        case .leftAlone:
            return String(localized: "Purge doesn't consider these safe to delete, so it never touches them.")
        case .managedByMacOS:
            return String(localized: "macOS creates and frees this space itself. There is nothing to do here.")
        }
    }

    static func color(_ bucket: EverythingElseBucket) -> Color {
        switch bucket {
        case .managedInApps: return AppColors.Chart.managedInApps
        case .yourFiles: return AppColors.Chart.yourFiles
        case .leftAlone: return AppColors.Chart.leftAlone
        case .managedByMacOS: return AppColors.Chart.managedByMacOS
        }
    }

    static func labelColor(_ bucket: EverythingElseBucket) -> Color {
        switch bucket {
        case .managedInApps, .yourFiles, .leftAlone: return AppColors.Chart.bucketLabel
        case .managedByMacOS: return AppColors.Chart.managedByMacOSLabel
        }
    }

    /// "41 smaller folders", or "Loose files" when there were none.
    static func smallerTitle(count: Int) -> String {
        switch count {
        case 0: return String(localized: "Loose files")
        case 1: return String(localized: "1 smaller folder")
        default: return String(localized: "\(count) smaller folders")
        }
    }

    static func actionTitle(_ action: EverythingElseFolderHint.Action) -> String {
        switch action {
        case .openApp(_, let title): return title
        case .openURL(_, let title): return title
        case .showInLargeFiles: return String(localized: "Show in Large Files")
        case .showInDevTools: return String(localized: "Show in Dev Tools")
        case .showInCommandLineTools: return String(localized: "Show in Uninstaller")
        }
    }
}

// MARK: - Overview row

/// The Everything else row (#159). Clicking it opens Everything else as its own
/// page, the map above the list; the Overview itself stays as it is. Like the
/// category rows, the hover fill and the pointing hand say it opens. Read only:
/// nothing here is selectable.
struct OverviewEverythingElseRow: View {
    let breakdown: OverviewBreakdown
    let linkedState: OverviewLinkedRowState

    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var phase: EverythingElsePhase { store.everythingElsePhase }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            OverviewIconTile(symbol: "ellipsis", color: AppColors.Chart.everythingElse)
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text("Everything else")
                    .font(AppStyle.Typography.headline)
                Text(detail)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .shimmeringText(phase == .measuring)
            }
            Spacer(minLength: AppStyle.Spacing.small)
            Text(OverviewCategoryStyle.shareText(breakdown.share(of: breakdown.everythingElseBytes)))
                .font(AppStyle.Typography.metadata.numbers)
                .foregroundStyle(AppColors.textTertiary)
                .overviewNumberTransition(breakdown.everythingElseBytes, reduceMotion: reduceMotion)
            Text(formatStorageBytes(breakdown.everythingElseBytes))
                .font(AppStyle.Typography.sectionTitle.numbers)
                .overviewNumberTransition(breakdown.everythingElseBytes, reduceMotion: reduceMotion)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, AppStyle.Row.scanCardHorizontalPadding)
        .padding(.vertical, AppStyle.Spacing.small)
        .overviewLinked(linkedState)
        .background(isHovering || linkedState == .emphasized ? AppColors.fillSecondary.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .help("See what Everything else holds")
        .onHover(perform: setHovering)
        .onDisappear { setHovering(false) }
        .onTapGesture { store.showEverythingElsePage() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens what Everything else holds")
        .accessibilityAction { store.showEverythingElsePage() }
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

    private var detail: String {
        switch phase {
        case .waiting, .measuring:
            return String(localized: "Measuring what it holds…")
        case .notMeasured, .ready:
            return String(localized: "macOS, your documents and photos, and files Purge doesn't sort")
        }
    }
}

// MARK: - Page

/// Everything else as its own page (#159): what you can do about the space, in
/// four figures, over a map of the space itself. The map starts as one tile for
/// the whole of Everything else and divides as the walk measures each group,
/// under frosted glass with one capsule that says which group is being
/// measured; the glass clears once when the walk is done, and the map is
/// already there. Each group is a frame with its biggest folders drawn inside,
/// sized by space and coloured by what you can do. Pointing at a tile names it;
/// clicking it opens what it is and its one action. Read only: no checkbox, no
/// count toward cleaning, and no way to `FileDeleter` from here.
struct EverythingElseView: View {
    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var diskStore: DiskSummaryStore
    @EnvironmentObject private var trashStore: TrashStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlightedBucket: EverythingElseBucket?

    static let mapHeight: CGFloat = 460

    var body: some View {
        content
            .padding(.horizontal, AppDetailPageLayout.horizontalInset)
            .padding(.bottom, AppStyle.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: highlightedBucket)
    }

    /// The Trash's figure. Nil only when it can't be read, so the map says it
    /// needs access; while the first count runs it is zero.
    private var trashBytes: Int64? {
        switch trashStore.access {
        case .readable: return trashStore.trashBytes
        case .measuring: return 0
        case .unreadable: return nil
        }
    }

    private var phase: EverythingElsePhase { store.everythingElsePhase }

    @ViewBuilder
    private var content: some View {
        let breakdown = store.everythingElseBreakdown(
            totalBytes: diskStore.totalDiskBytes,
            freeBytes: diskStore.freeDiskBytes,
            trashBytes: trashBytes
        )
        // A walk that Stop ended leaves no figures: the map goes back to one tile.
        let shown = phase == .notMeasured ? nil : breakdown
        let openFolders = shown == nil ? [] : store.everythingElseOpenFolders
        let level = openFolders.isEmpty ? nil : store.everythingElseOpenLevel()
        VStack(alignment: .leading, spacing: AppStyle.Spacing.medium) {
            // The heading sits under the way back, in the page itself. The walk's
            // one line of status is at the right of it: why it has not started,
            // or which group it is on. Plain text that changes in place. With a
            // folder open (#437) the heading is the way back up, and the right
            // side says what the open folder holds.
            HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.small) {
                if openFolders.isEmpty {
                    Text("Everything else")
                        .font(AppStyle.Typography.pageTitle)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    // A blank in the title's size keeps the row as tall as it
                    // is on the whole map, so the map doesn't move up a few
                    // points on the way in.
                    ZStack(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                        Text(verbatim: " ")
                            .font(AppStyle.Typography.pageTitle)
                            .accessibilityHidden(true)
                        EverythingElseBreadcrumb(openFolders: openFolders, passedThrough: store.everythingElsePassedThroughFolders()) { count in
                            store.closeEverythingElseFolders(keeping: count)
                        }
                    }
                }
                Spacer(minLength: AppStyle.Spacing.medium)
                if let level {
                    Text(formatStorageBytes(level.bytes))
                        .font(AppStyle.Typography.callout.numbers)
                        .foregroundStyle(AppColors.textSecondary)
                        .monospacedDigit()
                        .fixedSize()
                } else {
                    EverythingElseStatusLine(phase: phase, measurement: store.everythingElseMeasurement)
                }
            }
            bucketFigures(shown)
            EverythingElseNestedMap(
                breakdown: shown,
                phase: phase,
                measurement: store.everythingElseMeasurement,
                runningStep: store.scanQueue.active,
                highlightedBucket: highlightedBucket,
                openFolders: openFolders,
                level: level,
                // The glass is for the open folder only: one still waiting to
                // show is measured with the map left as it is.
                folderSizing: store.everythingElseFolderSizing.flatMap { sizing in
                    openFolders.last.map { OverviewSizedItem.normalized($0.path) } == sizing.path ? sizing : nil
                },
                onMeasure: { store.measureEverythingElseAgain() }
            )
            if let shown {
                footnote(shown)
            }
        }
    }

    // MARK: Headline

    /// The page's headline: how much of the space each kind of action reaches.
    private func bucketFigures(_ breakdown: EverythingElseBreakdown?) -> some View {
        HStack(spacing: AppStyle.Spacing.small) {
            ForEach(EverythingElseBucket.allCases, id: \.self) { bucket in
                let bytes = breakdown.flatMap { bucketBytes(bucket, in: $0) }
                VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                    HStack(spacing: AppStyle.Spacing.xxSmall) {
                        RoundedRectangle(cornerRadius: AppStyle.Radius.xs, style: .continuous)
                            .fill(EverythingElseStyle.color(bucket))
                            .frame(width: 10, height: 10)
                        Text(EverythingElseStyle.name(bucket))
                            .font(AppStyle.Typography.callout)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                    Text(bytes.map(formatStorageBytes) ?? "—")
                        .font(AppStyle.Typography.pageTitle.numbers)
                        .foregroundStyle(bytes == nil ? AppColors.textTertiary : AppColors.textPrimary)
                        .monospacedDigit()
                        .overviewNumberTransition(bytes ?? 0, reduceMotion: reduceMotion)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppStyle.Spacing.small)
                .overviewCard()
                .opacity(highlightedBucket == nil || highlightedBucket == bucket ? 1 : 0.5)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        highlightedBucket = bucket
                    } else if highlightedBucket == bucket {
                        highlightedBucket = nil
                    }
                }
                .help(EverythingElseStyle.explanation(bucket))
                .accessibilityElement(children: .combine)
                .accessibilityHint(EverythingElseStyle.explanation(bucket))
            }
        }
    }

    /// While the walk runs, a bucket's figure is what has landed so far, and
    /// nothing at all until one of its groups has: "0 bytes" would say the
    /// space is empty when it has not been measured yet. The unmeasured
    /// remainder is not System Data yet, so macOS's figure leaves it out until
    /// the walk is done.
    private func bucketBytes(_ bucket: EverythingElseBucket, in breakdown: EverythingElseBreakdown) -> Int64? {
        guard !breakdown.isComplete else { return breakdown.bytes(for: bucket) }
        guard bucket.groups.contains(where: { hasLanded($0, in: breakdown) }) else { return nil }
        guard bucket == .managedByMacOS else { return breakdown.bytes(for: bucket) }
        return breakdown.bytes(for: bucket) - breakdown.systemDataBytes
    }

    /// Whether a group's figure is in while the walk runs.
    private func hasLanded(_ group: EverythingElseGroup, in breakdown: EverythingElseBreakdown) -> Bool {
        switch group {
        case .macOS: return breakdown.macOSBytes != nil
        case .trash: return breakdown.trashBytes != nil
        case .systemData: return breakdown.isComplete
        case .otherApps, .mediaLibraries, .mailAndMessages, .protectedCaches,
             .developer, .appData, .documents, .otherUsers:
            return breakdown[group]?.isFinished == true
        }
    }

    // MARK: Footnote

    private func footnote(_ breakdown: EverythingElseBreakdown) -> some View {
        HStack(spacing: AppStyle.Spacing.xxSmall) {
            Text(breakdown.isApproximate
                ? String(localized: "Sizes are as counted on disk. Some categories show totals from an earlier scan, so these are close, not exact.")
                : String(localized: "Sizes are as counted on disk."))
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .help("Clones and purgeable files can make a folder read larger than what removing it would free. Hard links are counted once within each folder.")
                .accessibilityLabel("Clones and purgeable files can make a folder read larger than what removing it would free. Hard links are counted once within each folder.")
        }
        .font(AppStyle.Typography.metadata)
        .foregroundStyle(AppColors.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Breadcrumb

/// The heading while a folder is open on the map (#437): the way back up, one
/// step per folder. Each step above the open folder goes back to it; the open
/// folder itself is the heading. A folder that was passed through shares a
/// step with the folder it holds, as `Metadata / CoreSpotlight`: its own level
/// would be one tile filling the map. The whole path shows while it fits; one
/// too long for the row keeps the first step and the last two, then the last
/// one only, with an ellipsis between that lists the steps it stands for.
/// "Everything else" and the steps above the open folder never shrink, a
/// long step name is cut to `parentStepLength` characters, and the open
/// folder's name gives way instead, so the way back is always there. Command–Up Arrow goes up one step, as in Finder.
private struct EverythingElseBreadcrumb: View {
    let openFolders: [EverythingElseFolder]
    /// Normalized paths of the open folders that were passed through.
    let passedThrough: Set<String>
    /// How many folders stay open: 0 is the whole map.
    let onClose: (Int) -> Void

    /// Steps after the first that stay shown when the path is too long to fit.
    private static let trailingSteps = 2
    /// The most characters a step above the open folder shows. A longer name
    /// is cut in the middle; its tooltip has it in full.
    private static let parentStepLength = 28

    /// `name` cut in the middle to `limit` characters, with an ellipsis.
    static func shortened(_ name: String, to limit: Int) -> String {
        guard name.count > limit else { return name }
        let side = (limit - 1) / 2
        return String(name.prefix(side)) + "…" + String(name.suffix(side))
    }
    /// A size down from the page title: on the whole map "Everything else" is
    /// the heading, inside a folder the path is, and a path is longer.
    private static let font = AppStyle.Typography.sectionTitle

    /// One step on the path: a folder, with any folders passed through to it.
    private struct Step {
        let folders: ArraySlice<EverythingElseFolder>
        /// How many folders stay open when this step is clicked.
        let keeping: Int

        var id: String { folders.last?.path ?? "" }
        var name: String { folders.map(\.displayName).joined(separator: " / ") }
    }

    private var steps: [Step] {
        var steps: [Step] = []
        var first = 0
        for (index, folder) in openFolders.enumerated()
        where index == openFolders.count - 1 || !passedThrough.contains(OverviewSizedItem.normalized(folder.path)) {
            steps.append(Step(folders: openFolders[first...index], keeping: index + 1))
            first = index + 1
        }
        return steps
    }

    var body: some View {
        let steps = steps
        ViewThatFits(in: .horizontal) {
            path(steps, hiding: 0)
            path(steps, hiding: max(0, steps.count - Self.trailingSteps))
            // Taken whenever nothing fits, so it must work at any width.
            path(steps, hiding: max(0, steps.count - 1))
        }
        // On the path as a whole, not on the step above the open folder,
        // which the narrowest path keeps under the ellipsis.
        .background { upKeys(keeping: steps.count >= 2 ? steps[steps.count - 2].keeping : 0) }
    }

    /// Command–Up Arrow, as in Finder, and Command–[, as a browser's Back
    /// does, go up one step. The buttons are never seen.
    private func upKeys(keeping count: Int) -> some View {
        ZStack {
            Button(String(localized: "Goes back up to here")) { onClose(count) }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            Button(String(localized: "Goes back up to here")) { onClose(count) }
                .keyboardShortcut("[", modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The path with the first `hidden` steps under an ellipsis.
    private func path(_ steps: [Step], hiding hidden: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xxSmallPlus) {
            step(String(localized: "Everything else"), keeping: 0)
                .fixedSize()
            if hidden > 0 {
                separator
                EverythingElseHiddenSteps(
                    steps: steps.prefix(hidden).map { (name: $0.name, keeping: $0.keeping) },
                    font: Self.font,
                    onClose: onClose
                )
                .fixedSize()
            }
            ForEach(Array(steps.enumerated()).dropFirst(hidden), id: \.element.id) { index, item in
                separator
                if index == steps.count - 1 {
                    Text(item.name)
                        .font(Self.font)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.folders.last.map { displayDirectoryPath(for: $0.url) } ?? item.name)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    step(item.name, keeping: item.keeping)
                        .fixedSize()
                }
            }
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .fixedSize()
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(AppColors.textTertiary)
            .accessibilityHidden(true)
    }

    /// A step above the open folder.
    private func step(_ title: String, keeping count: Int) -> some View {
        Button {
            onClose(count)
        } label: {
            Text(Self.shortened(title, to: Self.parentStepLength))
                .font(Self.font)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(count == 0 ? String(localized: "Back to the whole map") : String(localized: "Back to \(title)"))
        .accessibilityLabel(Text(title))
        .accessibilityHint("Goes back up to here")
    }
}

/// The ellipsis in a long path: a click lists the steps it stands for,
/// outermost first, and each goes back up to its folder.
private struct EverythingElseHiddenSteps: View {
    let steps: [(name: String, keeping: Int)]
    let font: AppStyle.TextStyle
    let onClose: (Int) -> Void

    @State private var isShown = false

    /// The most characters a name in the list shows before it is cut in the middle.
    private static let nameLength = 44

    var body: some View {
        Button {
            isShown = true
        } label: {
            Text(verbatim: "…")
                .font(font)
                .foregroundStyle(AppColors.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Go back to a folder further up"))
        .accessibilityLabel(Text("Folders further up"))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
                ForEach(steps, id: \.keeping) { step in
                    Button {
                        isShown = false
                        onClose(step.keeping)
                    } label: {
                        Text(EverythingElseBreadcrumb.shortened(step.name, to: Self.nameLength))
                            .font(AppStyle.Typography.body)
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Back to \(step.name)"))
                    .accessibilityLabel(Text(step.name))
                }
            }
            .padding(AppStyle.Spacing.small)
        }
    }
}

// MARK: - Motion

/// The page's motions. The tiles divide on `curve` under the glass while the
/// walk runs; the glass clears on `fade` once, when it is done.
enum EverythingElseMotion {
    static let curve = Animation.timingCurve(0.7, 0, 0.3, 1, duration: 0.7)
    /// How long the figures must hold still before the glass lifts. The
    /// Trash's count lands a second or two after the walk, once `du` is no
    /// longer starved by it, and it is taken under the glass.
    static let driftDelay: TimeInterval = 1.5
    static let fade = Animation.easeInOut(duration: 0.4)
    /// How long `curve` takes, so the glass over an opened folder waits for it.
    static let zoomDuration: TimeInterval = 0.7
    /// Going in, the level being left fades as it moves out, so it is half
    /// gone when it is half off the map.
    static let leavingFadeIn = curve
    /// Going back up, it holds until it has nearly shrunk into its tile and
    /// fades at the end. Inside a folder every tile has the same colour, so a
    /// level that fades early reads as a fade, not as a step back out.
    static let leavingFadeUp = Animation.easeOut(duration: 0.2).delay(0.5)
    /// The folder's own tile comes in under it first, so the two are never
    /// both see-through at once, which muddies the colour.
    static let revealUp = Animation.easeIn(duration: 0.2).delay(0.3)
    /// Its names go first either way, so they never sit over the names of
    /// the level coming in.
    static let leavingLabelFade = Animation.easeOut(duration: 0.3)
    /// The capsule's width following its text, the way the Clean button's does.
    static let capsuleWidth = Animation.spring(response: 0.38, dampingFraction: 0.92, blendDuration: 0.12)
    static let capsuleText = Animation.easeInOut(duration: 0.45)
}

// MARK: - Status line

/// "4 of 8 groups" at the right of the heading while the walk runs. Plain
/// text that changes in place; the capsule on the map says which group.
private struct EverythingElseStatusLine: View {
    let phase: EverythingElsePhase
    let measurement: EverythingElseMeasurement?

    var body: some View {
        if phase == .measuring, let measurement, !measurement.plannedGroups.isEmpty {
            Text("\(measurement.finishedGroupCount) of \(measurement.plannedGroups.count) groups")
                .font(AppStyle.Typography.callout.numbers)
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Map layout

/// What the pointer is on, or what was clicked: a group's frame or one tile.
private enum EverythingElseMapSelection: Hashable {
    case group(EverythingElseGroup)
    case item(String)
}

/// The map's geometry for one size: a frame per group, and a tile per row inside
/// it, biggest first. While the walk runs a group joins the map only once it is
/// finished, so each change is one new piece arriving while the pieces already
/// there adjust; the glass over it keeps that from being something to read.
/// Groups have no header or background of their own: the tiles sit side by
/// side, and a tile names itself and its size on hover.
private struct EverythingElseMapLayout: Equatable {
    struct Tile: Identifiable, Equatable {
        let item: EverythingElseItem
        let rect: CGRect
        /// Darker by this many steps, so neighbours inside a frame read apart.
        let shade: Int
        var id: String { item.id }
    }

    /// Groups sit as close as tiles do, so the map reads as one surface.
    /// Each tile is drawn this far inside its share, and the map this far inside
    /// its card, so every gap on the map is the same two points: between tiles
    /// of one group, between groups, and at the edge. Groups get no inset of
    /// their own, which is what made the gap between groups wider before.
    static let tileGap: CGFloat = AppStyle.Spacing.xxxSmall / 2
    /// The smallest tile that can carry a name. A folder that would be drawn
    /// smaller joins its group's "smaller folders" tile instead. It is measured
    /// in points, so a bigger window shows more folders on their own.
    static let minimumTileArea: CGFloat = 80 * 36

    let tiles: [Tile]
    /// The size the map was cut for.
    let size: CGSize
    /// The folders opened to get here, outermost first (#437). Empty for the
    /// whole map.
    let openPaths: [String]
    /// The tile new tiles grow out of: the remainder on the whole map, the
    /// opened folder's own tile inside it.
    let originTileID: String
    /// True while an opened folder is being sized: its one tile fills the map.
    let isPlaceholder: Bool

    /// The id of the remainder's tile, which is the whole map before anything
    /// is measured.
    static let wholeTileID = "system.\(EverythingElseGroup.systemData.rawValue)"

    /// The rect with each edge on a whole point. The treemap hands back
    /// fractional edges, and a tile drawn at a half point blurs its stroke
    /// and gaps unevenly: a 2-point hover ring reads thin on one side and fat
    /// on the other. Neighbours share an edge, so both round it the same way
    /// and the 1-point gap between them stays 1 point.
    static func onPixelGrid(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded()
        let minY = rect.minY.rounded()
        return CGRect(x: minX, y: minY, width: rect.maxX.rounded() - minX, height: rect.maxY.rounded() - minY)
    }

    init(breakdown: EverythingElseBreakdown?, size: CGSize) {
        let whole = CGRect(origin: .zero, size: size).insetBy(dx: Self.tileGap, dy: Self.tileGap)
        self.size = size
        openPaths = []
        originTileID = Self.wholeTileID
        isPlaceholder = false
        guard let breakdown else {
            tiles = [Tile(
                item: EverythingElseItem(group: .systemData, kind: .system, bytes: 0),
                rect: Self.onPixelGrid(whole.insetBy(dx: Self.tileGap, dy: Self.tileGap)),
                shade: 0
            )]
            return
        }

        // While the walk runs, an unfinished group's bytes stay in the remainder.
        let shown = EverythingElseGroup.allCases.filter { group in
            switch group {
            case .systemData: return false
            case .macOS, .trash: return true
            case .otherApps, .mediaLibraries, .mailAndMessages, .protectedCaches,
                 .developer, .appData, .documents, .otherUsers:
                return breakdown.isComplete || breakdown[group]?.isFinished == true
            }
        }
        var weights = shown.map { Double(breakdown.bytes(for: $0)) }
        let shownTotal = weights.reduce(0, +)
        let remainder = breakdown.isComplete
            ? Double(breakdown.systemDataBytes)
            : max(0, Double(breakdown.everythingElseBytes) - shownTotal)
        weights.append(remainder)
        let groups = shown + [.systemData]
        let groupTiles = TreemapLayout.plan(
            zip(groups, weights).map { TreemapItem(id: $0.0.rawValue, weight: $0.1) },
            in: whole,
            floorWeight: 0
        ).tiles

        var tiles: [Tile] = []
        for groupTile in groupTiles {
            guard let group = EverythingElseGroup(rawValue: groupTile.id) else { continue }
            let rect = groupTile.rect
            guard rect.width > 0, rect.height > 0 else { continue }
            var rows = EverythingElseSection.items(for: group, in: breakdown).filter { $0.bytes > 0 }
            if group == .systemData, !breakdown.isComplete {
                rows = [EverythingElseItem(group: .systemData, kind: .system, bytes: Int64(remainder))]
            }
            let total = rows.reduce(0.0) { $0 + Double($1.bytes) }
            let minimumWeight = total > 0 ? Double(Self.minimumTileArea) * total / Double(rect.width * rect.height) : 0
            // Biggest first, so the layout is the same every time for the same figures.
            let items = EverythingElseSection.rollingUpTinyRows(rows, group: group, below: minimumWeight)
                .sorted { $0.bytes > $1.bytes }
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let laid = TreemapLayout.squarify(items.map { TreemapItem(id: $0.id, weight: Double($0.bytes)) }, in: rect)
            for (index, tile) in laid.enumerated() {
                guard let item = byID[tile.id] else { continue }
                let tileRect = Self.onPixelGrid(tile.rect.insetBy(dx: Self.tileGap, dy: Self.tileGap))
                guard tileRect.width >= 2, tileRect.height >= 2 else { continue }
                tiles.append(Tile(item: item, rect: tileRect, shade: min(index, 4)))
            }
        }
        self.tiles = tiles
    }

    /// The map for an opened folder (#437): a tile per folder inside it, and
    /// the loose files, in the opened tile's colour. Before its sizing lands,
    /// one tile for the folder itself fills the map.
    init(level: EverythingElseFolderLevel?, folder: EverythingElseFolder, openPaths: [String], size: CGSize) {
        let whole = CGRect(origin: .zero, size: size).insetBy(dx: Self.tileGap, dy: Self.tileGap)
        self.size = size
        self.openPaths = openPaths
        originTileID = folder.path
        let rows: [EverythingElseItem] = (level?.items ?? []).filter { $0.bytes > 0 }
        guard !rows.isEmpty else {
            isPlaceholder = level == nil
            let item = EverythingElseItem(group: folder.group, kind: .folder(folder), bytes: folder.bytes)
            tiles = [Tile(item: item, rect: Self.onPixelGrid(whole.insetBy(dx: Self.tileGap, dy: Self.tileGap)), shade: 0)]
            return
        }
        isPlaceholder = false
        let total = rows.reduce(0.0) { $0 + Double($1.bytes) }
        let minimumWeight = Double(Self.minimumTileArea) * total / Double(max(1, whole.width * whole.height))
        let items = EverythingElseSection.rollingUpTinyRows(rows, group: folder.group, below: minimumWeight)
            .sorted { $0.bytes > $1.bytes }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var tiles: [Tile] = []
        for (index, tile) in TreemapLayout.squarify(items.map { TreemapItem(id: $0.id, weight: Double($0.bytes)) }, in: whole).enumerated() {
            guard let item = byID[tile.id] else { continue }
            let rect = Self.onPixelGrid(tile.rect.insetBy(dx: Self.tileGap, dy: Self.tileGap))
            guard rect.width >= 2, rect.height >= 2 else { continue }
            tiles.append(Tile(item: item, rect: rect, shade: min(index, 4)))
        }
        self.tiles = tiles
    }
}

// MARK: - Map

/// Each group as a block of its biggest folders (#159), sized by space and
/// coloured by what you can do. The map is also the loading state: it starts
/// as one tile, divides as groups finish, and sits under frosted glass the
/// whole time the walk runs, so its movement reads as work in progress and not
/// as a result. A capsule on the glass says which group is being measured.
/// When the walk is done the glass clears, once, and the map is already there.
/// Pointing at a tile names it beside the pointer; clicking it opens what it is
/// and its action.
private struct EverythingElseNestedMap: View {
    let breakdown: EverythingElseBreakdown?
    let phase: EverythingElsePhase
    let measurement: EverythingElseMeasurement?
    let runningStep: ScanStep?
    let highlightedBucket: EverythingElseBucket?
    /// The folders opened to get here, outermost first, and the tiles for the
    /// last one once it is sized (#437).
    let openFolders: [EverythingElseFolder]
    let level: EverythingElseFolderLevel?
    let folderSizing: EverythingElseFolderSizing?
    let onMeasure: () -> Void

    @EnvironmentObject private var store: PurgeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: EverythingElseMapSelection?
    @State private var opened: EverythingElseMapSelection?
    /// Where the pointer is, so the hover label sits beside it.
    @State private var hoverPoint: CGPoint = .zero
    @State private var pointerIsInside = false
    /// The hover label's size, read from the label itself, so it can be kept
    /// inside the map without guessing its width.
    @State private var hoverLabelSize: CGSize = .zero
    /// Where each tile is drawn right now, so a new tile can start inside the
    /// space it takes over and grow from there.
    @State private var drawn: [String: CGRect] = [:]
    /// The layout on screen. While the glass is down it is the latest one.
    /// Once the glass has lifted the map holds still: a later figure change
    /// that would move a tile (a project's git status landing and shifting a
    /// claim, a category rescan) waits in `pendingLayout` until the page is
    /// next shown, so the finished map never rearranges itself while it is
    /// being looked at. The header says when it was measured.
    @State private var shown: EverythingElseMapLayout?
    @State private var pendingLayout: EverythingElseMapLayout?
    /// The glass stays down after the walk until the figures have held still
    /// for `driftDelay`, so the map is still when it comes into view.
    @State private var holdsGlass = false
    @State private var liftWork: DispatchWorkItem?
    /// When the zoom into or out of a folder settles, so a folder's tiles that
    /// land mid-zoom wait for it rather than jump in under a moving tile.
    @State private var zoomEndsAt = Date.distantPast
    /// Keeps the glass down while landed tiles wait for the zoom to settle.
    @State private var holdsFolderGlass = false
    /// The last folder sizing, so the capsule keeps its name through that wait.
    @State private var lastFolderSizing: EverythingElseFolderSizing?
    /// The tiles of the level being left (#437). They don't vanish: going in
    /// they move out past the edges as the opened tile grows, going back up
    /// they shrink into the tile they came from, and either way they fade.
    @State private var leaving: [EverythingElseMapLayout.Tile] = []
    @State private var leavingRects: [String: CGRect] = [:]
    @State private var leavingOpacity: Double = 0
    @State private var leavingLabelOpacity: Double = 0
    /// Going back up, the leaving tiles sit over the map they shrink into;
    /// going in, under the tiles growing over them.
    @State private var leavingOnTop = false
    /// Going back up, the tile of the folder being left. It is hidden while
    /// that folder's tiles shrink into its place: drawn under them in the
    /// same colour, it would fill the gaps between them, and they would read
    /// as one block fading rather than a level going back into its tile.
    @State private var revealingTileID: String?
    @State private var revealOpacity: Double = 1
    @State private var leavingGeneration = 0

    /// Tiles smaller than this keep their colour but drop the label; the hover
    /// label names them.
    private static let labelWidth: CGFloat = 60
    private static let labelHeight: CGFloat = 32
    /// A tile this tall but too short for the size still shows its name.
    private static let nameOnlyHeight: CGFloat = 18
    /// The label's distance from the tile's left and right edges.
    private static let labelInset: CGFloat = AppStyle.Spacing.xxSmallPlus
    private static let settle = EverythingElseMotion.curve
    static let lookInsideHint = String(localized: "Double-click to look inside")

    /// The folder a tile stands for, when it can be opened.
    private static func openableFolder(_ tile: EverythingElseMapLayout.Tile, store: PurgeStore) -> EverythingElseFolder? {
        guard case .folder(let folder) = tile.item.kind, store.everythingElseCanOpen(folder) else { return nil }
        return folder
    }

    /// The folder under the pointer, for Return and Command–Down Arrow, as in
    /// Finder and other disk maps. Nothing while the map is under glass.
    private func pointedFolder(in layout: EverythingElseMapLayout) -> EverythingElseFolder? {
        guard isComplete, !isUnderGlass, case .item(let id) = hovered,
              let tile = layout.tiles.first(where: { $0.id == id })
        else { return nil }
        return Self.openableFolder(tile, store: store)
    }

    /// Return and Command–Down Arrow open the folder under the pointer. The
    /// buttons are never seen; they are there for their shortcuts, which do
    /// nothing, and let the key through, when no folder is under the pointer.
    private func lookInsideKeys(_ folder: EverythingElseFolder?) -> some View {
        ZStack {
            Button("Look Inside") { if let folder { store.openEverythingElseFolder(folder) } }
                .keyboardShortcut(.return, modifiers: [])
            Button("Look Inside") { if let folder { store.openEverythingElseFolder(folder) } }
                .keyboardShortcut(.downArrow, modifiers: [.command])
        }
        .disabled(folder == nil)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isComplete: Bool { breakdown?.isComplete == true }
    /// Folders inside the open folder excluded from scans. Their space is in
    /// its loose files tile, which says so.
    private var excludedInside: Int { openFolders.isEmpty ? 0 : (level?.excludedFolderCount ?? 0) }
    /// The glass is down while the walk is queued or running, and until the
    /// figures have stopped moving afterwards.
    private var isUnderGlass: Bool {
        phase == .waiting || phase == .measuring || holdsGlass || folderSizing != nil || holdsFolderGlass
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            GeometryReader { geometry in
                let computed = openFolders.last.map { folder in
                    EverythingElseMapLayout(level: level, folder: folder, openPaths: openFolders.map(\.path), size: geometry.size)
                } ?? EverythingElseMapLayout(breakdown: breakdown, size: geometry.size)
                let layout = shown ?? computed
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        ForEach(layout.tiles) { tile in
                            tileView(tile, rect: drawnRect(tile, origin: layout.originTileID))
                                // Going back up, the folder's own tile comes in as
                                // its folders fade, in the place they shrank into.
                                .opacity(tile.id == revealingTileID ? revealOpacity : 1)
                                // The remainder sits underneath, so a piece leaving
                                // it is seen growing out of it.
                                .zIndex(tile.id == layout.originTileID ? 0 : 1)
                                .transition(.identity)
                        }
                        // Its own identity, apart from the tiles arriving: a
                        // "smaller folders" tile can be on both levels.
                        ForEach(leaving, id: \.id) { tile in
                            leavingTile(tile)
                        }
                        .zIndex(leavingOnTop ? 2 : 0.5)
                    }
                    if isComplete {
                        hoverLabel(layout: layout, size: geometry.size)
                            .zIndex(2)
                    }
                    if isUnderGlass {
                        EverythingElseGlass(
                            phase: phase,
                            measurement: measurement,
                            runningStep: runningStep,
                            folder: folderSizing ?? (holdsFolderGlass ? lastFolderSizing : nil)
                        )
                            .zIndex(3)
                            .transition(.opacity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous))
                .background { lookInsideKeys(pointedFolder(in: layout)) }
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : EverythingElseMotion.fade, value: isUnderGlass)
                .onAppear {
                    shown = computed
                    pendingLayout = nil
                    drawn = Self.targets(computed)
                    holdsGlass = phase == .waiting || phase == .measuring
                }
                .onChange(of: computed) { layoutDidChange(to: $0) }
                .onChange(of: phase) { phaseDidChange(to: $0) }
                .onChange(of: folderSizing) { if let sizing = $0 { lastFolderSizing = sizing } }
                // One tracker for the whole map, hit-testing the tiles itself, so
                // the label always belongs to what is under the pointer.
                .onContinuousHover(coordinateSpace: .local) { hoverPhase in
                    switch hoverPhase {
                    case .active(let point):
                        hoverPoint = point
                        pointerIsInside = true
                        let target = Self.selection(at: point, in: layout)
                        if target != hovered { hovered = target }
                    case .ended:
                        pointerIsInside = false
                        hovered = nil
                    }
                }
            }
            .frame(height: EverythingElseView.mapHeight)
            .padding(AppStyle.Spacing.xSmall)
            .overviewCard()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Map of Everything else")

            if !openFolders.isEmpty {
                folderLockedLine
            } else if let breakdown {
                lockedLine(breakdown)
            }
        }
    }

    // MARK: The glass

    /// The glass goes down with the walk and comes up only once the figures
    /// have held still for `driftDelay` after it. Stop lifts it at once.
    private func phaseDidChange(to phase: EverythingElsePhase) {
        switch phase {
        case .waiting, .measuring:
            liftWork?.cancel()
            liftWork = nil
            holdsGlass = true
        case .ready:
            scheduleLift()
        case .notMeasured:
            liftWork?.cancel()
            liftWork = nil
            holdsGlass = false
        }
    }

    private func scheduleLift() {
        liftWork?.cancel()
        let work = DispatchWorkItem {
            liftWork = nil
            withAnimation(reduceMotion ? nil : EverythingElseMotion.fade) { holdsGlass = false }
        }
        liftWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EverythingElseMotion.driftDelay, execute: work)
    }

    // MARK: Taking a new layout

    /// Under the glass, every change moves the map at once and pushes the lift
    /// back, so the glass comes up on a map that has stopped. Once it is up,
    /// a change too small to see is taken with no move, and one that would
    /// move a tile is held until the page is next shown. A resize is taken at
    /// once, since the map must fit.
    private func layoutDidChange(to layout: EverythingElseMapLayout) {
        pendingLayout = nil
        if let current = shown, current.size == layout.size {
            // Opening a folder or going back up is always taken, at once.
            if current.openPaths != layout.openPaths {
                navigate(from: current, to: layout)
                return
            }
            // An opened folder's tiles landing. They take the folder's tile
            // over once the zoom into it has settled, and the glass, if the
            // sizing was slow enough to need it, lifts as they do. No "Done"
            // beat: a folder is measured in a moment, unlike the walk.
            if current.isPlaceholder {
                let wait = zoomEndsAt.timeIntervalSinceNow
                guard wait > 0 else {
                    adopt(layout, animated: true)
                    return
                }
                holdsFolderGlass = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    if shown?.openPaths == layout.openPaths, shown?.isPlaceholder == true {
                        adopt(layout, animated: true)
                    }
                    withAnimation(reduceMotion ? nil : EverythingElseMotion.fade) { holdsFolderGlass = false }
                }
                return
            }
        }
        // Read from the store, which is current; the view's own `phase` and
        // `breakdown` in this handler are the ones it was made with.
        let phase = store.everythingElsePhase
        let isComplete = store.everythingElseMeasurement?.isComplete == true
        guard let current = shown, isComplete, phase == .ready, !holdsGlass, current.size == layout.size else {
            adopt(layout, animated: true)
            if phase == .ready, holdsGlass {
                scheduleLift()
            }
            return
        }
        guard Self.movesATile(from: current, to: layout) else {
            adopt(layout, animated: false)
            return
        }
        pendingLayout = layout
    }

    private func adopt(_ layout: EverythingElseMapLayout, animated: Bool) {
        shown = layout
        if animated {
            settle(to: layout)
        } else {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { drawn = Self.targets(layout) }
        }
    }

    /// Whether any tile comes, goes, or moves by more than a hair.
    private static func movesATile(from old: EverythingElseMapLayout, to new: EverythingElseMapLayout) -> Bool {
        let before = targets(old)
        let after = targets(new)
        guard Set(before.keys) == Set(after.keys) else { return true }
        return after.contains { id, rect in
            guard let was = before[id] else { return true }
            return abs(was.minX - rect.minX) > 2 || abs(was.minY - rect.minY) > 2
                || abs(was.maxX - rect.maxX) > 2 || abs(was.maxY - rect.maxY) > 2
        }
    }

    // MARK: Opening a folder

    /// Going into a folder, the new map starts inside the tile that was opened
    /// and grows to fill the map. Going back up, it starts blown up so the
    /// folder that was open fills the map, and shrinks until that folder is
    /// its own tile again. A jump the old map has no tile for is taken still.
    private func navigate(from old: EverythingElseMapLayout, to new: EverythingElseMapLayout) {
        hovered = nil
        opened = nil
        shown = new
        let targets = Self.targets(new)
        let full = CGRect(origin: .zero, size: new.size)
        let oldRects = Self.targets(old).merging(drawn) { _, current in current }
        // Every tile of the old level leaves. No tile is on both: a level's
        // loose files and smaller folders share an id with the level above,
        // and a kept one would jump to its new place instead of moving.
        var going = old.tiles
        var start: [String: CGRect]?
        var leavingTargets: [String: CGRect] = [:]
        var revealing: String?
        if new.openPaths.count > old.openPaths.count {
            let id = new.openPaths[old.openPaths.count]
            if let anchor = oldRects[id] {
                // The opened tile itself goes at once: its folders take its
                // place exactly, and its colour under them would fill the gaps
                // that show them as folders.
                going.removeAll { $0.id == id }
                start = targets.mapValues { Self.map($0, from: full, to: anchor) }
                // The camera's move: what was around the opened tile goes out
                // past the edges as that tile grows to fill the map.
                for tile in going {
                    leavingTargets[tile.id] = Self.map(oldRects[tile.id] ?? tile.rect, from: anchor, to: full)
                }
            }
        } else if new.openPaths.count < old.openPaths.count {
            let id = old.openPaths[new.openPaths.count]
            if let anchor = targets[id] {
                revealing = id
                start = targets.mapValues { Self.map($0, from: anchor, to: full) }
                // Back into the tile they were inside.
                for tile in going {
                    leavingTargets[tile.id] = Self.map(oldRects[tile.id] ?? tile.rect, from: full, to: anchor)
                }
            }
        }
        var still = Transaction()
        still.disablesAnimations = true
        guard let start, !reduceMotion else {
            withTransaction(still) {
                drawn = targets
                leaving = []
                revealingTileID = nil
            }
            return
        }
        zoomEndsAt = Date().addingTimeInterval(EverythingElseMotion.zoomDuration)
        leavingGeneration += 1
        let generation = leavingGeneration
        withTransaction(still) {
            drawn = start
            leaving = going
            leavingRects = oldRects.filter { id, _ in leavingTargets[id] != nil }
            leavingOpacity = 1
            leavingLabelOpacity = 1
            leavingOnTop = new.openPaths.count < old.openPaths.count
            revealingTileID = revealing
            revealOpacity = 0
        }
        let fade = leavingOnTop ? EverythingElseMotion.leavingFadeUp : EverythingElseMotion.leavingFadeIn
        DispatchQueue.main.async {
            withAnimation(Self.settle) {
                drawn = targets
                leavingRects = leavingTargets
            }
            withAnimation(fade) { leavingOpacity = 0 }
            withAnimation(EverythingElseMotion.revealUp) { revealOpacity = 1 }
            withAnimation(EverythingElseMotion.leavingLabelFade) { leavingLabelOpacity = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + EverythingElseMotion.zoomDuration + 0.05) {
            guard leavingGeneration == generation else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                leaving = []
                revealingTileID = nil
            }
            // A still pointer points at the tile now under it, so Return can
            // go further in without a nudge of the mouse.
            if pointerIsInside, hovered == nil, let shown {
                hovered = Self.selection(at: hoverPoint, in: shown)
            }
        }
    }

    /// `rect` moved from `source`'s frame into `target`'s, scaled to match.
    static func map(_ rect: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return target }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        return CGRect(
            x: target.minX + (rect.minX - source.minX) * scaleX,
            y: target.minY + (rect.minY - source.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    // MARK: Growing out

    private static func targets(_ layout: EverythingElseMapLayout) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: layout.tiles.map { ($0.id, $0.rect) })
    }

    private func drawnRect(_ tile: EverythingElseMapLayout.Tile, origin: String) -> CGRect {
        drawn[tile.id] ?? Self.origin(of: tile.rect, from: drawn[origin])
    }

    /// Where a new tile starts. The part of its place that the remainder tile
    /// held, so it grows out of that tile as the tile shrinks. If it held none
    /// of it, a sliver on the tile's edge that faces the remainder.
    static func origin(of target: CGRect, from remainder: CGRect?) -> CGRect {
        guard let remainder else { return target }
        let overlap = target.intersection(remainder)
        if !overlap.isNull, overlap.width > 1, overlap.height > 1 {
            return overlap
        }
        let dx = remainder.midX - target.midX
        let dy = remainder.midY - target.midY
        if abs(dx) >= abs(dy) {
            let x = dx < 0 ? target.minX : target.maxX
            return CGRect(x: x, y: target.minY, width: 0, height: target.height)
        }
        let y = dy < 0 ? target.minY : target.maxY
        return CGRect(x: target.minX, y: y, width: target.width, height: 0)
    }

    /// Tiles already on the map move to their new place; a new one is put where
    /// it starts, without animation, and grows to its place with the rest.
    /// Slow in, slow out, with no bounce.
    private func settle(to layout: EverythingElseMapLayout) {
        let targets = Self.targets(layout)
        guard !reduceMotion else {
            drawn = targets
            return
        }
        let remainder = drawn[layout.originTileID]
        var start = drawn.filter { targets[$0.key] != nil }
        for tile in layout.tiles where start[tile.id] == nil {
            start[tile.id] = Self.origin(of: tile.rect, from: remainder)
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { drawn = start }
        DispatchQueue.main.async {
            withAnimation(Self.settle) { drawn = targets }
        }
    }

    // MARK: Hit testing

    /// The tile under the point, or nothing.
    private static func selection(at point: CGPoint, in layout: EverythingElseMapLayout) -> EverythingElseMapSelection? {
        layout.tiles.first(where: { $0.rect.contains(point) }).map { .item($0.id) }
    }

    private func isDimmed(_ group: EverythingElseGroup) -> Bool {
        guard let highlightedBucket else { return false }
        return group.bucket != highlightedBucket
    }

    private func isOpen(_ selection: EverythingElseMapSelection) -> Binding<Bool> {
        Binding(
            get: { opened == selection },
            set: { isShown in
                if isShown {
                    opened = selection
                } else if opened == selection {
                    opened = nil
                }
            }
        )
    }

    // MARK: Tiles

    @ViewBuilder
    private func tileView(_ tile: EverythingElseMapLayout.Tile, rect: CGRect) -> some View {
        if tile.item.group == .systemData, !isComplete {
            remainderTile(tile, rect: rect)
        } else {
            itemTile(tile, rect: rect)
        }
    }

    /// The part of the map the walk has not reached: one grey tile that shrinks
    /// as groups take their space. Before the first walk it carries the button
    /// that starts one; under the glass it carries nothing.
    private func remainderTile(_ tile: EverythingElseMapLayout.Tile, rect: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous)
                .fill(AppColors.textSecondary.opacity(SkeletonOpacity.light))
            if phase == .notMeasured, tile.rect.width >= 220, tile.rect.height >= 120 {
                EverythingElseStatus(onMeasure: onMeasure)
                    .padding(AppStyle.Spacing.medium)
                    .frame(maxWidth: 360)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous))
        .position(x: rect.midX, y: rect.midY)
    }

    /// A tile's fill and label, with nothing to click: what `itemTile` draws
    /// inside its button, and what a tile leaving the map draws as it goes.
    private func tileFace(_ tile: EverythingElseMapLayout.Tile, labelOpacity: Double = 1) -> some View {
        let item = tile.item
        let bucket = item.group.bucket
        let showsSize = tile.rect.width >= Self.labelWidth && tile.rect.height >= Self.labelHeight
        let showsName = showsSize || (tile.rect.width >= Self.labelWidth - 12 && tile.rect.height >= Self.nameOnlyHeight)
        let titleLines = tile.rect.height >= 56 ? 2 : 1
        return RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous)
            .fill(EverythingElseStyle.color(bucket))
            .brightness(-0.05 * Double(tile.shade))
            // An overlay, so a label wider than the tile it rides never
            // widens the tile and stays pinned to its top-left corner.
            .overlay(alignment: .topLeading) {
                if showsName {
                    // The label is laid out against the tile's final width, not
                    // the width it is animating through, so it never re-wraps
                    // mid-move: it rides the tile's corner and is clipped until
                    // the tile has grown to fit it.
                    VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                        Text(EverythingElseMapLabel.title(item, excludedFolders: excludedInside))
                            .font(AppStyle.Typography.metadataEmphasis)
                            .lineLimit(titleLines)
                        if showsSize {
                            Text(formatStorageBytes(item.bytes))
                                .font(AppStyle.Typography.metadata.numbers)
                                .monospacedDigit()
                                .lineLimit(1)
                                .opacity(0.75)
                        }
                    }
                    .foregroundStyle(EverythingElseStyle.labelColor(bucket))
                    .frame(width: max(0, tile.rect.width - 2 * Self.labelInset), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.labelInset)
                    .padding(.vertical, showsSize ? AppStyle.Spacing.xxSmallPlus : AppStyle.Spacing.xxxSmall)
                    .opacity(labelOpacity)
                }
            }
    }

    private func itemTile(_ tile: EverythingElseMapLayout.Tile, rect: CGRect) -> some View {
        let item = tile.item
        let selection = EverythingElseMapSelection.item(item.id)
        let isRinged = hovered == selection || opened == selection
        var openable: EverythingElseFolder?
        if case .folder(let folder) = item.kind, store.everythingElseCanOpen(folder) {
            openable = folder
        }
        return Button {
            // The second click of a double-click opens a folder, as in Finder.
            // The first has already shown the details; they close as it opens.
            if let openable, (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                opened = nil
                store.openEverythingElseFolder(openable)
            } else {
                opened = selection
            }
        } label: {
            tileFace(tile)
                .modifier(EverythingElseLookInsideTooltip(shows: openable != nil && Self.carriesOwnLabel(tile)))
                .overlay {
                    RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous)
                        .strokeBorder(AppColors.textPrimary, lineWidth: isRinged ? 2 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous))
        .popover(isPresented: isOpen(selection), arrowEdge: .bottom) {
            if let breakdown {
                EverythingElseDetail(
                    breakdown: breakdown,
                    group: item.group,
                    item: item,
                    isInsideFolder: !openFolders.isEmpty,
                    excludedInside: excludedInside
                )
            }
        }
        .position(x: rect.midX, y: rect.midY)
        .opacity(isDimmed(item.group) ? 0.3 : 1)
        .contextMenu { tileMenu(item) }
        .accessibilityLabel(EverythingElseMapLabel.title(item, excludedFolders: excludedInside) + ", " + formatStorageBytes(item.bytes) + ", " + EverythingElseStyle.name(item.group))
        .accessibilityHint("Shows what this is and what you can do about it")
        .modifier(EverythingElseLookInsideAction(folder: openable) { store.openEverythingElseFolder($0) })
    }

    /// Whether a tile is big enough to show its name and size itself.
    private static func carriesOwnLabel(_ tile: EverythingElseMapLayout.Tile) -> Bool {
        tile.rect.width >= labelWidth && tile.rect.height >= labelHeight
    }

    /// A tile of the level being left, moving with the zoom as it fades.
    private func leavingTile(_ tile: EverythingElseMapLayout.Tile) -> some View {
        let rect = leavingRects[tile.id] ?? tile.rect
        return tileFace(tile, labelOpacity: leavingLabelOpacity)
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous))
            .position(x: rect.midX, y: rect.midY)
            .opacity(leavingOpacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tileMenu(_ item: EverythingElseItem) -> some View {
        if case .folder(let folder) = item.kind {
            if store.everythingElseCanOpen(folder) {
                Button("Look Inside") { store.openEverythingElseFolder(folder) }
                Divider()
            }
            Button("Show in Finder") { FinderReveal.show(folder.url) }
            Button("Copy Path") { FinderReveal.copyPaths([folder.url]) }
            if let action = store.everythingElseFolderHint(for: folder)?.action {
                Button(EverythingElseStyle.actionTitle(action)) { store.performEverythingElseHint(action) }
            }
            Divider()
            Button("Exclude from scans") { store.hideFromEverythingElse(folder) }
        }
    }

    // MARK: Hover label

    /// The name and size of the tile under the pointer, drawn beside the
    /// pointer itself, so a tile too small for its own label is still readable
    /// without a click and the label is always next to what it names.
    @ViewBuilder
    private func hoverLabel(layout: EverythingElseMapLayout, size: CGSize) -> some View {
        // A tile big enough to carry its own name and size says it all already;
        // the label is for the tiles that had to drop one or both.
        if case .item(let id) = hovered, opened != hovered,
           let tile = layout.tiles.first(where: { $0.id == id }),
           !Self.carriesOwnLabel(tile) {
            let item = tile.item
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
                Text(EverythingElseMapLabel.title(item, excludedFolders: excludedInside))
                    .font(AppStyle.Typography.headline)
                    .lineLimit(1)
                Text(formatStorageBytes(item.bytes))
                    .font(AppStyle.Typography.metadata.numbers)
                    .monospacedDigit()
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                if Self.openableFolder(tile, store: store) != nil {
                    Text(Self.lookInsideHint)
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, AppStyle.Spacing.xSmall)
            .padding(.vertical, AppStyle.Spacing.xxSmallPlus)
            .background {
                RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                    .fill(AppColors.surfaceRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                    .strokeBorder(AppColors.borderStrong, lineWidth: 0.5)
            }
            .fixedSize()
            .background(GeometryReader { geometry in
                Color.clear.preference(key: EverythingElseHoverLabelSizeKey.self, value: geometry.size)
            })
            .onPreferenceChange(EverythingElseHoverLabelSizeKey.self) { hoverLabelSize = $0 }
            .position(Self.labelPosition(beside: hoverPoint, labelSize: hoverLabelSize, in: size))
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    /// Up and to the right of the pointer, the way a tooltip sits, kept inside
    /// the map: it slides left at the right edge and drops below the pointer
    /// at the top edge.
    private static func labelPosition(beside point: CGPoint, labelSize: CGSize, in size: CGSize) -> CGPoint {
        let gap: CGFloat = AppStyle.Spacing.small
        let edge: CGFloat = 2
        let halfWidth = labelSize.width / 2
        let halfHeight = labelSize.height / 2
        let x = min(max(point.x + gap + halfWidth, halfWidth + edge), max(halfWidth + edge, size.width - halfWidth - edge))
        let above = point.y - gap - halfHeight
        let y = above >= halfHeight + edge ? above : min(point.y + gap + halfHeight, size.height - halfHeight - edge)
        return CGPoint(x: x, y: y)
    }

    /// Groups and the Trash that a limited scan could not read, in one line.
    @ViewBuilder
    private func lockedLine(_ breakdown: EverythingElseBreakdown) -> some View {
        let locked = EverythingElseGroup.allCases.filter { group in
            EverythingElseSection.items(for: group, in: breakdown).contains(where: \.isLocked)
        }
        if !locked.isEmpty {
            HStack(spacing: AppStyle.Spacing.xxSmall) {
                Image(systemName: "lock")
                    .font(.system(size: 11, weight: .medium))
                Text("Needs Full Disk Access to measure: \(locked.map(EverythingElseStyle.name).joined(separator: ", "))")
            }
            .font(AppStyle.Typography.metadata)
            .foregroundStyle(AppColors.textTertiary)
            .accessibilityElement(children: .combine)
        }
    }

    /// Folders inside the opened one that a limited scan could not read.
    @ViewBuilder
    private var folderLockedLine: some View {
        if let count = level?.lockedFolderCount, count > 0 {
            HStack(spacing: AppStyle.Spacing.xxSmall) {
                Image(systemName: "lock")
                    .font(.system(size: 11, weight: .medium))
                Text(count == 1
                    ? String(localized: "1 folder inside needs Full Disk Access to measure")
                    : String(localized: "\(count) folders inside need Full Disk Access to measure"))
            }
            .font(AppStyle.Typography.metadata)
            .foregroundStyle(AppColors.textTertiary)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Look Inside as an accessibility action, on the tiles that can open only.
private struct EverythingElseLookInsideAction: ViewModifier {
    let folder: EverythingElseFolder?
    let open: (EverythingElseFolder) -> Void

    func body(content: Content) -> some View {
        if let folder {
            content.accessibilityAction(named: Text("Look Inside")) { open(folder) }
        } else {
            content
        }
    }
}

/// A tooltip saying a double-click opens the tile. A tile too small for its
/// own label gets the line in the hover label instead, so the two never show
/// at once. It sits on the tile's face, inside the button, so the button
/// keeps its VoiceOver hint.
private struct EverythingElseLookInsideTooltip: ViewModifier {
    let shows: Bool

    func body(content: Content) -> some View {
        if shows {
            content.help(EverythingElseNestedMap.lookInsideHint)
        } else {
            content
        }
    }
}

// MARK: - Glass

/// Frosted glass over the map while the walk is queued or running, with one
/// capsule in the middle: a ring for how many groups are done, the group being
/// measured, and its folder. The capsule is one size throughout; only its text
/// changes, in place. It takes the clicks, so nothing under it can be opened.
private struct EverythingElseGlass: View {
    let phase: EverythingElsePhase
    let measurement: EverythingElseMeasurement?
    let runningStep: ScanStep?
    /// A folder opened on the map being sized (#437). It takes the capsule
    /// over from the walk.
    var folder: EverythingElseFolderSizing?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The text column's natural width, read from a hidden copy, so the
    /// capsule fits its text and glides to the next size when the text changes.
    @State private var textWidth: CGFloat?

    /// A very long path is cut at this rather than widening the capsule further.
    private static let maxTextWidth: CGFloat = 360

    var body: some View {
        // The material does the blurring. A blur filter on the tiles themselves
        // would stay as a filter at radius 0 and resample the finished map,
        // smearing every edge and stroke.
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Rectangle()
                .fill(AppColors.surfaceBase.opacity(0.3))
            capsule
        }
        .accessibilityElement(children: .combine)
    }

    private var capsule: some View {
        HStack(spacing: AppStyle.Spacing.small) {
            ring
            // The visible text sits in a frame that follows the hidden copy's
            // width on a spring, the way the Clean button grows for a selection.
            // Both copies sit at their natural width, so the capsule fits its
            // text before the first width is read, and never has a flexible
            // frame that could stretch it. The read width then drives the frame.
            ZStack(alignment: .leading) {
                textColumn
                    .fixedSize(horizontal: true, vertical: false)
                textColumn
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: EverythingElseCapsuleWidthKey.self, value: geometry.size.width)
                    })
                    .accessibilityHidden(true)
            }
            .frame(width: textWidth, alignment: .leading)
            .clipped()
        }
        .padding(.vertical, AppStyle.Spacing.small)
        .padding(.leading, AppStyle.Spacing.small)
        // More air after the text than before the ring, which carries weight of its own.
        .padding(.trailing, AppStyle.Spacing.large)
        .background(Capsule(style: .continuous).fill(.regularMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(AppColors.borderStrong, lineWidth: 0.5))
        .onPreferenceChange(EverythingElseCapsuleWidthKey.self) { width in
            guard width > 0 else { return }
            withAnimation(reduceMotion ? nil : EverythingElseMotion.capsuleWidth) {
                textWidth = min(width, Self.maxTextWidth)
            }
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxxSmall) {
            Text(title)
                .font(AppStyle.Typography.headline)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : EverythingElseMotion.capsuleText, value: title)
            // No second line when there is nothing to say, so "Done" sits in
            // the middle of the capsule rather than over an empty line.
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : EverythingElseMotion.capsuleText, value: subtitle)
            }
        }
        .lineLimit(1)
    }

    /// Done over planned groups while measuring. Waiting behind another scan
    /// is an indeterminate spinner: something is running, just not this.
    @ViewBuilder
    private var ring: some View {
        if let folder {
            EverythingElseRing(fraction: folder.fraction, ceiling: 1)
        // The ring stays, full, for the beat the glass holds after the walk.
        } else if phase == .measuring || phase == .ready, let measurement, !measurement.plannedRoots.isEmpty {
            EverythingElseRing(fraction: measurement.walkFraction, ceiling: measurement.walkCeiling)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: EverythingElseRing.size, height: EverythingElseRing.size)
        }
    }

    private var title: String {
        if let folder {
            return String(localized: "Measuring \(folder.name)")
        }
        switch phase {
        case .waiting:
            guard let runningStep, runningStep != .everythingElse else { return String(localized: "Starting…") }
            return String(localized: "Waiting for \(runningStep.displayName)")
        case .measuring:
            guard let current = measurement?.currentRoot else { return String(localized: "Measuring…") }
            return String(localized: "Measuring \(EverythingElseStyle.name(current.group))")
        case .ready:
            // The glass is holding for the last tiles to settle.
            return String(localized: "Done")
        case .notMeasured:
            return ""
        }
    }

    private var subtitle: String {
        if let folder {
            return displayDirectoryPath(for: URL(fileURLWithPath: folder.path, isDirectory: true))
        }
        switch phase {
        case .waiting:
            switch runningStep {
            case .cachesAndDevTools:
                return String(localized: "Everything else is what they leave unsorted.")
            case .largeFiles, .apps, .leftovers, .everythingElse, .commandLineTools, nil:
                return String(localized: "Scans run one at a time.")
            }
        case .measuring:
            guard let current = measurement?.currentRoot else { return String(localized: "Finishing up") }
            return displayDirectoryPath(for: current.url)
        case .notMeasured, .ready:
            return ""
        }
    }
}

/// The hover label's size, read from the label itself.
private struct EverythingElseHoverLabelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The capsule text's natural width, read from its hidden copy.
private struct EverythingElseCapsuleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A determinate ring that never stands still while the walk runs. The real
/// figure is the floor: the arc catches up to it quickly when it moves. Between
/// figures the arc creeps toward `ceiling`, the point the next finished root
/// would bring it to, and never past it, so a real figure is never behind the
/// arc and the arc never moves backwards. Drawn by the clock, not by SwiftUI's
/// animation, so the two motions never fight.
private struct EverythingElseRing: View {
    let fraction: Double
    let ceiling: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = Motion()
    /// The tick has drawn in. Once the arc has closed, the ring becomes a check.
    @State private var tickDrawn = false

    static let size: CGFloat = 24
    private static let lineWidth: CGFloat = 3
    /// The tick draws in over this long, as the arc closes, so the two finish
    /// together.
    private static let tickDuration: TimeInterval = 0.4

    /// Both figures as one value, so one change handler sees both as they are
    /// now. A handler that read them off `self` saw the view it was made with,
    /// one update behind, and the ring never learned the walk had finished.
    private struct Figures: Equatable {
        let fraction: Double
        let ceiling: Double
    }

    private var figures: Figures { Figures(fraction: fraction, ceiling: ceiling) }

    /// Where the arc is heading from where it was when the figures last changed.
    private struct Motion {
        var base: Double = 0
        var since = Date.distantPast
        var real: Double = 0
        var goal: Double = 0

        /// Time to cover most of the gap: fast to a real figure, slow on the creep,
        /// and quicker still to close the ring when the walk is done.
        static let catchUp: TimeInterval = 0.4
        static let close: TimeInterval = 0.12
        static let creep: TimeInterval = 6
        /// The creep stops this short of the ceiling.
        static let shortfall = 0.015

        func value(at now: Date) -> Double {
            let elapsed = max(0, now.timeIntervalSince(since))
            let toReal = base + (real - base) * (1 - exp(-elapsed / (real >= 1 ? Self.close : Self.catchUp)))
            let toGoal = base + (goal - base) * (1 - exp(-elapsed / Self.creep))
            return min(1, max(base, toReal, toGoal))
        }

        /// Carries on from where the arc is now, toward the new figures.
        func continuing(real: Double, ceiling: Double, at now: Date) -> Motion {
            let goal = real >= 1 ? 1 : max(real, ceiling - Self.shortfall)
            return Motion(base: value(at: now), since: now, real: real, goal: goal)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppColors.textPrimary.opacity(0.14), lineWidth: Self.lineWidth)
            // Only the arc is drawn by the clock. The tick sits outside the
            // timeline so its own animation is left alone by the ticks.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let shown = reduceMotion ? fraction : motion.value(at: context.date)
                Circle()
                    .trim(from: 0, to: min(1, max(0, shown)))
                    .stroke(AppColors.textPrimary, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            // The tick draws in from its short stroke to its long one.
            Self.tick
                .trim(from: 0, to: tickDrawn ? 1 : 0)
                .stroke(AppColors.textPrimary, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: Self.size, height: Self.size)
        .onAppear {
            motion = Motion(base: fraction, since: Date(), real: fraction, goal: max(fraction, ceiling - Motion.shortfall))
            tickDrawn = fraction >= 1
        }
        .onChange(of: figures) { figures in
            motion = motion.continuing(real: figures.fraction, ceiling: figures.ceiling, at: Date())
            drawTick(ifDone: figures.fraction)
        }
        .accessibilityHidden(true)
    }

    private func drawTick(ifDone fraction: Double) {
        guard fraction >= 1 else {
            tickDrawn = false
            return
        }
        guard !reduceMotion else {
            tickDrawn = true
            return
        }
        withAnimation(.easeOut(duration: Self.tickDuration)) { tickDrawn = true }
    }

    /// A check inside the ring, short stroke first.
    private static var tick: Path {
        Path { path in
            path.move(to: CGPoint(x: 7.5, y: 12.5))
            path.addLine(to: CGPoint(x: 10.5, y: 15.5))
            path.addLine(to: CGPoint(x: 16.5, y: 9))
        }
    }
}

/// What the map says before the first walk: what measuring does, and the
/// button that starts it.
private struct EverythingElseStatus: View {
    let onMeasure: () -> Void

    var body: some View {
        VStack(spacing: AppStyle.Spacing.small) {
            Text("See what this space holds")
                .font(AppStyle.Typography.sectionTitle)
            Text("Purge walks your home folder and Library. It can take a few minutes, and nothing is changed.")
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Measure", action: onMeasure)
                .buttonStyle(.purge(.primary))
        }
        .accessibilityElement(children: .combine)
    }
}

/// What a tile or the detail calls a row.
private enum EverythingElseMapLabel {
    /// `excludedFolders` is how many folders inside an opened folder were
    /// excluded from scans: their space is in its loose files row.
    static func title(_ item: EverythingElseItem, excludedFolders: Int = 0) -> String {
        switch item.kind {
        case .folder(let folder): return folder.displayName
        case .smaller(let count, _):
            if count == 0, excludedFolders > 0 { return String(localized: "Loose files and excluded folders") }
            return EverythingElseStyle.smallerTitle(count: count)
        case .locked, .system: return EverythingElseStyle.name(item.group)
        }
    }
}

// MARK: - Detail

/// What a clicked tile or group is: its size, what it holds, what you can do about
/// it, and the one action that does it. A folder also has "Why isn't this
/// cleanable?". There is no Move to Trash here, by design (#159).
private struct EverythingElseDetail: View {
    let breakdown: EverythingElseBreakdown
    let group: EverythingElseGroup
    let item: EverythingElseItem?
    /// The tile is inside an opened folder (#437), so its loose files are that
    /// one folder's.
    var isInsideFolder = false
    /// Folders inside the open folder excluded from scans, in its loose files.
    var excludedInside = 0

    @EnvironmentObject private var store: PurgeStore
    @EnvironmentObject private var trashStore: TrashStore
    @State private var isShowingWhy = false

    private var title: String {
        item.map { EverythingElseMapLabel.title($0, excludedFolders: excludedInside) } ?? EverythingElseStyle.name(group)
    }

    private var bytes: Int64 {
        item?.bytes ?? breakdown.bytes(for: group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
                RoundedRectangle(cornerRadius: AppStyle.Radius.xs, style: .continuous)
                    .fill(EverythingElseStyle.color(group.bucket))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(title)
                    .font(AppStyle.Typography.sectionTitle)
                    .lineLimit(2)
                Spacer(minLength: AppStyle.Spacing.small)
                Text(formatStorageBytes(bytes))
                    .font(AppStyle.Typography.headline.numbers)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
            }
            if item != nil, title != EverythingElseStyle.name(group) {
                AppBadge(text: EverythingElseStyle.name(group), tone: .neutral)
                    .help(EverythingElseStyle.detail(group))
            }
            Text(note)
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            (Text(EverythingElseStyle.name(group.bucket)).fontWeight(.semibold)
                + Text(verbatim: " · ")
                + Text(EverythingElseStyle.explanation(group.bucket)).foregroundColor(AppColors.textSecondary))
                .font(AppStyle.Typography.callout)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(AppStyle.Spacing.medium)
        .frame(width: 380, alignment: .leading)
        // The popover stays glass at its edge and arrow; the text sits on a
        // mostly solid surface so it stays readable over bright tiles.
        .background(AppColors.surfaceRaised.opacity(0.88))
    }

    private var note: String {
        guard let item else { return EverythingElseStyle.detail(group) }
        switch item.kind {
        case .folder(let folder):
            let path = displayDirectoryPath(for: folder.url)
            if let hint = store.everythingElseFolderHint(for: folder) {
                return hint.steps + "\n" + path
            }
            return path
        case .smaller(let count, let biggest):
            if count == 0 {
                guard isInsideFolder else {
                    return String(localized: "Files that sit directly in these folders rather than in a folder of their own.")
                }
                return excludedInside > 0
                    ? String(localized: "Files that sit directly in this folder, and the folders inside it you excluded from scans.")
                    : String(localized: "Files that sit directly in this folder rather than in a folder inside it.")
            }
            return biggest.isEmpty
                ? String(localized: "Each is too small to show on the map by itself.")
                : String(localized: "Each is too small to show on the map by itself. These are the biggest.")
        case .locked:
            return String(localized: "Needs Full Disk Access")
        case .system:
            return EverythingElseStyle.detail(group)
        }
    }

    /// Shown by name in a smaller-folders popover, before "and N more".
    private static let listedFolderCount = 6

    @ViewBuilder
    private var actions: some View {
        if let item {
            switch item.kind {
            case .folder(let folder):
                // "Why" gets its own row, so the buttons below never have to
                // share the width with it and nothing is cut off.
                Button {
                    isShowingWhy.toggle()
                } label: {
                    HStack(spacing: AppStyle.Spacing.xxSmall) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isShowingWhy ? 90 : 0))
                            .accessibilityHidden(true)
                        Text("Why isn't this cleanable?")
                            .font(AppStyle.Typography.callout)
                    }
                    .foregroundStyle(AppColors.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isShowingWhy {
                    Text(EverythingElseStyle.whyNotCleanable(folder.group))
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: AppStyle.Spacing.xSmall) {
                    Spacer(minLength: 0)
                    Button("Show in Finder") { FinderReveal.show(folder.url) }
                        .buttonStyle(.purge(.secondary, size: .small))
                        .fixedSize()
                    let hint = store.everythingElseFolderHint(for: folder)?.action
                    // Look Inside is the way further into the map (#437). An
                    // app's own action, when there is one, stays the main button.
                    if store.everythingElseCanOpen(folder) {
                        Button("Look Inside") { store.openEverythingElseFolder(folder) }
                            .buttonStyle(.purge(hint == nil ? .primary : .secondary, size: .small))
                            .fixedSize()
                            .help("Show the folders inside, by size")
                    }
                    if let hint {
                        Button(EverythingElseStyle.actionTitle(hint)) { store.performEverythingElseHint(hint) }
                            .buttonStyle(.purge(.primary, size: .small))
                            .fixedSize()
                    }
                }
            case .smaller(let count, let biggest):
                smallerList(count: count, biggest: biggest)
            case .system where item.group == .trash:
                HStack {
                    Spacer(minLength: 0)
                    Button("Open Trash") { trashStore.openTrashInFinder() }
                        .buttonStyle(.purge(.secondary, size: .small))
                }
            case .system, .locked:
                EmptyView()
            }
        }
    }

    /// The biggest of the folders the tile stands for, each with Show in Finder,
    /// and how many more there are.
    @ViewBuilder
    private func smallerList(count: Int, biggest: [EverythingElseFolder]) -> some View {
        let listed = Array(biggest.prefix(Self.listedFolderCount))
        if !listed.isEmpty {
            VStack(spacing: 0) {
                ForEach(listed) { folder in
                    HStack(spacing: AppStyle.Spacing.xSmall) {
                        Text(folder.displayName)
                            .font(AppStyle.Typography.rowTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: AppStyle.Spacing.small)
                        Text(formatStorageBytes(folder.bytes))
                            .font(AppStyle.Typography.metadata.numbers)
                            .foregroundStyle(AppColors.textSecondary)
                            .monospacedDigit()
                        Button {
                            FinderReveal.show(folder.url)
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.purge(.quiet, size: .small, width: .square))
                        .help("Show in Finder")
                    }
                    .padding(.vertical, AppStyle.Spacing.xxxSmall)
                    .help(displayDirectoryPath(for: folder.url))
                }
                if count > listed.count {
                    Text("and \(count - listed.count) more")
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, AppStyle.Spacing.xxSmall)
                }
            }
        }
    }
}

// MARK: - Header

/// The page's header, in the band where other pages put their title: the way
/// back to the Overview on the far left, and Measure again or Stop on the right.
/// When the last walk finished shows on hover over Measure again.
struct EverythingElseHeaderBar: View {
    let now: Date

    @EnvironmentObject private var store: PurgeStore

    private var isBusy: Bool {
        store.everythingElsePhase == .measuring || store.everythingElsePhase == .waiting
    }

    private var measuredHelp: String {
        if isBusy { return String(localized: "Stop measuring") }
        guard let completedAt = store.everythingElseMeasurement?.completedAt else {
            return String(localized: "Walk the unsorted folders again")
        }
        return String(localized: "Measured \(compactAgoText(from: completedAt, to: now))")
    }

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            Button {
                store.showOverviewSummary()
            } label: {
                Label("Overview", systemImage: "chevron.left")
            }
            // A light fill without an outline: lighter than Measure again, with an
            // edge that lines up with the heading below it.
            .buttonStyle(.purge(.soft))
            // Inside a folder, Command–[ goes back up a step instead: the
            // breadcrumb's step above the open folder takes it.
            .keyboardShortcut(store.everythingElseOpenFolders.isEmpty ? KeyboardShortcut("[", modifiers: [.command]) : nil)
            .help("Back to the Overview")

            Spacer(minLength: AppStyle.Spacing.medium)

            Button {
                if isBusy {
                    store.stopEverythingElse()
                } else {
                    store.measureEverythingElseAgain()
                }
            } label: {
                CleaningButtonLabel(
                    title: isBusy ? String(localized: "Stop") : String(localized: "Measure again"),
                    systemImage: isBusy ? "stop.fill" : "arrow.clockwise",
                    isCleaning: false
                )
            }
            .buttonStyle(.purge(.secondary))
            .help(measuredHelp)
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(.top, AppDetailPageLayout.topContentInset)
        .padding(.bottom, AppStyle.Spacing.small)
    }
}
