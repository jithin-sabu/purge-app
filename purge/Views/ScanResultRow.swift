import AppKit
import SwiftUI

private struct ScanRowPlaceholderAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var scanRowPlaceholderAppearance: Bool {
        get { self[ScanRowPlaceholderAppearanceKey.self] }
        set { self[ScanRowPlaceholderAppearanceKey.self] = newValue }
    }
}

/// Observes `ScanSelection` and hands the current selected state to its content, so a
/// toggle re-renders only this scope (and the row) — never the list container, whose
/// re-render reverts scroll. Mirrors the LargeFileSelection decoupling.
struct ScanSelectionScope<Content: View>: View {
    @ObservedObject var selection: ScanSelection
    let isSelected: (ScanSelection) -> Bool
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(isSelected(selection))
    }
}

struct ScanResultRow: View {
    /// Selection value + toggle callback (not a binding) so an observing scope can
    /// publish selection without re-rendering the list container.
    let isSelected: Bool
    var onToggle: () -> Void = {}
    let primaryLabel: String
    let formattedSize: String
    let safetyInfo: SafetyInfo
    /// Brand or static row icon; re-resolves for light/dark when using cache/dev/project sources.
    let brandIcon: AdaptiveBrandIconImage.Source?
    /// Small footer line (e.g. artifact kind tag).
    let detailCaption: String?
    let reinstallSafety: ReinstallSafetyStatus?
    let showUncommittedRepoChanges: Bool

    /// Clears a legacy manual category override. When nil, the corresponding
    /// badge is hidden.
    let onResetToAutomatic: (() -> Void)?
    /// When nil, the row omits the "Exclude from scans" context-menu action.
    var onExcludeFromScans: (() -> Void)?
    /// Folders this row would delete, for the "Show in Finder" context-menu action.
    /// A closure, not an array: it is only evaluated on right-click, so no row pays
    /// for path standardization or size formatting during `body`.
    var revealLocations: (() -> [ScanRowLocation])?
    let isUserOverride: Bool
    /// When `false`, the row checkbox is disabled (e.g. high-risk items that should not participate in bulk select).
    var allowsBulkSelection: Bool = true
    /// When `false`, hides the row checkbox; selection may still be driven by a parent control (e.g. project group header).
    var showsBulkCheckbox: Bool = true
    /// When true, the trailing size shows a skeleton placeholder (post-scan enrichment).
    var isMetadataPending: Bool = false
    /// When false, the row renders without its own card chrome (for nested rows inside a parent card).
    var showsCardChrome: Bool = true
    /// When false, no leading icon column is shown (e.g. expanded project artifact rows).
    var showsLeadingIcon: Bool = true
    /// When true, reserves one explanation line instead of two (e.g. simulator device rows).
    var usesCompactExplanation: Bool = false

    @Environment(\.scanRowPlaceholderAppearance) private var rendersAsPlaceholder
    @State private var isContextMenuActive = false

    private var statusLabel: String {
        safetyInfo.level.displayName
    }

    private var statusTone: AppBadge.Tone {
        switch safetyInfo.level {
        case .safe: return .safe
        case .medium: return .warning
        case .unknown: return .neutral
        }
    }

    private var canSelectForBulk: Bool {
        allowsBulkSelection
    }

    private var showsRowCheckbox: Bool {
        showsBulkCheckbox && allowsBulkSelection
    }

    private var canTapRowToToggleSelection: Bool {
        showsBulkCheckbox && allowsBulkSelection
    }

    private var hasExtraBadges: Bool {
        isUserOverride || detailCaption != nil || showsReinstallBadge || showUncommittedRepoChanges
    }

    private var explanationMinHeight: CGFloat {
        usesCompactExplanation
            ? ScanResultRow.subheadlineOneLineHeight
            : ScanResultRow.subheadlineTwoLineHeight
    }

    private var explanationLineLimit: Int {
        usesCompactExplanation ? 1 : 3
    }

    private var rowVerticalPadding: CGFloat {
        usesCompactExplanation ? 10 : 12
    }

    private var showsReinstallBadge: Bool {
        guard let reinstallSafety else { return false }
        return reinstallSafety != .notApplicable
    }

    init(
        isSelected: Bool,
        onToggle: @escaping () -> Void = {},
        primaryLabel: String,
        formattedSize: String,
        safetyInfo: SafetyInfo,
        brandIcon: AdaptiveBrandIconImage.Source?,
        detailCaption: String? = nil,
        reinstallSafety: ReinstallSafetyStatus? = nil,
        showUncommittedRepoChanges: Bool = false,
        onResetToAutomatic: (() -> Void)? = nil,
        onExcludeFromScans: (() -> Void)? = nil,
        revealLocations: (() -> [ScanRowLocation])? = nil,
        isUserOverride: Bool = false,
        allowsBulkSelection: Bool = true,
        showsBulkCheckbox: Bool = true,
        isMetadataPending: Bool = false,
        showsCardChrome: Bool = true,
        showsLeadingIcon: Bool = true,
        usesCompactExplanation: Bool = false
    ) {
        self.isSelected = isSelected
        self.onToggle = onToggle
        self.primaryLabel = primaryLabel
        self.formattedSize = formattedSize
        self.safetyInfo = safetyInfo
        self.brandIcon = brandIcon
        self.detailCaption = detailCaption
        self.reinstallSafety = reinstallSafety
        self.showUncommittedRepoChanges = showUncommittedRepoChanges
        self.onResetToAutomatic = onResetToAutomatic
        self.onExcludeFromScans = onExcludeFromScans
        self.revealLocations = revealLocations
        self.isUserOverride = isUserOverride
        self.allowsBulkSelection = allowsBulkSelection
        self.showsBulkCheckbox = showsBulkCheckbox
        self.isMetadataPending = isMetadataPending
        self.showsCardChrome = showsCardChrome
        self.showsLeadingIcon = showsLeadingIcon
        self.usesCompactExplanation = usesCompactExplanation
    }

    @ViewBuilder
    var body: some View {
        let row = rowBody
            .modifier(
                ScanResultRowChrome(
                    showsCardChrome: showsCardChrome,
                    canSelectForBulk: canSelectForBulk,
                    showsContextMenuHighlight: isContextMenuActive
                )
            )
            .animation(.easeOut(duration: 0.12), value: isContextMenuActive)

        if onExcludeFromScans != nil || revealLocations != nil {
            // Not SwiftUI's `.contextMenu`: that hands the menu to the enclosing
            // NSTableView, which then paints its own blue contextual-menu highlight
            // around the whole list row. Consuming the right-click ourselves keeps
            // the table out of it; we draw our own neutral row emphasis instead.
            row.overlay {
                ScanRowContextMenu(
                    isMenuActive: $isContextMenuActive,
                    entries: contextMenuEntries
                )
            }
            // The overlay only answers a secondary click, which VoiceOver and the
            // keyboard cannot produce; this exposes the same actions to them.
            .modifier(
                ScanRowAccessibilityActions(
                    onExcludeFromScans: onExcludeFromScans,
                    revealLocations: revealLocations
                )
            )
        } else {
            row
        }
    }

    /// Built on right-click, not during `body` — see `ScanRowContextMenu.entries`.
    private func contextMenuEntries() -> [ScanRowMenuEntry] {
        var entries: [ScanRowMenuEntry] = []

        if let onExcludeFromScans {
            entries.append(.action(title: "Exclude from scans", handler: onExcludeFromScans))
        }

        // Largest first, so the submenu leads with the folder holding the bulk.
        let locations = (revealLocations?() ?? [])
            .sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        guard !locations.isEmpty else { return entries }

        if !entries.isEmpty {
            entries.append(.separator)
        }

        if locations.count == 1 {
            let url = locations[0].url
            entries.append(.action(title: "Show in Finder") { FinderReveal.show(url) })
        } else {
            entries.append(
                .submenu(
                    title: "Show in Finder",
                    entries: locations.map { location in
                        .action(title: FinderReveal.menuTitle(for: location)) {
                            FinderReveal.show(location.url)
                        }
                    }
                )
            )
        }

        let urls = locations.map(\.url)
        entries.append(
            .action(title: urls.count == 1 ? "Copy Path" : "Copy Paths") {
                FinderReveal.copyPaths(urls)
            }
        )

        return entries
    }

    @ViewBuilder
    private var rowBody: some View {
        let stack = HStack(alignment: .center, spacing: 12) {
            if showsRowCheckbox {
                // Non-interactive: the row's own tap gesture publishes selection.
                // An interactive Toggle here routes clicks through AppKit's control
                // path, which scrolls the clicked row into view and shifts the list.
                Toggle("", isOn: .constant(isSelected))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .tint(AppColors.buttonPrimaryBg)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            rowMainContent

            Spacer(minLength: 12)

            trailingColumn
        }
        .padding(.horizontal, showsCardChrome ? AppStyle.Row.scanCardHorizontalPadding : 0)
        .padding(.vertical, showsCardChrome ? rowVerticalPadding : 8)

        // The tap target must blanket the ENTIRE row, not just rowMainContent: a
        // Button/interactive control in a macOS List row scrolls the clicked row
        // into view, and any uncovered area (checkbox, spacer, trailing column)
        // falls through to the List's own native row selection, which also
        // scrolls. One whole-row gesture avoids both.
        if canTapRowToToggleSelection {
            stack
                .contentShape(Rectangle())
                .onTapGesture {
                    onToggle()
                }
                .accessibilityAction {
                    onToggle()
                }
        } else {
            stack
        }
    }

    private var rowMainContent: some View {
        HStack(alignment: .center, spacing: showsLeadingIcon ? 12 : 0) {
            if showsLeadingIcon {
                rowIconView
            }
            rowTextColumn
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rowIconView: some View {
        if rendersAsPlaceholder {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(SkeletonOpacity.light))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                .shimmering()
        } else if let brandIcon {
            AdaptiveBrandIconImage(source: brandIcon)
        }
    }

    @ViewBuilder
    private var rowTextColumn: some View {
        if rendersAsPlaceholder {
            rowPlaceholderTextColumn
        } else {
            rowLoadedTextColumn
        }
    }

    private var rowLoadedTextColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(primaryLabel)
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            Text(safetyInfo.explanation)
                .lineLimit(explanationLineLimit)
                .truncationMode(.tail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(
                    minHeight: explanationMinHeight,
                    alignment: usesCompactExplanation ? .leading : .topLeading
                )

            if hasExtraBadges {
                badgesRow
            }
        }
    }

    private var rowPlaceholderTextColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            SkeletonFillBar(height: ScanResultRow.headlineOneLineHeight, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 4) {
                if usesCompactExplanation {
                    SkeletonFillBar(height: 10)
                } else {
                    SkeletonFillBar(height: 10)
                    SkeletonFillBar(height: 10)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: explanationMinHeight,
                alignment: .topLeading
            )

            if hasExtraBadges {
                SkeletonBar(width: 96, height: 16, cornerRadius: AppStyle.Radius.chip)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmering()
    }

    @ViewBuilder
    private var trailingColumn: some View {
        if rendersAsPlaceholder {
            trailingMetadataSkeleton
        } else {
            loadedTrailingColumn
        }
    }

    private var loadedTrailingColumn: some View {
        ScanContentCrossfade(isLoading: isMetadataPending, contentAlignment: .topTrailing) {
            trailingMetadataSkeleton
        } loaded: {
            VStack(alignment: .trailing, spacing: 8) {
                Text(formattedSize)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()

                AppBadge(text: statusLabel, tone: statusTone)
            }
        }
    }

    private var trailingMetadataSkeleton: some View {
        VStack(alignment: .trailing, spacing: 8) {
            SkeletonBar(width: 56, height: ScanResultRow.subheadlineOneLineHeight, cornerRadius: 4)
            SkeletonBar(width: 92, height: 18, cornerRadius: AppStyle.Radius.chip)
        }
        .shimmering()
    }

    /// Single-line height for `.headline` title text.
    static let headlineOneLineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .headline)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    /// Single-line height for `.subheadline` trailing size text.
    static let subheadlineOneLineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    @ViewBuilder
    private var badgesRow: some View {
        HStack(alignment: .center, spacing: 6) {
            extraBadges
        }
    }

    /// Reserves exactly two lines of subheadline-sized text so rows with short
    /// explanations don't shrink between the placeholder and loaded states.
    static let subheadlineTwoLineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        let lineHeight = font.ascender - font.descender + font.leading
        return ceil(lineHeight * 2)
    }()

    @ViewBuilder
    private var extraBadges: some View {
        if isUserOverride {
            userOverrideBadge
        }
        if let detailCaption {
            AppBadge(text: detailCaption, tone: .neutral)
        }
        if let reinstallSafety {
            switch reinstallSafety {
            case .reinstallable:
                AppBadge(text: "Can be rebuilt", tone: .safe)
            case .missingLockfile:
                AppBadge(text: "Check support files", tone: .warning)
            case .notApplicable:
                EmptyView()
            }
        }
        if showUncommittedRepoChanges {
            AppBadge(text: "Local changes nearby", tone: .warning)
        }
    }

    @ViewBuilder
    private var userOverrideBadge: some View {
        if let onResetToAutomatic {
            Button {
                onResetToAutomatic()
            } label: {
                AppBadge(text: "Manual category", tone: .accent)
            }
            .buttonStyle(.plain)
            .help("Reset to automatic")
        } else {
            AppBadge(text: "Manual category", tone: .accent)
        }
    }
}

// MARK: - Row accessibility actions

/// Exposes the right-click actions to VoiceOver and the keyboard, which cannot produce
/// a secondary click.
///
/// The Finder actions keep fixed names even when the row has several locations:
/// `accessibilityAction(named:)` needs its label during `body`, so naming one action per
/// location — or pluralizing "Copy Path" by counting them — would force the evaluation
/// and formatting we deliberately defer to right-click. "Show in Finder" therefore
/// reveals the largest location (the one the visual submenu lists first), and "Copy Path"
/// copies every location, matching what the menu's "Copy Paths" does.
private struct ScanRowAccessibilityActions: ViewModifier {
    let onExcludeFromScans: (() -> Void)?
    let revealLocations: (() -> [ScanRowLocation])?

    func body(content: Content) -> some View {
        content
            .modifier(OptionalAction(name: "Exclude from scans", handler: onExcludeFromScans))
            .modifier(OptionalAction(name: "Show in Finder", handler: revealHandler))
            .modifier(OptionalAction(name: "Copy Path", handler: copyPathsHandler))
    }

    private var revealHandler: (() -> Void)? {
        guard let revealLocations else { return nil }
        return {
            let largest = revealLocations().max { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }
            guard let largest else { return }
            FinderReveal.show(largest.url)
        }
    }

    private var copyPathsHandler: (() -> Void)? {
        guard let revealLocations else { return nil }
        return {
            FinderReveal.copyPaths(revealLocations().map(\.url))
        }
    }

    private struct OptionalAction: ViewModifier {
        let name: String
        let handler: (() -> Void)?

        func body(content: Content) -> some View {
            if let handler {
                content.accessibilityAction(named: Text(name), handler)
            } else {
                content
            }
        }
    }
}

// MARK: - Row context menu

/// One entry in a scan row's right-click menu.
enum ScanRowMenuEntry {
    case action(title: String, handler: () -> Void)
    case submenu(title: String, entries: [ScanRowMenuEntry])
    case separator
}

/// Retains a menu item's closure: `NSMenuItem.target` is weak, so the host view holds
/// these for the lifetime of the open menu.
private final class ScanRowMenuActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
    }
}

/// Right-click menu that consumes the click so NSTableView never paints its blue row
/// highlight. Left clicks pass through for normal row selection.
struct ScanRowContextMenu: NSViewRepresentable {
    @Binding var isMenuActive: Bool
    /// Evaluated on right-click, never during `body`. Building entries eagerly would
    /// standardize paths and format sizes on every render of every visible row.
    let entries: () -> [ScanRowMenuEntry]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var onMenuClosed: (() -> Void)?

        func menuDidClose(_ menu: NSMenu) {
            DispatchQueue.main.async { [weak self] in
                self?.onMenuClosed?()
            }
        }
    }

    final class MenuHostView: NSView {
        weak var menuDelegate: NSMenuDelegate?
        var entries: () -> [ScanRowMenuEntry] = { [] }
        var onMenuOpened: (() -> Void)?

        /// Keeps each item's action target alive while the menu is up.
        private var actionTargets: [ScanRowMenuActionTarget] = []

        override func rightMouseDown(with event: NSEvent) {
            showMenu(for: event)
        }

        /// Control-click arrives as a left click with the control modifier.
        override func mouseDown(with event: NSEvent) {
            showMenu(for: event)
        }

        private func showMenu(for event: NSEvent) {
            let entries = entries()
            guard !entries.isEmpty else { return }
            onMenuOpened?()
            actionTargets.removeAll()
            let menu = NSMenu()
            // Items carry explicit targets; without this, AppKit's validation path
            // would grey out the submenu parents.
            menu.autoenablesItems = false
            populate(menu, with: entries)
            menu.delegate = menuDelegate
            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        }

        private func populate(_ menu: NSMenu, with entries: [ScanRowMenuEntry]) {
            for entry in entries {
                switch entry {
                case .separator:
                    menu.addItem(.separator())

                case .action(let title, let handler):
                    let target = ScanRowMenuActionTarget(handler: handler)
                    actionTargets.append(target)
                    let item = NSMenuItem(
                        title: title,
                        action: #selector(ScanRowMenuActionTarget.fire),
                        keyEquivalent: ""
                    )
                    item.target = target
                    menu.addItem(item)

                case .submenu(let title, let subEntries):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    let subMenu = NSMenu(title: title)
                    subMenu.autoenablesItems = false
                    populate(subMenu, with: subEntries)
                    item.submenu = subMenu
                    menu.addItem(item)
                }
            }
        }

        /// Claim secondary clicks only; every other event passes to the SwiftUI row beneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown, .leftMouseUp:
                return event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
            default:
                return nil
            }
        }
    }

    func makeNSView(context: Context) -> MenuHostView {
        let view = MenuHostView()
        view.entries = entries
        wire(view: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: MenuHostView, context: Context) {
        nsView.entries = entries
        wire(view: nsView, coordinator: context.coordinator)
    }

    private func wire(view: MenuHostView, coordinator: Coordinator) {
        view.menuDelegate = coordinator
        view.onMenuOpened = { isMenuActive = true }
        coordinator.onMenuClosed = { isMenuActive = false }
    }
}

// MARK: - Row chrome

struct ScanRowCardChrome: ViewModifier {
    var showsCardChrome: Bool = true
    var canSelectForBulk: Bool = true
    var showsContextMenuHighlight: Bool = false

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppStyle.Radius.panel, style: .continuous)
    }

    func body(content: Content) -> some View {
        if showsCardChrome {
            content
                .background {
                    cardShape
                        .fill(
                            showsContextMenuHighlight
                                ? Color.primary.opacity(0.10)
                                : Color.primary.opacity(0.05)
                        )
                }
                .clipShape(cardShape)
                .overlay {
                    if showsContextMenuHighlight {
                        cardShape
                            .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
                    }
                }
                .opacity(canSelectForBulk ? 1 : 0.55)
        } else {
            content
                .background {
                    if showsContextMenuHighlight {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .opacity(canSelectForBulk ? 1 : 0.55)
        }
    }
}

private typealias ScanResultRowChrome = ScanRowCardChrome

// MARK: - Placeholder

extension ScanResultRow {
    /// Renders a `ScanResultRow` as a redacted, shimmering placeholder that matches
    /// the geometry of a real loaded row. Used by `ScanListSkeletonPlaceholder` so
    /// the loading-to-loaded crossfade has no layout shift.
    ///
    /// - Parameter showsExtraBadges: When `true`, reserves the optional badges row
    ///   beneath the subtitle (e.g. project artifact tags). Default `false` matches
    ///   typical App Cache and dev tool rows.
    static func placeholder(seed: Int, showsExtraBadges: Bool = false) -> some View {
        ScanResultRowPlaceholder(seed: seed, showsExtraBadges: showsExtraBadges)
    }
}

private struct ScanResultRowPlaceholder: View {
    let seed: Int
    var showsExtraBadges: Bool

    var body: some View {
        ScanResultRow(
            isSelected: false,
            primaryLabel: Self.primaryLabel(for: seed),
            formattedSize: Self.formattedSize(for: seed),
            safetyInfo: Self.safetyInfo(for: seed, showsExtraBadges: showsExtraBadges),
            brandIcon: nil,
            detailCaption: showsExtraBadges ? Self.detailCaption(for: seed) : nil,
            reinstallSafety: nil,
            showUncommittedRepoChanges: false,
            onResetToAutomatic: nil,
            isUserOverride: false,
            allowsBulkSelection: true,
            isMetadataPending: false
        )
        .environment(\.scanRowPlaceholderAppearance, true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let primaryLabels: [String] = [
        "Sample Application",
        "Another Cache Folder",
        "A Slightly Longer Item Name",
        "Short Name",
        "Medium-Length Title Here",
        "Yet Another Sample Item",
        "Compact",
        "Placeholder Application Title"
    ]

    private static let explanations: [String] = [
        "This cache rebuilds automatically the next time the application launches and is generally safe to remove without losing user data.",
        "Stored derived data and indexes that the tool will regenerate on the next build, so deleting it only costs a one-time rebuild.",
        "Holds intermediate artifacts that are reproducible from source. Removing them frees disk space at the cost of the next compile or fetch.",
        "Temporary files that the system or app keeps around for performance. They are recreated on demand and do not contain user content."
    ]

    private static let detailCaptions: [String] = [
        "Cache",
        "Build folder",
        "Derived data",
        "Module store"
    ]

    private static let sizeStrings: [String] = [
        "123 MB",
        "1.2 GB",
        "45 MB",
        "678 MB",
        "2.4 GB"
    ]

    private static func primaryLabel(for seed: Int) -> String {
        primaryLabels[abs(seed) % primaryLabels.count]
    }

    private static func detailCaption(for seed: Int) -> String {
        detailCaptions[abs(seed) % detailCaptions.count]
    }

    private static func formattedSize(for seed: Int) -> String {
        sizeStrings[abs(seed) % sizeStrings.count]
    }

    private static func safetyInfo(for seed: Int, showsExtraBadges: Bool) -> SafetyInfo {
        let levels: [SafetyLevel] = [.safe, .medium, .unknown]
        let level = showsExtraBadges ? levels[abs(seed) % levels.count] : .safe
        let explanation = explanations[abs(seed) % explanations.count]
        return SafetyInfo(
            level: level,
            headline: primaryLabel(for: seed),
            explanation: explanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }
}
