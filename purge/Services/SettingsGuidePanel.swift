import AppKit
import SwiftUI

/// A small floating panel that sits beside the System Settings window and says
/// what to click, for the two moments Purge has to hand over to macOS: installing
/// the Apple Intelligence download-block profile and removing it (#133). The
/// window list gives System Settings' position without any permission, so the
/// panel follows the window as it moves and comes back when it is behind
/// something. It never takes focus, and it goes away on its own once the store
/// sees the profile change.
@MainActor
final class SettingsGuidePanel {
    static let shared = SettingsGuidePanel()

    enum Guide: Equatable {
        case installProfile
        case removeProfile
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private var onCancel: (() -> Void)?

    private static let width: CGFloat = 300
    private static let gap: CGFloat = 14
    private static let systemSettingsBundleID = "com.apple.systempreferences"

    func show(_ guide: Guide, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        onCancel = nil
        panel?.orderOut(nil)
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

    /// Beside the System Settings window: to its right when there is room, else
    /// to its left, else just below it. With no System Settings window on screen,
    /// the top-right corner of the main screen, where the user will look for it.
    private func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.maxX - size.width - Self.gap, y: visible.maxY - size.height - Self.gap)
        if let window = Self.systemSettingsFrame() {
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
                            .font(AppStyle.Typography.callout.weight(.semibold))
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
        }
    }

    private var steps: [String] {
        switch guide {
        case .installProfile:
            return [
                String(localized: "In System Settings, double-click \"Purge: Apple Intelligence models removed\" under Downloaded."),
                String(localized: "Click Install…, then Install again when macOS asks."),
                String(localized: "Enter your password if it asks for one."),
            ]
        case .removeProfile:
            return [
                String(localized: "In System Settings, select \"Purge: Apple Intelligence models removed\"."),
                String(localized: "Click the minus button below the list, then Remove."),
                String(localized: "Enter your password if it asks for one."),
            ]
        }
    }
}
