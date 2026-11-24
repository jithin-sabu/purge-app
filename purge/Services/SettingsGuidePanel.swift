import AppKit
import Combine
import SwiftUI

/// A small floating panel that sits beside the System Settings window and shows
/// what to switch on, for every moment Purge has to hand over to macOS (#450):
/// Full Disk Access, allowing Purge in the background (the deleted-apps watcher
/// and the secure removal helper), and installing or removing the Apple
/// Intelligence download-block profile (#133).
///
/// It shows a copy of the row to look for rather than instructions about it,
/// and says it is waiting. When its owner sees the change, `finish` turns it into
/// a check for a moment, closes it and brings Purge back. It is on screen only
/// while System Settings is the frontmost app, so it never floats over anything
/// else. The window list gives System Settings' position without any permission,
/// so the panel follows the window, with its pointer on the side that faces it.
/// It never takes focus.
@MainActor
final class SettingsGuidePanel {
    static let shared = SettingsGuidePanel()

    enum Guide: Equatable {
        case fullDiskAccess
        case allowInBackground
        case installProfile
        case removeProfile
    }

    /// The panel's edge that faces System Settings, where its pointer goes.
    enum PointerEdge: Equatable {
        case leading
        case trailing
        case top
        case none
    }

    /// What the view draws. One instance for the panel's life, so a change of
    /// state redraws in place instead of rebuilding the view.
    final class Model: ObservableObject {
        @Published var guide: Guide = .fullDiskAccess
        @Published var isDone = false
        @Published var pointer: PointerEdge = .none
    }

    private let model = Model()
    private var panel: NSPanel?
    private(set) var shown: Guide?
    private var followTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var closeTask: Task<Void, Never>?
    private var onCancel: (() -> Void)?

    private static let gap: CGFloat = AppStyle.Spacing.xSmall
    private static let systemSettingsBundleID = "com.apple.systempreferences"
    /// Ten times a second keeps the panel beside a window being dragged. Each
    /// tick is one window-list read, and it runs only while the panel is visible.
    private static let followInterval: TimeInterval = 0.1
    /// How long the check shows before the panel closes.
    nonisolated static let doneDisplayTime: Duration = .milliseconds(1400)

    /// Whether the panel is on screen right now.
    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows `guide`. One System Settings pane is on screen at a time, so a guide
    /// for another flow is replaced, and that flow is told its guide was
    /// cancelled, so it stops waiting instead of waiting with no guide. The same
    /// guide shown again keeps showing; the newest caller owns its Not Now.
    func show(_ guide: Guide, onCancel: @escaping () -> Void) {
        if let previous = shown, previous != guide, let replaced = self.onCancel {
            self.onCancel = nil
            shown = nil
            replaced()
        }
        closeTask?.cancel()
        closeTask = nil
        self.onCancel = onCancel
        shown = guide
        model.guide = guide
        model.isDone = false

        let panel = self.panel ?? makePanel()
        self.panel = panel
        resize()
        watchFrontmostApp()
        updateVisibility()
    }

    func hide() {
        closeTask?.cancel()
        closeTask = nil
        stopFollowing()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        onCancel = nil
        shown = nil
        model.isDone = false
        panel?.orderOut(nil)
    }

    /// Hides the panel only while it shows `guide`, so one flow never closes
    /// another's guide.
    func hide(_ guide: Guide) {
        if shown == guide { hide() }
    }

    /// The change `guide` asked for has landed. While the user is looking at the
    /// panel it shows a check, then closes and brings Purge forward, where the
    /// flow carries on. When it is not on screen it just closes. Does nothing
    /// while another guide shows.
    func finish(_ guide: Guide) {
        guard shown == guide else { return }
        onCancel = nil
        shown = nil
        guard isVisible else {
            hide()
            return
        }
        model.isDone = true
        resize()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.doneDisplayTime)
            guard !Task.isCancelled, let self else { return }
            let bringPurgeBack = Self.isSystemSettingsFrontmost()
            self.closeTask = nil
            self.hide()
            if bringPurgeBack { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    private func cancel() {
        let handler = onCancel
        hide()
        handler?()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // It follows System Settings, so there is nothing to drag it for, and a
        // movable background would take the drag meant for the Purge icon.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = FirstMouseHostingView(
            rootView: SettingsGuideView(model: model) { [weak self] in self?.cancel() }
        )
        return panel
    }

    /// Fits the panel to its content, keeping its top edge where it was.
    private func resize() {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        let top = panel.frame.maxY
        panel.setFrame(
            NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
            display: false
        )
        if panel.isVisible { place() }
    }

    // MARK: Showing only beside System Settings

    private func watchFrontmostApp() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
    }

    /// On screen while System Settings is in front; hidden, with its state kept,
    /// while anything else is.
    private func updateVisibility() {
        guard let panel, shown != nil || model.isDone else { return }
        if Self.isSystemSettingsFrontmost() {
            place()
            if !panel.isVisible { panel.orderFrontRegardless() }
            startFollowing()
        } else {
            stopFollowing()
            panel.orderOut(nil)
        }
    }

    private static func isSystemSettingsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == systemSettingsBundleID
    }

    private func startFollowing() {
        guard followTimer == nil else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: Self.followInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    // MARK: Placement

    /// Beside the System Settings window, on whichever display holds it, with
    /// the pointer on the edge that faces the window. See `placement`.
    private func place() {
        guard let panel else { return }
        let size = panel.frame.size
        let window = Self.systemSettingsFrame()
        let screen = window.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main
        guard let screen else { return }
        let placement = Self.placement(panelSize: size, window: window, visible: screen.visibleFrame, gap: Self.gap)
        if model.pointer != placement.pointer { model.pointer = placement.pointer }
        if panel.frame.origin != placement.origin {
            panel.setFrameOrigin(placement.origin)
        }
    }

    /// Where the panel goes for a System Settings window at `window`, in AppKit
    /// screen coordinates, and which of its edges then faces the window: to the
    /// window's right when there is room, else to its left, else just below it.
    /// With no window, the top-right corner of the screen, with no pointer.
    nonisolated static func placement(
        panelSize size: NSSize, window: NSRect?, visible: NSRect, gap: CGFloat
    ) -> (origin: NSPoint, pointer: PointerEdge) {
        guard let window else {
            return (NSPoint(x: visible.maxX - size.width - gap, y: visible.maxY - size.height - gap), .none)
        }
        let right = NSPoint(x: window.maxX + gap, y: window.maxY - size.height)
        let left = NSPoint(x: window.minX - size.width - gap, y: window.maxY - size.height)
        let below = NSPoint(x: window.minX, y: window.minY - size.height - gap)
        var origin: NSPoint
        let pointer: PointerEdge
        if right.x + size.width <= visible.maxX {
            origin = right
            pointer = .leading
        } else if left.x >= visible.minX {
            origin = left
            pointer = .trailing
        } else {
            origin = below
            pointer = .top
        }
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        return (origin, pointer)
    }

    /// The frontmost System Settings window, in AppKit screen coordinates.
    /// Window bounds and owners come without Screen Recording permission; only
    /// titles are gated, and none are needed.
    private static func systemSettingsFrame() -> NSRect? {
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: systemSettingsBundleID).first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        let pid = settings.processIdentifier
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  width > 200, height > 200
            else { continue }
            // Window-list bounds count from the top-left of the main display.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: x, y: mainHeight - y - height, width: width, height: height)
        }
        return nil
    }
}

/// The panel never becomes key, so its first click would otherwise only bring
/// it forward. Not Now and the Purge icon answer the first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the panel shows: Purge's icon and what to do, a copy of the row to look
/// for, a line or two on where it is, and whether Purge is still waiting.
struct SettingsGuideView: View {
    @ObservedObject var model: SettingsGuidePanel.Model
    let onCancel: () -> Void

    static let cardWidth: CGFloat = 280

    private var guide: SettingsGuidePanel.Guide { model.guide }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            header
            targetRow
            if !model.isDone {
                stepList
                if guide == .fullDiskAccess { dragHint }
            }
            footer
        }
        .padding(AppStyle.Spacing.medium)
        .frame(width: Self.cardWidth, alignment: .leading)
        .padding(GuideCalloutShape.caretDepth)
        .background(GuideCalloutShape(pointer: model.pointer).fill(AppColors.surfaceRaised))
        .overlay(GuideCalloutShape(pointer: model.pointer).stroke(AppColors.borderSubtle, lineWidth: 1))
    }

    /// Title only: the row below carries Purge's icon, once.
    private var header: some View {
        Text(title)
            .font(AppStyle.Typography.headline)
            .foregroundStyle(AppColors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A copy of the row System Settings shows, so the user looks for a picture
    /// rather than reading where to click. Once done, the same spot says so.
    private var targetRow: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            if model.isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.statusSafeText)
                    .accessibilityHidden(true)
                Text(doneText)
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 0)
            } else {
                switch guide {
                case .fullDiskAccess, .allowInBackground:
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(verbatim: "Purge")
                        .font(AppStyle.Typography.rowTitle)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer(minLength: AppStyle.Spacing.xSmall)
                    SwitchedOnMark()
                case .installProfile, .removeProfile:
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(AppleIntelligenceDownloadBlock.profileDisplayName)
                        .font(AppStyle.Typography.rowTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(minHeight: 22)
        .padding(.horizontal, AppStyle.Spacing.small)
        .padding(.vertical, AppStyle.Spacing.xSmall)
        .background(AppColors.surfaceCard, in: RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous)
                .strokeBorder(model.isDone ? AppColors.statusSafeText : AppColors.borderSubtle)
        )
        .modifier(DragsPurgeApp(isOn: guide == .fullDiskAccess && !model.isDone))
    }

    /// One line needs no number; several are numbered in the order the user
    /// meets them.
    private var stepList: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
                    if steps.count > 1 {
                        Text(verbatim: "\(index + 1).")
                            .font(AppStyle.Typography.callout.weight(.semibold).numbers)
                            .foregroundStyle(AppColors.textTertiary)
                            .monospacedDigit()
                    }
                    Text(step)
                        .font(AppStyle.Typography.callout)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Purge is listed once it has asked for a protected folder, and a user can
    /// take it off with the minus button. The row above can be dragged onto the
    /// list, which adds the app as dropping it from Finder does.
    private var dragHint: some View {
        Text("Not in the list? Drag the Purge row above into it.")
            .font(AppStyle.Typography.metadata)
            .foregroundStyle(AppColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            if model.isDone {
                Text("Back to Purge…")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textTertiary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(waitingText)
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: AppStyle.Spacing.small)
                Button("Not now", action: onCancel)
                    .buttonStyle(.purge(.quiet, size: .small))
            }
        }
        .frame(minHeight: 22)
    }

    private var title: String {
        switch guide {
        case .fullDiskAccess: return String(localized: "Allow Full Disk Access")
        case .allowInBackground: return String(localized: "Allow Purge in the background")
        case .installProfile: return String(localized: "Install the Purge profile")
        case .removeProfile: return String(localized: "Remove the Purge profile")
        }
    }

    private var steps: [String] {
        switch guide {
        case .fullDiskAccess:
            return [
                String(localized: "Switch Purge on."),
                String(localized: "If macOS offers to reopen Purge, go ahead."),
            ]
        case .allowInBackground:
            // macOS 27 renamed the section; 13 through 26 call it Allow in the Background.
            let renamed = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            return [
                renamed
                    ? String(localized: "Scroll down to Background App Activity.")
                    : String(localized: "Scroll down to Allow in the Background."),
                String(localized: "Switch Purge on."),
            ]
        case .installProfile:
            return [
                String(localized: "Double-click it under Downloaded."),
                String(localized: "Click Install…, then Install again when macOS asks."),
                String(localized: "Enter your password if it asks for one."),
            ]
        case .removeProfile:
            return [
                String(localized: "Select it, then click the minus button below the list."),
                String(localized: "Click Remove."),
                String(localized: "Enter your password if it asks for one."),
            ]
        }
    }

    private var waitingText: String {
        switch guide {
        case .fullDiskAccess, .allowInBackground: return String(localized: "Waiting for the switch")
        case .installProfile: return String(localized: "Waiting for the install")
        case .removeProfile: return String(localized: "Waiting for the removal")
        }
    }

    private var doneText: String {
        switch guide {
        case .fullDiskAccess: return String(localized: "Full Disk Access is on")
        case .allowInBackground: return String(localized: "Purge is allowed in the background")
        case .installProfile: return String(localized: "Profile installed")
        case .removeProfile: return String(localized: "Profile removed")
        }
    }
}

/// Lets the Full Disk Access row be dragged onto System Settings' list as the
/// Purge app itself. The hint line under the steps says it can be.
private struct DragsPurgeApp: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help(String(localized: "Drag Purge into the Full Disk Access list"))
        } else {
            content
        }
    }
}

/// A switch drawn on, as System Settings draws it in the user's accent colour.
/// A real `Toggle` would show dimmed, because the panel is never the key window.
private struct SwitchedOnMark: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(AppColors.systemControlAccent)
            .frame(width: 26, height: 15)
            .overlay(alignment: .trailing) {
                Circle()
                    .fill(AppColors.systemControlKnob)
                    .frame(width: 13, height: 13)
                    .padding(.trailing, AppStyle.Spacing.xxxSmall / 2)
            }
            .accessibilityHidden(true)
    }
}

/// The panel's card: a rounded rectangle with a small pointer on the edge that
/// faces System Settings. Drawn as one outline so the border runs around the
/// pointer instead of across it.
struct GuideCalloutShape: Shape {
    var pointer: SettingsGuidePanel.PointerEdge

    /// How far the pointer sticks out. The card is inset by this on every side,
    /// so moving the pointer never changes the panel's size.
    static let caretDepth: CGFloat = AppStyle.Spacing.xSmall
    private static let caretHalfWidth: CGFloat = AppStyle.Spacing.xSmall
    /// From the card's top (or leading edge, for a pointer on top) to the
    /// pointer's middle: level with the header.
    private static let caretOffset: CGFloat = AppStyle.Spacing.medium + AppStyle.Spacing.small

    func path(in rect: CGRect) -> Path {
        let card = rect.insetBy(dx: Self.caretDepth, dy: Self.caretDepth)
        let r = min(AppStyle.Radius.lg, card.width / 2, card.height / 2)
        let d = Self.caretDepth
        let h = Self.caretHalfWidth
        let (minX, minY, maxX, maxY) = (card.minX, card.minY, card.maxX, card.maxY)
        var path = Path()
        path.move(to: CGPoint(x: minX + r, y: minY))
        if pointer == .top {
            let x = minX + Self.caretOffset
            path.addLine(to: CGPoint(x: x - h, y: minY))
            path.addLine(to: CGPoint(x: x, y: minY - d))
            path.addLine(to: CGPoint(x: x + h, y: minY))
        }
        path.addLine(to: CGPoint(x: maxX - r, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + r), radius: r)
        if pointer == .trailing {
            let y = minY + Self.caretOffset
            path.addLine(to: CGPoint(x: maxX, y: y - h))
            path.addLine(to: CGPoint(x: maxX + d, y: y))
            path.addLine(to: CGPoint(x: maxX, y: y + h))
        }
        path.addLine(to: CGPoint(x: maxX, y: maxY - r))
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - r, y: maxY), radius: r)
        path.addLine(to: CGPoint(x: minX + r, y: maxY))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - r), radius: r)
        if pointer == .leading {
            let y = minY + Self.caretOffset
            path.addLine(to: CGPoint(x: minX, y: y + h))
            path.addLine(to: CGPoint(x: minX - d, y: y))
            path.addLine(to: CGPoint(x: minX, y: y - h))
        }
        path.addLine(to: CGPoint(x: minX, y: minY + r))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + r, y: minY), radius: r)
        path.closeSubpath()
        return path
    }
}
