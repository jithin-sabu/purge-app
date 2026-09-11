import AppKit
import SwiftUI

/// Dropdown whose popup is pinned to its button: never narrower than the
/// button, and with its left edge flush against the button's.
///
/// macOS places a native `Menu`'s popup itself — a few points to the left of
/// the button and sized to its own content — which reads as misaligned next to
/// the app's other controls, so the list is drawn here instead.
///
/// The list rides in a borderless child panel rather than a `.popover`, which
/// always draws a callout arrow at the anchor edge.
///
/// The caller supplies the button's own look and applies its own
/// `.buttonStyle(_:)`; the option rows override that with `.plain`.
struct AppDropdown<Option: Hashable, Trigger: View>: View {
    let options: [Option]
    let selection: Option
    let optionLabel: (Option) -> String
    let onSelect: (Option) -> Void
    @ViewBuilder let trigger: Trigger

    @State private var panel = AppDropdownPanelController()
    @State private var triggerSize: CGSize = .zero
    @State private var anchorView: NSView?

    private static var rowFont: NSFont { .systemFont(ofSize: 13) }

    /// Widest option label, plus the checkmark column, row padding and the
    /// popup's own padding. Never less than the button's width.
    ///
    /// Chrome around the label: 12 (popup padding) + 16 (row padding) + 14
    /// (checkmark) + 12 (two 6pt HStack gaps) + a little slack so the longest
    /// label never clips.
    private var popupWidth: CGFloat {
        let widest = options
            .map { (optionLabel($0) as NSString).size(withAttributes: [.font: Self.rowFont]).width }
            .max() ?? 0
        return max(triggerSize.width, ceil(widest) + 62)
    }

    var body: some View {
        Button {
            toggle()
        } label: {
            trigger
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: AppDropdownSizeKey.self, value: proxy.size)
            }
        )
        .background(AppDropdownAnchor { anchorView = $0 })
        .onPreferenceChange(AppDropdownSizeKey.self) { triggerSize = $0 }
        .onDisappear { panel.dismiss() }
    }

    private func toggle() {
        guard !panel.isVisible else {
            panel.dismiss()
            return
        }
        guard let anchorView else { return }
        panel.present(from: anchorView, width: popupWidth) {
            AnyView(optionList)
        }
    }

    private var optionList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(options, id: \.self) { option in
                AppDropdownRow(
                    label: optionLabel(option),
                    isSelected: option == selection
                ) {
                    onSelect(option)
                    panel.dismiss()
                }
            }
        }
        .padding(6)
        .frame(width: popupWidth)
        .background(AppColors.bgOverlay)
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous)
                .strokeBorder(AppColors.borderSubtle)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous))
    }
}

private struct AppDropdownRow: View {
    let label: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered ? AppColors.bgElevated : .clear,
                in: RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Hands back the `NSView` backing the trigger so the panel can be positioned
/// against its on-screen frame.
private struct AppDropdownAnchor: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Borderless child panel that carries the option list.
@MainActor
private final class AppDropdownPanelController {
    private var panel: NSPanel?
    private weak var anchor: NSView?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// Gap between the button's bottom edge and the list.
    private let verticalGap: CGFloat = 4

    var isVisible: Bool { panel != nil }

    func present(from anchor: NSView, width: CGFloat, content: () -> AnyView) {
        dismiss()

        guard let parent = anchor.window else { return }

        let hosting = NSHostingView(rootView: content())
        hosting.frame.size = NSSize(width: width, height: hosting.fittingSize.height)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.anchor = anchor
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = true
        panel.level = .popUpMenu
        panel.animationBehavior = .utilityWindow
        panel.setFrameOrigin(origin(for: anchor, in: parent, size: hosting.frame.size))

        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        panel.invalidateShadow()

        self.panel = panel
        startWatching(parent: parent)
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        anchor = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    /// True when the event is a mouse-down landing inside the trigger view, so
    /// the outside-click monitor can leave it alone and let the trigger's own
    /// `toggle()` dismiss an already-visible panel instead of reopening it.
    private func isInsideAnchor(_ event: NSEvent) -> Bool {
        guard let anchor, let window = anchor.window, event.window === window else { return false }
        let frameInWindow = anchor.convert(anchor.bounds, to: nil)
        return frameInWindow.contains(event.locationInWindow)
    }

    /// Below the button and left-aligned with it, flipped above when the
    /// screen has no room underneath.
    private func origin(for anchor: NSView, in parent: NSWindow, size: NSSize) -> NSPoint {
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var x = anchorRect.minX
        var y = anchorRect.minY - verticalGap - size.height

        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            if y < visible.minY {
                y = anchorRect.maxY + verticalGap
            }
            x = min(max(x, visible.minX), visible.maxX - size.width)
        }

        return NSPoint(x: x, y: y)
    }

    private func startWatching(parent: NSWindow) {
        let outside: (NSEvent) -> Bool = { [weak self] event in
            guard let self, let panel = self.panel else { return false }
            // A click on the trigger is technically outside the panel, but the
            // trigger's own action toggles the panel — dismissing here would let
            // it immediately reopen. Leave those clicks to `toggle()`.
            if self.isInsideAnchor(event) { return false }
            return event.window !== panel
        }

        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            if outside(event) { self?.dismiss() }
            return event
        } {
            monitors.append(local)
        }

        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
        } {
            monitors.append(global)
        }

        if let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Escape
            self?.dismiss()
            return nil
        } {
            monitors.append(key)
        }

        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: parent,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                }
            )
        }
    }
}

private struct AppDropdownSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
