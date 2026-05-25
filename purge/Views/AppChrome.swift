import AppKit
import SwiftUI

struct AppBrandMark: View {
    var iconSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text("Purge")
                .font(.system(size: 14, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Purge")
    }
}

/// Sidebar column insets — brand mark and nav selection share the same leading edge.
enum SidebarLayout {
    static let horizontalInset: CGFloat = 8
    static let navRowInnerPadding: CGFloat = 8
    static let selectionCornerRadius: CGFloat = 6
    /// Clears unified title-bar traffic lights without the extra safe-area gap.
    static let topContentInset: CGFloat = 36
}

/// Shared horizontal inset for Settings-style detail pages (App Caches, Dev Tools, Settings).
enum AppDetailPageLayout {
    static let horizontalInset: CGFloat = 24
    /// Space below the title bar before page content begins.
    static let topContentInset: CGFloat = 20
    static let verticalPadding: CGFloat = 12
}

/// Page header matching Settings section typography (`.headline` + subtitle).
struct AppSectionPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppStyle.Typography.pageTitle)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppStyle.Spacing.medium)

            trailing()
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(.top, AppDetailPageLayout.topContentInset)
        .padding(.bottom, AppStyle.Spacing.small)
    }
}

/// Scan and Clean Selected — top-trailing actions on App Caches / Dev Tools pages.
struct AppScanCleanActions: View {
    let onScan: () -> Void

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            AppScanButton(action: onScan)
            AppCleanSelectedButton()
        }
        .fixedSize()
    }
}

struct AppScanButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Scan", systemImage: "arrow.clockwise")
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
        .keyboardShortcut("r", modifiers: [.command])
    }
}

struct AppCleanSelectedButton: View {
    @EnvironmentObject private var store: PurgeStore

    private var title: String {
        guard store.selectedCount > 0 else { return "Clean Selected" }
        return "Clean Selected (\(formatBytes(store.selectedTotalBytes)))"
    }

    var body: some View {
        Button {
            store.showDeletionSheet = true
        } label: {
            Label(title, systemImage: "trash.fill")
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(AppButtonStyle(variant: .filled, isCapsule: true))
        .disabled(store.selectedCount == 0 || store.isDeleting)
    }
}

struct AppPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppStyle.Spacing.xxSmall) {
                Text(title)
                    .font(AppStyle.Typography.pageTitle)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppStyle.Spacing.medium)

            trailing()
        }
        .padding(.horizontal, AppStyle.Spacing.large)
        .padding(.top, AppStyle.Spacing.large)
        .padding(.bottom, AppStyle.Spacing.small)
    }
}

struct AppButtonStyle: ButtonStyle {
    enum Variant {
        case bordered
        case filled
        case ghost
        case destructive
    }

    var variant: Variant = .bordered
    var isCapsule: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(labelFont)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, isCapsule ? 14 : 10)
            .padding(.vertical, isCapsule ? 7 : 6)
            .background(background(configuration: configuration))
            .overlay(border)
            .clipShape(buttonShape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
    }

    private var labelFont: Font {
        let size: CGFloat = isCapsule ? 13 : 12
        let design: Font.Design = isCapsule ? .rounded : .default
        return .system(size: size, weight: .semibold, design: design)
    }

    private var buttonShape: AnyShape {
        if isCapsule {
            return AnyShape(Capsule(style: .continuous))
        }
        return AnyShape(RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous))
    }

    private var foregroundStyle: Color {
        switch variant {
        case .bordered, .ghost:
            return .primary
        case .filled:
            return .white
        case .destructive:
            return AppStyle.danger
        }
    }

    private func background(configuration: Configuration) -> Color {
        switch variant {
        case .bordered:
            return configuration.isPressed ? AppStyle.rowHover : AppStyle.elevated
        case .filled:
            return AppStyle.accent
        case .ghost:
            return configuration.isPressed ? AppStyle.rowHover : .clear
        case .destructive:
            return AppStyle.danger.opacity(configuration.isPressed ? 0.18 : 0.1)
        }
    }

    @ViewBuilder
    private var border: some View {
        if isCapsule {
            Capsule(style: .continuous)
                .stroke(variant == .filled ? Color.clear : AppStyle.hairline)
        } else {
            RoundedRectangle(cornerRadius: AppStyle.Radius.control, style: .continuous)
                .stroke(variant == .filled ? Color.clear : AppStyle.hairline)
        }
    }
}

struct AppBadge: View {
    enum Tone {
        case neutral
        case accent
        case safe
        case warning
        case danger
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(AppStyle.Typography.metadataEmphasis)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous)
                    .stroke(color.opacity(0.14))
            }
            .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous))
    }

    private var color: Color {
        switch tone {
        case .neutral: return .secondary
        case .accent: return AppStyle.accent
        case .safe: return AppStyle.safe
        case .warning: return AppStyle.warning
        case .danger: return AppStyle.danger
        }
    }
}

struct AppNavRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppStyle.Spacing.xSmall) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? AppStyle.accent : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: AppStyle.Spacing.xSmall)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, SidebarLayout.navRowInnerPadding)
            .padding(.vertical, 6)
            .background(navBackground, in: RoundedRectangle(cornerRadius: SidebarLayout.selectionCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var navBackground: Color {
        if isSelected {
            return AppStyle.accent.opacity(0.12)
        }
        if isHovering {
            return AppStyle.rowHover
        }
        return .clear
    }
}

struct AppSortMenu: View {
    @Binding var selection: SortOption

    var body: some View {
        Menu {
            ForEach(SortOption.allCases) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            Label(selection.shortDisplayName, systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .buttonStyle(AppButtonStyle(variant: .bordered))
        .fixedSize()
        .accessibilityLabel("Sort by \(selection.displayName)")
    }
}

enum AppWindowLayout {
    static let width: CGFloat = 980
    static let minHeight: CGFloat = 600
    static let defaultHeight: CGFloat = 700
}

private enum FixedWindowWidthStorage {
    static var delegateKey: UInt8 = 0
}

/// Clamps live resize attempts; SwiftUI often overrides `minSize` / `maxSize` alone.
private final class FixedWindowWidthDelegate: NSObject, NSWindowDelegate {
    let fixedWidth: CGFloat
    let minHeight: CGFloat
    private weak var chainedDelegate: NSWindowDelegate?

    init(fixedWidth: CGFloat, minHeight: CGFloat, chainedDelegate: NSWindowDelegate?) {
        self.fixedWidth = fixedWidth
        self.minHeight = minHeight
        self.chainedDelegate = chainedDelegate
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let clamped = NSSize(
            width: fixedWidth,
            height: max(frameSize.height, minHeight)
        )
        if let chainedDelegate,
           chainedDelegate.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))) {
            return chainedDelegate.windowWillResize!(sender, to: clamped)
        }
        return clamped
    }
}

private struct FixedWindowWidthConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorHostingView {
        ConfiguratorHostingView()
    }

    func updateNSView(_ nsView: ConfiguratorHostingView, context: Context) {
        nsView.applyWindowSizePolicy()
    }

    final class ConfiguratorHostingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowSizePolicy()
        }

        func applyWindowSizePolicy() {
            guard let window else { return }
            let width = AppWindowLayout.width
            let minHeight = AppWindowLayout.minHeight

            window.minSize = NSSize(width: width, height: minHeight)
            window.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)

            if let existing = objc_getAssociatedObject(
                window,
                &FixedWindowWidthStorage.delegateKey
            ) as? FixedWindowWidthDelegate {
                if window.delegate !== existing {
                    window.delegate = existing
                }
            } else {
                let delegate = FixedWindowWidthDelegate(
                    fixedWidth: width,
                    minHeight: minHeight,
                    chainedDelegate: window.delegate
                )
                objc_setAssociatedObject(
                    window,
                    &FixedWindowWidthStorage.delegateKey,
                    delegate,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
                window.delegate = delegate
            }

            clampFrameIfNeeded(window, width: width, minHeight: minHeight)
            removeSidebarToggle(from: window)
            disableSidebarCollapse(in: window)
        }

        override func layout() {
            super.layout()
            if let window {
                removeSidebarToggle(from: window)
            }
        }

        private func removeSidebarToggle(from window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            let toggleID = "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
            while let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == toggleID }) {
                toolbar.removeItem(at: index)
            }
        }

        private func disableSidebarCollapse(in window: NSWindow) {
            guard let splitView = window.contentView?.firstDescendant(where: { $0 is NSSplitView }) as? NSSplitView,
                  let controller = splitView.delegate as? NSSplitViewController else {
                return
            }
            for item in controller.splitViewItems {
                item.canCollapse = false
                item.canCollapseFromWindowResize = false
            }
        }

        private func clampFrameIfNeeded(_ window: NSWindow, width: CGFloat, minHeight: CGFloat) {
            var frame = window.frame
            let targetHeight = max(frame.height, minHeight)
            guard abs(frame.width - width) > 0.5 || abs(frame.height - targetHeight) > 0.5 else { return }

            let widthDelta = width - frame.width
            frame.size.width = width
            frame.origin.x -= widthDelta
            if abs(frame.height - targetHeight) > 0.5 {
                frame.origin.y += frame.height - targetHeight
                frame.size.height = targetHeight
            }
            window.setFrame(frame, display: false)
        }
    }
}

/// Collapses the empty toolbar strip NavigationSplitView reserves above the detail column.
private struct DetailColumnCompactTopModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("")
            .modifier(DetailColumnToolbarCollapseModifier())
            .ignoresSafeArea(.container, edges: .top)
    }
}

private struct DetailColumnToolbarCollapseModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else if #available(macOS 14.0, *) {
            content
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

private struct SidebarToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

/// Pulls sidebar header + nav up under the unified toolbar (tighter than default safe area).
private struct SidebarCompactTopModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
    }
}

private extension NSView {
    func firstDescendant(where predicate: (NSView) -> Bool) -> NSView? {
        if predicate(self) { return self }
        for subview in subviews {
            if let match = subview.firstDescendant(where: predicate) {
                return match
            }
        }
        return nil
    }
}

extension View {
    func fixedAppWindowWidth() -> some View {
        background(FixedWindowWidthConfigurator())
    }

    func detailColumnCompactTop() -> some View {
        modifier(DetailColumnCompactTopModifier())
    }

    func sidebarToolbarHidden() -> some View {
        modifier(SidebarToolbarModifier())
    }

    func sidebarCompactTop() -> some View {
        modifier(SidebarCompactTopModifier())
    }
}

