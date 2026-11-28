import AppKit
import SwiftUI

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

    /// When nil, the row omits the "Exclude from scans" context-menu action.
    var onExcludeFromScans: (() -> Void)?
    /// Folders this row would delete, for the "Show in Finder" context-menu action.
    /// A closure, not an array: it is only evaluated on right-click, so no row pays
    /// for path standardization or size formatting during `body`.
    var revealLocations: (() -> [ScanRowLocation])?
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
    /// A row from the last scan's saved file (#283): dimmed, a clock where the
    /// checkbox goes, and no way to select it until the scan finds it again.
    var isFromLastScan: Bool = false
    /// Makes this row the keyboard's current row (#96). Runs on every tap of the
    /// row, before any toggle, so rows that don't toggle still take the highlight.
    var onHighlight: (() -> Void)?

    @State private var isContextMenuActive = false

    private var canSelectForBulk: Bool {
        allowsBulkSelection && !isFromLastScan
    }

    private var showsRowCheckbox: Bool {
        showsBulkCheckbox && allowsBulkSelection && !isFromLastScan
    }

    private var canTapRowToToggleSelection: Bool {
        showsBulkCheckbox && allowsBulkSelection && !isFromLastScan
    }

    private var hasExtraBadges: Bool {
        detailCaption != nil || showsReinstallBadge || showUncommittedRepoChanges
    }

    private var explanationMinHeight: CGFloat {
        usesCompactExplanation
            ? ScanResultRow.subheadlineOneLineHeight
            : ScanResultRow.subheadlineTwoLineHeight
    }

    private var explanationLineLimit: Int {
        usesCompactExplanation ? 1 : 2
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
        onExcludeFromScans: (() -> Void)? = nil,
        revealLocations: (() -> [ScanRowLocation])? = nil,
        allowsBulkSelection: Bool = true,
        showsBulkCheckbox: Bool = true,
        isMetadataPending: Bool = false,
        showsCardChrome: Bool = true,
        showsLeadingIcon: Bool = true,
        usesCompactExplanation: Bool = false,
        isFromLastScan: Bool = false,
        onHighlight: (() -> Void)? = nil
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
        self.onExcludeFromScans = onExcludeFromScans
        self.revealLocations = revealLocations
        self.allowsBulkSelection = allowsBulkSelection
        self.showsBulkCheckbox = showsBulkCheckbox
        self.isMetadataPending = isMetadataPending
        self.showsCardChrome = showsCardChrome
        self.showsLeadingIcon = showsLeadingIcon
        self.usesCompactExplanation = usesCompactExplanation
        self.isFromLastScan = isFromLastScan
        self.onHighlight = onHighlight
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
            entries.append(.action(title: String(localized: "Exclude from scans"), handler: onExcludeFromScans))
        }

        let finderEntries = FinderReveal.menuEntries(for: revealLocations?() ?? [])
        guard !finderEntries.isEmpty else { return entries }

        if !entries.isEmpty {
            entries.append(.separator)
        }
        entries.append(contentsOf: finderEntries)
        return entries
    }

    @ViewBuilder
    private var rowBody: some View {
        let stack = HStack(alignment: .center, spacing: AppStyle.Spacing.small) {
            if isFromLastScan, showsBulkCheckbox {
                LastScanRowMarker()
            } else if showsRowCheckbox {
                // Non-interactive: the row's own tap gesture publishes selection.
                // An interactive Toggle here routes clicks through AppKit's control
                // path, which scrolls the clicked row into view and shifts the list.
                Toggle("", isOn: .constant(isSelected))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .tint(AppColors.actionPrimary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            rowMainContent

            Spacer(minLength: AppStyle.Spacing.small)

            trailingColumn
        }
        .padding(.horizontal, showsCardChrome ? AppStyle.Row.scanCardHorizontalPadding : 0)
        .padding(.vertical, showsCardChrome ? AppStyle.Spacing.small : AppStyle.Spacing.xSmall)

        // The tap target must blanket the ENTIRE row, not just rowMainContent: a
        // Button/interactive control in a macOS List row scrolls the clicked row
        // into view, and any uncovered area (checkbox, spacer, trailing column)
        // falls through to the List's own native row selection, which also
        // scrolls. One whole-row gesture avoids both.
        if canTapRowToToggleSelection {
            stack
                .contentShape(Rectangle())
                .onTapGesture {
                    onHighlight?()
                    onToggle()
                }
                .accessibilityAction {
                    onToggle()
                }
        } else if isFromLastScan {
            stack
                .contentShape(Rectangle())
                .onTapGesture {
                    onHighlight?()
                }
                .help(LastScanRowMarker.help)
        } else if let onHighlight {
            stack
                .contentShape(Rectangle())
                .onTapGesture(perform: onHighlight)
        } else {
            stack
        }
    }

    private var rowMainContent: some View {
        HStack(alignment: .center, spacing: showsLeadingIcon ? AppStyle.Spacing.small : 0) {
            if showsLeadingIcon {
                rowIconView
            }
            rowTextColumn
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rowIconView: some View {
        if let brandIcon {
            AdaptiveBrandIconImage(source: brandIcon)
        }
    }

    private var rowTextColumn: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
            Text(primaryLabel)
                .font(AppStyle.Typography.headline)
                .lineLimit(1)

            Text(safetyInfo.explanation)
                .lineLimit(explanationLineLimit)
                .truncationMode(.tail)
                .font(AppStyle.Typography.metadata)
                .foregroundStyle(AppColors.textSecondary)

            if hasExtraBadges {
                badgesRow
            }
        }
        // Reserve the height on the whole column, not the explanation, so a
        // one-line explanation centres with the title instead of leaving a gap below.
        .frame(minHeight: textColumnMinHeight, alignment: .leading)
    }

    private var textColumnMinHeight: CGFloat {
        ScanResultRow.headlineOneLineHeight + 4 + explanationMinHeight
    }

    private var trailingColumn: some View {
        ScanContentCrossfade(isLoading: isMetadataPending, contentAlignment: .topTrailing) {
            trailingMetadataSkeleton
        } loaded: {
            VStack(alignment: .trailing, spacing: AppStyle.Spacing.xSmall) {
                Text(formattedSize)
                    .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                    .foregroundStyle(AppColors.textPrimary)
                    .monospacedDigit()

                AppBadge(level: safetyInfo.level)
            }
        }
    }

    private var trailingMetadataSkeleton: some View {
        VStack(alignment: .trailing, spacing: AppStyle.Spacing.xSmall) {
            SkeletonBar(width: 56, height: ScanResultRow.subheadlineOneLineHeight, cornerRadius: AppStyle.Radius.xs)
            SkeletonBar(width: 92, height: 18, cornerRadius: AppStyle.Radius.sm)
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
        HStack(alignment: .center, spacing: AppStyle.Spacing.xxSmallPlus) {
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
        if let detailCaption {
            AppBadge(text: detailCaption, tone: .neutral)
        }
        if let reinstallSafety {
            switch reinstallSafety {
            case .reinstallable:
                AppBadge(text: String(localized: "Can be rebuilt"), tone: .safe)
            case .missingLockfile:
                AppBadge(text: String(localized: "Check support files"), tone: .warning)
            case .notApplicable:
                EmptyView()
            }
        }
        if showUncommittedRepoChanges {
            AppBadge(text: String(localized: "Local changes nearby"), tone: .warning)
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
struct ScanRowAccessibilityActions: ViewModifier {
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
                content.accessibilityAction(named: Text(LocalizedStringKey(name)), handler)
            } else {
                content
            }
        }
    }
}

// MARK: - Row context menu

extension View {
    /// Same Show in Finder / Copy Path overlay App Caches and Dev Tools use.
    /// `locations` is evaluated on right-click, never during `body`.
    ///
    /// With a `rowID`, inside a list that set `scanRowMenuCenter`, the row
    /// hands its menu to that list's one shared menu view instead of carrying
    /// its own (#457).
    func finderRevealMenu(
        isMenuActive: Binding<Bool>,
        rowID: AnyHashable? = nil,
        locations: @escaping () -> [ScanRowLocation]
    ) -> some View {
        modifier(FinderRevealMenuModifier(isMenuActive: isMenuActive, rowID: rowID, locations: locations))
            .modifier(
                ScanRowAccessibilityActions(
                    onExcludeFromScans: nil,
                    revealLocations: locations
                )
            )
    }
}

private struct FinderRevealMenuModifier: ViewModifier {
    let isMenuActive: Binding<Bool>
    let rowID: AnyHashable?
    let locations: () -> [ScanRowLocation]

    @Environment(\.scanRowMenuCenter) private var center
    @State private var owner = ScanRowMenuOwner()

    func body(content: Content) -> some View {
        if let center, let rowID {
            let entries = locations
            let owner = owner
            // Not observed state: read only when the row is right-clicked.
            let _ = center.register(rowID, owner: owner, isMenuActive: isMenuActive) {
                FinderReveal.menuEntries(for: entries())
            }
            content
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(ScanRowMenuCenter.coordinateSpace))
                } action: { frame in
                    center.setFrame(frame, for: rowID, owner: owner)
                }
                .onDisappear { center.remove(rowID, owner: owner) }
        } else {
            content.overlay {
                ScanRowContextMenu(isMenuActive: isMenuActive, entries: {
                    FinderReveal.menuEntries(for: locations())
                })
            }
        }
    }
}

// MARK: - Shared row menu (#457)

/// The right-click menus of a long list, served by one AppKit view.
///
/// Each row used to carry its own `ScanRowContextMenu` view. With hundreds
/// of rows, SwiftUI updated hundreds of AppKit views whenever one row changed,
/// which made each change in the uninstaller several times slower (#457).
/// Rows here register their menu and report their frame; one
/// `ScanRowMenuCenterLayer` over the list claims the same clicks a row's own
/// view would and shows that row's menu.
@MainActor
final class ScanRowMenuCenter {
    /// The coordinate space rows report their frames in. The layer sits on
    /// the view that names it.
    static let coordinateSpace = "ScanRowMenuCenter"

    struct Menu {
        let isMenuActive: Binding<Bool>
        let entries: () -> [ScanRowMenuEntry]
    }

    /// The row's view that registered it, and its menu and frame. A row's
    /// view can be replaced by a new one for the same app, as when a sort
    /// moves a tile to another grid row. The new view registers before the old
    /// one disappears, so the old one may only clear or move what it owns.
    private struct Row {
        weak var owner: AnyObject?
        var menu: Menu
        var frame: CGRect?
    }

    private var rows: [AnyHashable: Row] = [:]

    func register(_ id: AnyHashable, owner: AnyObject, isMenuActive: Binding<Bool>, entries: @escaping () -> [ScanRowMenuEntry]) {
        let menu = Menu(isMenuActive: isMenuActive, entries: entries)
        if let row = rows[id], row.owner === owner {
            rows[id]?.menu = menu
        } else {
            rows[id] = Row(owner: owner, menu: menu, frame: nil)
        }
    }

    func setFrame(_ frame: CGRect, for id: AnyHashable, owner: AnyObject) {
        guard let row = rows[id], row.owner === owner else { return }
        rows[id]?.frame = frame
    }

    func remove(_ id: AnyHashable, owner: AnyObject) {
        guard let row = rows[id], row.owner === owner else { return }
        rows[id] = nil
    }

    /// The menu of the row at `point`, in the layer's coordinates.
    func menu(at point: CGPoint) -> Menu? {
        for row in rows.values {
            if let frame = row.frame, frame.contains(point) { return row.menu }
        }
        return nil
    }
}

/// Stands for one row view in `ScanRowMenuCenter`.
final class ScanRowMenuOwner {}

private nonisolated struct ScanRowMenuCenterKey: EnvironmentKey {
    static let defaultValue: ScanRowMenuCenter? = nil
}

extension EnvironmentValues {
    nonisolated var scanRowMenuCenter: ScanRowMenuCenter? {
        get { self[ScanRowMenuCenterKey.self] }
        set { self[ScanRowMenuCenterKey.self] = newValue }
    }
}

/// The one AppKit view that shows the rows' menus. Put it in an overlay of the
/// view that names `ScanRowMenuCenter.coordinateSpace`, so both share
/// coordinates.
struct ScanRowMenuCenterLayer: NSViewRepresentable {
    let center: ScanRowMenuCenter

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.center = center
        return view
    }

    func updateNSView(_ nsView: LayerView, context: Context) {
        nsView.center = center
    }

    final class LayerView: NSView {
        var center: ScanRowMenuCenter?
        private let menuHost = ScanRowContextMenu.MenuHostView()
        private let menuDelegate = ScanRowContextMenu.Coordinator()

        override var isFlipped: Bool { true }

        /// Claims what a row's own menu view claimed, over a row only.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let view = super.hitTest(point), let event = NSApp.currentEvent else { return nil }
            let claims: Bool
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                claims = true
            case .leftMouseDown, .leftMouseUp:
                claims = event.modifierFlags.contains(.control)
            default:
                claims = false
            }
            guard claims, center?.menu(at: convert(point, from: superview)) != nil else { return nil }
            return view
        }

        override func rightMouseDown(with event: NSEvent) {
            showMenu(for: event)
        }

        /// Control-click arrives as a left click with the control modifier.
        override func mouseDown(with event: NSEvent) {
            showMenu(for: event)
        }

        private func showMenu(for event: NSEvent) {
            guard let menu = center?.menu(at: convert(event.locationInWindow, from: nil)) else { return }
            let isMenuActive = menu.isMenuActive
            menuHost.entries = menu.entries
            menuHost.menuDelegate = menuDelegate
            menuHost.onMenuOpened = { isMenuActive.wrappedValue = true }
            menuDelegate.onMenuClosed = { isMenuActive.wrappedValue = false }
            menuHost.showMenu(for: event, in: self)
        }
    }
}

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
            // Taken now: by the time the block runs, another row's menu may
            // have opened and replaced it.
            let onMenuClosed = onMenuClosed
            DispatchQueue.main.async {
                onMenuClosed?()
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
            showMenu(for: event, in: self)
        }

        /// Control-click arrives as a left click with the control modifier.
        override func mouseDown(with event: NSEvent) {
            showMenu(for: event, in: self)
        }

        /// Shows the menu at the click, in `view`: this view, or a
        /// `ScanRowMenuCenterLayer` that serves many rows.
        func showMenu(for event: NSEvent, in view: NSView) {
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
            menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
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
                        title: NSLocalizedString(title, comment: "Scan row menu item"),
                        action: #selector(ScanRowMenuActionTarget.fire),
                        keyEquivalent: ""
                    )
                    item.target = target
                    menu.addItem(item)

                case .submenu(let title, let subEntries):
                    let item = NSMenuItem(title: NSLocalizedString(title, comment: "Scan row menu item"), action: nil, keyEquivalent: "")
                    let subMenu = NSMenu(title: NSLocalizedString(title, comment: "Scan row submenu"))
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

/// Sits where a row's checkbox goes when the row is from the last scan (#283), so
/// the column keeps its width and nothing shifts when the live row takes its place.
struct LastScanRowMarker: View {
    static let help = String(localized: "From the last scan. Purge is checking it again.")

    var body: some View {
        Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppColors.textTertiary)
            .frame(width: 14)
            .accessibilityLabel(Self.help)
    }
}

struct ScanRowCardChrome: ViewModifier {
    var showsCardChrome: Bool = true
    var canSelectForBulk: Bool = true
    var showsContextMenuHighlight: Bool = false

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppStyle.Radius.lg, style: .continuous)
    }

    func body(content: Content) -> some View {
        if showsCardChrome {
            content
                .background {
                    cardShape
                        .fill(
                            showsContextMenuHighlight
                                ? AppColors.fillSecondaryPressed
                                : AppColors.fillSecondary
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
                        RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                            .fill(AppColors.fillSecondary)
                    }
                }
                .opacity(canSelectForBulk ? 1 : 0.55)
        }
    }
}

private typealias ScanResultRowChrome = ScanRowCardChrome
