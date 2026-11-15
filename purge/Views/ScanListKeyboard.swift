import AppKit
import Combine
import SwiftUI

// Finder-style keys in the scan lists (#96).
//
// Each scan tab owns one `ScanListKeyboardController`. The tab hands it its
// rows in display order and what each key does to a row; the controller keeps
// the highlight, moves it, keeps it in view and runs the key's action. One
// app-wide key monitor feeds the controller of the tab that is showing.
//
// The highlight is not the selection: moving it never ticks a row. It lives in
// its own observable, like `ScanSelection` and `LargeFileSelection`, so a move
// redraws the rows and never the List itself, whose redraw reverts the scroll.
// Rows are kept in view by asking the row's own AppKit view to scroll itself
// visible, never through ScrollViewReader (see `LargeFilesView.resultsList`).

/// Which row of a scan list is current. Observed only by the rows.
@MainActor
final class ScanHighlight<ID: Hashable>: ObservableObject {
    @Published var id: ID?
    /// Whether the ring shows on the current row. Like a browser's
    /// `:focus-visible`, it shows once a list key is pressed and hides on the
    /// next click: a click still makes its row current, without the ring.
    @Published var showsRing = false
}

/// What the keys do to a row of one tab. Every action returns whether it acted;
/// a refusal beeps, as Finder does.
@MainActor
struct ScanListKeyActions<ID: Hashable> {
    /// Return or X.
    var toggle: (ID) -> Bool
    /// ⌘⌫. Opens the row's confirm sheet, on the route its tab already uses.
    var trash: (ID) -> Bool
    /// Space. Nil means there is nothing to preview.
    var previewURL: (ID) -> URL?
    /// ⌘C. The paths to copy, largest first; empty beeps.
    var copyURLs: (ID) -> [URL]
    /// Whether the row is still in the scan results at all, as opposed to only
    /// hidden by a filter or search. A row that left them, as after a trash,
    /// hands the highlight to the next row.
    var stillExists: (ID) -> Bool
    /// The group a nested row sits in, for ← and for a group that closes.
    var parent: (ID) -> ID? = { _ in nil }
    /// → in a list: open the group. False when the row is no closed group.
    var expand: (ID) -> Bool = { _ in false }
    /// ← in a list: close the group. False when the row is no open group.
    var collapse: (ID) -> Bool = { _ in false }
    /// ⌘↓ and ⌘↑ in the grid: open or close the group's tray.
    var openGroup: (ID) -> Bool = { _ in false }
    var closeGroup: (ID) -> Bool = { _ in false }
    /// True in the Uninstaller's grid, where ← and → step through the tiles.
    var arrowsStepSideways = false
}

/// What the app-wide monitor needs from the controller of the tab that shows.
@MainActor
protocol ScanListKeyResponder: AnyObject {
    /// The window the list is in, or nil while no row is on screen.
    var window: NSWindow? { get }
    /// True while a sheet, review, clean or alert owns the window.
    var isBlocked: Bool { get }
    func perform(_ key: ScanListKey, isRepeat: Bool) -> Bool
}

@MainActor
final class ScanListKeyboardController<ID: Hashable>: ScanListKeyResponder {
    let highlight = ScanHighlight<ID>()
    let anchors = ScanRowAnchorRegistry()

    private(set) var rows: [[ID]] = []
    private var order: [ID] = []
    private var orderSet: Set<ID> = []
    private var actions: ScanListKeyActions<ID>?
    private var blocked: () -> Bool = { false }
    /// The order the highlight was last reconciled against.
    private var reconciledOrder: [ID] = []

    var window: NSWindow? { anchors.window }

    var isBlocked: Bool { blocked() || !FirstRunGate.hasCompletedOnboarding }

    /// Called from the tab's body with the rows as drawn now.
    func update(rows: [[ID]], actions: ScanListKeyActions<ID>, isBlocked: @escaping () -> Bool) {
        self.rows = rows
        self.actions = actions
        self.blocked = isBlocked
        let order = rows.flatMap { $0 }
        if order != self.order {
            self.order = order
            orderSet = Set(order)
        }
    }

    /// A click on a row makes it the current one, without the ring. No scroll:
    /// it is on screen.
    func highlight(_ id: ID) {
        if highlight.showsRing { highlight.showsRing = false }
        guard highlight.id != id else { return }
        highlight.id = id
        followWithPreview(id)
    }

    /// The list appeared with this order.
    func orderDidAppear(_ order: [ID]) {
        reconciledOrder = order
    }

    /// The list's order changed: a filter, a search, a scan, a trash, a group.
    func orderDidChange(to newOrder: [ID]) {
        let oldOrder = reconciledOrder
        reconciledOrder = newOrder
        guard let current = highlight.id, let actions else { return }
        let next = ScanListHighlight.reconciled(
            current,
            oldOrder: oldOrder,
            newOrder: newOrder,
            stillExists: actions.stillExists,
            parent: actions.parent
        )
        guard next != current else { return }
        highlight.id = next
        guard let next else {
            if QuickLookPreview.isVisible { QuickLookPreview.close() }
            return
        }
        anchors.requestScroll(to: AnyHashable(next), from: nil, direction: nil)
        followWithPreview(next)
    }

    func perform(_ key: ScanListKey, isRepeat: Bool) -> Bool {
        let used = performKey(key, isRepeat: isRepeat)
        // Any key the list used shows the ring on the current row, the one a
        // click made current included.
        if used, highlight.id != nil, !highlight.showsRing { highlight.showsRing = true }
        return used
    }

    private func performKey(_ key: ScanListKey, isRepeat: Bool) -> Bool {
        guard let actions else { return false }
        let current = highlight.id.flatMap { orderSet.contains($0) ? $0 : nil }

        switch key {
        case .up:
            return move(.up)
        case .down:
            return move(.down)
        case .left, .right:
            if let current {
                if key == .right, actions.expand(current) { return true }
                if key == .left {
                    if actions.collapse(current) { return true }
                    if !actions.arrowsStepSideways, let parent = actions.parent(current), orderSet.contains(parent) {
                        moveHighlight(to: parent, from: current, direction: .up)
                        return true
                    }
                }
            }
            if actions.arrowsStepSideways { return move(key == .left ? .left : .right) }
            // Nothing to open or close: swallow the key so the List underneath
            // doesn't act on it, but only when a row is current.
            return current != nil
        case .openGroup, .closeGroup:
            guard let current else { return false }
            guard !isRepeat else { return true }
            let acted = key == .openGroup ? actions.openGroup(current) : actions.closeGroup(current)
            if !acted { NSSound.beep() }
            return true
        case .space:
            if QuickLookPreview.isVisible {
                QuickLookPreview.close()
                return true
            }
            guard let current else { return false }
            guard !isRepeat else { return true }
            if let url = actions.previewURL(current) {
                QuickLookPreview.show(url: url)
            } else {
                NSSound.beep()
            }
            return true
        case .toggle:
            guard let current else { return false }
            guard !isRepeat else { return true }
            if !actions.toggle(current) { NSSound.beep() }
            return true
        case .trash:
            guard let current else { return false }
            guard !isRepeat else { return true }
            QuickLookPreview.close()
            if !actions.trash(current) { NSSound.beep() }
            return true
        case .copy:
            guard let current else { return false }
            guard !isRepeat else { return true }
            let urls = actions.copyURLs(current)
            if urls.isEmpty {
                NSSound.beep()
            } else {
                FinderReveal.copyPaths(urls)
            }
            return true
        }
    }

    /// An arrow. A highlight scrolled out of sight counts as none, so the key
    /// starts from the first row on screen instead of yanking the list back.
    private func move(_ direction: ScanListHighlight.Direction) -> Bool {
        let from = highlight.id.flatMap { orderSet.contains($0) && anchors.isOnScreen(AnyHashable($0)) ? $0 : nil }
        let firstVisible = order.first { anchors.isMostlyVisible(AnyHashable($0)) }
        guard let next = ScanListHighlight.moved(from: from, direction, in: rows, firstVisible: firstVisible) else {
            return false
        }
        moveHighlight(to: next, from: from, direction: direction)
        return true
    }

    private func moveHighlight(to next: ID, from: ID?, direction: ScanListHighlight.Direction) {
        anchors.requestScroll(to: AnyHashable(next), from: from.map(AnyHashable.init), direction: direction)
        guard highlight.id != next else { return }
        highlight.id = next
        followWithPreview(next)
    }

    /// With the preview open, it follows the highlight, as in Finder.
    private func followWithPreview(_ id: ID) {
        guard QuickLookPreview.isVisible else { return }
        if let url = actions?.previewURL(id) {
            QuickLookPreview.update(url: url)
        } else {
            QuickLookPreview.close()
        }
    }
}

// MARK: - The key monitor

/// One local key-down monitor for the whole app. The tab that appeared last
/// gets the keys: tabs crossfade, so the old tab's `onDisappear` can come after
/// the new tab's `onAppear`, and each list only ever removes itself.
@MainActor
final class ScanListKeyMonitor {
    static let shared = ScanListKeyMonitor()

    private struct Entry {
        weak var responder: ScanListKeyResponder?
    }

    private var entries: [Entry] = []
    private var monitor: Any?

    func activate(_ responder: ScanListKeyResponder) {
        entries.removeAll { $0.responder == nil || $0.responder === responder }
        entries.append(Entry(responder: responder))
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                ScanListKeyMonitor.shared.handle(event) ? nil : event
            }
        }
    }

    func deactivate(_ responder: ScanListKeyResponder) {
        entries.removeAll { $0.responder == nil || $0.responder === responder }
        guard entries.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// True when a list used the key, which then goes no further.
    private func handle(_ event: NSEvent) -> Bool {
        guard let responder = entries.last?.responder,
              let window = responder.window,
              let key = ScanListKey(
                  keyCode: event.keyCode,
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                  modifierFlags: event.modifierFlags
              )
        else { return false }

        let fromPreview = QuickLookPreview.isPreviewWindow(event.window)
        guard event.window === window || fromPreview else { return false }
        guard window.attachedSheet == nil, NSApp.modalWindow == nil, !responder.isBlocked else { return false }
        // A dropdown or popover open over the list owns the keys.
        if window.childWindows?.contains(where: \.isVisible) == true { return false }
        // Typing in a search field, or a control focused from the keyboard, keeps
        // its keys. A preview's own text view doesn't count: the keys there are ours.
        if !fromPreview, Self.firstResponderTakesKeys(window.firstResponder) { return false }

        return responder.perform(key, isRepeat: event.isARepeat)
    }

    private static func firstResponderTakesKeys(_ responder: NSResponder?) -> Bool {
        if responder is NSText { return true }
        if let control = responder as? NSControl, !(control is NSTableView) { return true }
        return false
    }
}

// MARK: - Keeping the current row in view

/// The AppKit views behind the rows on screen, by row id. Lists drop rows that
/// scroll away, so only rows near the visible part are here.
@MainActor
final class ScanRowAnchorRegistry {
    private final class Weak {
        weak var view: ScanRowAnchorView?
        init(_ view: ScanRowAnchorView) { self.view = view }
    }

    private var views: [AnyHashable: Weak] = [:]
    /// A row the highlight moved to before the list had drawn it.
    private var pendingScroll: AnyHashable?

    var window: NSWindow? {
        for entry in views.values {
            if let window = entry.view?.window { return window }
        }
        return nil
    }

    func register(_ view: ScanRowAnchorView, id: AnyHashable) {
        views[id] = Weak(view)
        if pendingScroll == id {
            pendingScroll = nil
            // After this layout pass, once the row has its final frame.
            DispatchQueue.main.async { [weak view] in view?.scrollIntoView() }
        }
    }

    func unregister(_ view: ScanRowAnchorView, id: AnyHashable) {
        if views[id]?.view === view { views[id] = nil }
    }

    private func mountedView(_ id: AnyHashable) -> ScanRowAnchorView? {
        guard let view = views[id]?.view, view.window != nil else { return nil }
        return view
    }

    func isOnScreen(_ id: AnyHashable) -> Bool {
        guard let view = mountedView(id) else { return false }
        return !view.visibleRect.isEmpty
    }

    func isMostlyVisible(_ id: AnyHashable) -> Bool {
        guard let view = mountedView(id), view.bounds.height > 0 else { return false }
        return view.visibleRect.height >= view.bounds.height / 2
    }

    /// Scrolls `id` into view. A row the list hasn't drawn yet is reached by
    /// first scrolling the space past the row it came from into view, which
    /// makes the list draw it; it then scrolls itself the rest of the way.
    func requestScroll(to id: AnyHashable, from previous: AnyHashable?, direction: ScanListHighlight.Direction?) {
        if let view = mountedView(id) {
            pendingScroll = nil
            view.scrollIntoView()
            return
        }
        pendingScroll = id
        if let previous, let direction, let view = mountedView(previous) {
            view.scrollPast(direction)
        }
    }
}

/// An empty AppKit view behind a row. It never takes clicks.
final class ScanRowAnchorView: NSView {
    fileprivate var rowID: AnyHashable?
    fileprivate weak var registry: ScanRowAnchorRegistry?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reregister()
    }

    fileprivate func set(id: AnyHashable, registry: ScanRowAnchorRegistry) {
        guard id != rowID || registry !== self.registry else { return }
        if let rowID { self.registry?.unregister(self, id: rowID) }
        rowID = id
        self.registry = registry
        reregister()
    }

    private func reregister() {
        guard let rowID, let registry else { return }
        if window == nil {
            registry.unregister(self, id: rowID)
        } else {
            registry.register(self, id: rowID)
        }
    }

    /// Space kept between the row and the list's edges, so the row clears the
    /// soft edge under the header.
    private var margin: CGFloat { AppStyle.Spacing.large }

    func scrollIntoView() {
        scrollToVisible(bounds.insetBy(dx: 0, dy: -margin))
    }

    /// Scrolls the space one row beyond this one into view.
    fileprivate func scrollPast(_ direction: ScanListHighlight.Direction) {
        let height = bounds.height
        switch direction {
        case .down, .right:
            scrollToVisible(NSRect(x: 0, y: 0, width: bounds.width, height: height * 2 + margin))
        case .up, .left:
            scrollToVisible(NSRect(x: 0, y: -(height + margin), width: bounds.width, height: height * 2 + margin))
        }
    }
}

private struct ScanRowAnchor: NSViewRepresentable {
    let id: AnyHashable
    let registry: ScanRowAnchorRegistry

    func makeNSView(context: Context) -> ScanRowAnchorView {
        let view = ScanRowAnchorView()
        view.set(id: id, registry: registry)
        return view
    }

    func updateNSView(_ view: ScanRowAnchorView, context: Context) {
        // Lists reuse row views for other rows.
        view.set(id: id, registry: registry)
    }
}

// MARK: - Modifiers

/// How the highlight ring sits on a row.
enum ScanListRingPlacement {
    /// Just outside the card, like a focus ring, so it never reads as the
    /// selection outline some cards draw on their own edge (the app tiles).
    case outside
    /// On the card's edge, for a row inside a card that clips what it holds.
    case inside
}

/// Draws the highlight ring on the current row.
private struct ScanListHighlightRing<ID: Hashable>: View {
    @ObservedObject var highlight: ScanHighlight<ID>
    let id: ID
    let cornerRadius: CGFloat
    let placement: ScanListRingPlacement

    private static var gap: CGFloat { AppStyle.Spacing.xxxSmall }

    var body: some View {
        if highlight.id == id, highlight.showsRing {
            switch placement {
            case .outside:
                RoundedRectangle(cornerRadius: cornerRadius + Self.gap, style: .continuous)
                    .strokeBorder(AppColors.actionPrimary, lineWidth: 2)
                    .padding(-Self.gap)
                    .allowsHitTesting(false)
            case .inside:
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppColors.actionPrimary, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Wires a scan list to the keys. `rows` is the order as drawn: one id per
    /// row in a list, up to four per row in a grid.
    func scanListKeyboard<ID: Hashable>(
        _ controller: ScanListKeyboardController<ID>,
        rows: [[ID]],
        actions: ScanListKeyActions<ID>,
        isBlocked: @escaping () -> Bool
    ) -> some View {
        modifier(ScanListKeyboardModifier(controller: controller, rows: rows, actions: actions, isBlocked: isBlocked))
    }

    /// Marks a row of a keyboard-wired scan list: the ring when it is current,
    /// and the anchor that keeps it in view. Put it on the row's card, outside
    /// its padding, so the ring follows the card's edge.
    func scanListRow<ID: Hashable>(
        _ id: ID,
        in controller: ScanListKeyboardController<ID>,
        cornerRadius: CGFloat = AppStyle.Radius.lg,
        ring placement: ScanListRingPlacement = .outside
    ) -> some View {
        background(ScanRowAnchor(id: AnyHashable(id), registry: controller.anchors))
            .overlay(ScanListHighlightRing(
                highlight: controller.highlight, id: id, cornerRadius: cornerRadius, placement: placement
            ))
    }
}

private struct ScanListKeyboardModifier<ID: Hashable>: ViewModifier {
    let controller: ScanListKeyboardController<ID>
    let rows: [[ID]]
    let actions: ScanListKeyActions<ID>
    let isBlocked: () -> Bool

    func body(content: Content) -> some View {
        let order = rows.flatMap { $0 }
        // Not observed state: the monitor reads it when a key comes in.
        let _ = controller.update(rows: rows, actions: actions, isBlocked: isBlocked)
        content
            .onAppear { ScanListKeyMonitor.shared.activate(controller) }
            .onDisappear { ScanListKeyMonitor.shared.deactivate(controller) }
            .modifier(OrderChangeObserver(order: order, controller: controller))
    }
}

/// Reconciles the highlight when the order changes. The previous order is
/// kept on the controller, not in view state, so nothing here redraws the List.
private struct OrderChangeObserver<ID: Hashable>: ViewModifier {
    let order: [ID]
    let controller: ScanListKeyboardController<ID>

    func body(content: Content) -> some View {
        content
            .onAppear { controller.orderDidAppear(order) }
            .onChange(of: order) { newOrder in
                controller.orderDidChange(to: newOrder)
            }
    }
}
