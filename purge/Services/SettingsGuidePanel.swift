import AppKit
import SwiftUI

/// A small floating panel that sits beside the System Settings window and says
/// what to click, for the moments Purge has to hand over to macOS: installing
/// the Apple Intelligence download-block profile and removing it (#133), and
/// allowing the deleted-apps watcher in Login Items. The
/// window list gives System Settings' position without any permission, so the
/// panel follows the window as it moves and comes back when it is behind
/// something. It never takes focus, and it goes away on its own once its owner
/// sees the change it asked for.
@MainActor
final class SettingsGuidePanel {
    static let shared = SettingsGuidePanel()

    enum Guide: Equatable {
        case installProfile
        case removeProfile
        case allowInBackground
    }

    private var panel: NSPanel?
    private(set) var shown: Guide?
    private var timer: Timer?
    private var onCancel: (() -> Void)?

    private static let width: CGFloat = 300
    private static let gap: CGFloat = AppStyle.Spacing.medium
    private static let systemSettingsBundleID = "com.apple.systempreferences"

    /// Shows `guide`. One System Settings pane is on screen at a time, so a guide
    /// for another flow is replaced, and that flow is told its guide was
    /// cancelled, so it stops waiting instead of waiting with no guide.
    func show(_ guide: Guide, onCancel: @escaping () -> Void) {
        if let previous = shown, previous != guide, let replaced = self.onCancel {
            self.onCancel = nil
            shown = nil
            replaced()
        }
        self.onCancel = onCancel
        shown = guide
        let content = SettingsGuideView(guide: guide) { [weak self] in self?.cancel() }
        let hosting = NSHostingView(rootView: content)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = self.panel ?? Self.makePanel()
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.panel = panel
        place()
        panel.orderFrontRegardless()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        onCancel = nil
        shown = nil
        panel?.orderOut(nil)
    }

    /// Hides the panel only while it shows `guide`, so one flow never closes
    /// another's guide.
    func hide(_ guide: Guide) {
        if shown == guide { hide() }
    }

    private func cancel() {
        let handler = onCancel
        hide()
        handler?()
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Beside the System Settings window, on whichever display holds it: to its
    /// right when there is room, else to its left, else just below it. With no
    /// System Settings window on screen, the top-right corner of the main screen,
    /// where the user will look for it.
    private func place() {
        guard let panel else { return }
        let size = panel.frame.size
        let window = Self.systemSettingsFrame()
        let screen = window.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.maxX - size.width - Self.gap, y: visible.maxY - size.height - Self.gap)
        if let window {
            let right = NSPoint(x: window.maxX + Self.gap, y: window.maxY - size.height)
            let left = NSPoint(x: window.minX - size.width - Self.gap, y: window.maxY - size.height)
            let below = NSPoint(x: window.minX, y: window.minY - size.height - Self.gap)
            if right.x + size.width <= visible.maxX {
                origin = right
            } else if left.x >= visible.minX {
                origin = left
            } else {
                origin = below
            }
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
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

/// What the panel says. Short, numbered, in the order the user meets things.
struct SettingsGuideView: View {
    let guide: SettingsGuidePanel.Guide
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
            HStack(spacing: AppStyle.Spacing.xSmall) {
                Image(systemName: "hand.point.left.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textSecondary)
                Text(title)
                    .font(AppStyle.Typography.headline)
                    .foregroundStyle(AppColors.textPrimary)
            }
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
                        Text("\(index + 1).")
                            .font(AppStyle.Typography.callout.weight(.semibold).numbers)
                            .foregroundStyle(AppColors.textSecondary)
                            .monospacedDigit()
                        Text(step)
                            .font(AppStyle.Typography.callout)
                            .foregroundStyle(AppColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Text("Purge carries on by itself once that's done.")
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textTertiary)
                Spacer(minLength: AppStyle.Spacing.small)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.purge(.quiet, size: .small))
            }
        }
        .padding(AppStyle.Spacing.medium)
        .frame(width: 300)
        .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppStyle.Radius.md, style: .continuous).strokeBorder(AppColors.borderSubtle))
        .padding(AppStyle.Spacing.xSmall)
    }

    private var title: String {
        switch guide {
        case .installProfile: return String(localized: "Install the Purge profile")
        case .removeProfile: return String(localized: "Remove the Purge profile")
        case .allowInBackground: return String(localized: "Allow Purge in the background")
        }
    }

    private var steps: [String] {
        switch guide {
        case .installProfile:
            return [
                String(localized: "In System Settings, double-click \"\(AppleIntelligenceDownloadBlock.profileDisplayName)\" under Downloaded."),
                String(localized: "Click Install…, then Install again when macOS asks."),
                String(localized: "Enter your password if it asks for one."),
            ]
        case .removeProfile:
            return [
                String(localized: "In System Settings, select \"\(AppleIntelligenceDownloadBlock.profileDisplayName)\"."),
                String(localized: "Click the minus button below the list, then Remove."),
                String(localized: "Enter your password if it asks for one."),
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
        }
    }
}
