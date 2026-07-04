import AppKit
import Combine
import SwiftUI

// MARK: - Palette

/// Menu-local colors. Keeps the redesign self-contained without touching
/// `AppColors`. Accent is our blue; ready/junk is amber; success is green.
enum MenuPalette {
    static let accent = dynamic(light: 0x185FA5, dark: 0x2F7FD1)
    static let amber = dynamic(light: 0xE08A00, dark: 0xF2B84B)
    static let success = AppColors.tagSafeText

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

// MARK: - Menu bar label icon

/// MenuBarExtra ignores SwiftUI asset sizing; load the template asset as
/// `NSImage`, set a menu-bar point size, then bridge to SwiftUI.
struct MenuBarStatusIcon: View {
    private static let barHeight: CGFloat = 14

    var body: some View {
        Image(nsImage: Self.image)
    }

    static let image: NSImage = {
        guard let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage else {
            return NSImage(systemSymbolName: "paintbrush.fill", accessibilityDescription: "Purge")!
        }
        let ratio = image.size.height / max(image.size.width, 1)
        image.size = NSSize(width: barHeight / ratio, height: barHeight)
        image.isTemplate = true
        return image
    }()
}

// MARK: - Layout

private enum MenuLayout {
    static let rowInset: CGFloat = 6
    static let rowContentInset: CGFloat = 10
    static let contentHorizontalInset: CGFloat = rowInset + rowContentInset
    static let mutedStatusOpacity: Double = 0.78
    static let disabledRowOpacity: Double = 0.35
}

// MARK: - Content

/// State-driven menu dropdown. A window-style panel rather than a native menu:
/// menu tracking freezes the main dispatch queue, so a native menu can never
/// resolve `checking → ready` while open — this panel updates live in place.
/// The trade-off (accepted deliberately): an auto-hidden menu bar slides away
/// while the panel is open, because only real menu tracking pins it.
struct MenuBarContentView: View {
    @ObservedObject var model: MenuViewModel
    @EnvironmentObject private var store: PurgeStore
    /// The panel hierarchy stays alive while the panel is hidden (the `.window`
    /// panel is reused across opens), so every repeating timer in this view
    /// must be gated on this flag or it keeps waking the app while closed.
    @State private var panelIsVisible = false

    private enum Metrics {
        static let panelWidth: CGFloat = 240
        static let dividerInset: CGFloat = 12
        /// Constant height for the single-line hero states (checking / clear /
        /// ready / cleaned) so the action rows below never jump when the state
        /// swaps. Sized to the tallest line (the 16 pt byte count).
        static let heroMinHeight: CGFloat = 24
    }

    /// Old text blurs and drifts up while fading out; new text sharpens in from
    /// below. The blur masks the crossover so the swap reads as one soft morph.
    private static let heroTransition: AnyTransition = .asymmetric(
        insertion: .blurFade(offsetY: 5),
        removal: .blurFade(offsetY: -5)
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusRegion
                .padding(.horizontal, MenuLayout.contentHorizontalInset)
                .padding(.top, 10)
                .padding(.bottom, 6)

            menuDivider

            menuActionRows
        }
        .frame(width: Metrics.panelWidth, alignment: .leading)
        .padding(.vertical, 6)
        .background(MenuOpenDetector(
            onOpen: { model.menuDidOpen() },
            onWindow: { model.panelWindow = $0 },
            onVisibilityChange: { panelIsVisible = $0 }
        ))
        .task { model.attach(store: store) }
    }

    // MARK: Status region (hero)

    /// A `ZStack` so outgoing and incoming states overlap while cross-fading,
    /// with a constant minimum height so the rows below stay put.
    private var statusRegion: some View {
        ZStack(alignment: .leading) {
            switch model.state {
            case .checking:
                CheckingStatusLine(isPanelVisible: panelIsVisible)
                    .opacity(MenuLayout.mutedStatusOpacity)
                    .transition(Self.heroTransition)

            case .clear(let lastScanned):
                HStack(spacing: 8) {
                    Text("You're all clear")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer(minLength: 0)
                    scannedAgoLabel(for: lastScanned)
                }
                .opacity(MenuLayout.mutedStatusOpacity)
                .transition(Self.heroTransition)

            case .ready(let bytes, let lastScanned):
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        Text(menuBytes(bytes))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        Text(" to clean")
                            .font(.system(size: 13))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    Spacer(minLength: 0)
                    scannedAgoLabel(for: lastScanned)
                }
                .transition(Self.heroTransition)

            case .cleaning(let cleaned, let total):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleaning…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    MenuStorageBar(
                        fraction: total > 0 ? Double(cleaned) / Double(total) : 0,
                        tint: MenuPalette.accent
                    )
                    Text("Moved \(menuBytes(cleaned)) of \(menuBytes(total)) to trash")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textSecondary)
                }
                .transition(Self.heroTransition)

            case .cleaned(let bytes):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(MenuPalette.success)
                    Text("Cleaned \(menuBytes(bytes))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer(minLength: 0)
                }
                .opacity(MenuLayout.mutedStatusOpacity)
                .transition(Self.heroTransition)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.heroMinHeight, alignment: .leading)
    }

    // MARK: Actions

    private var menuActionRows: some View {
        VStack(spacing: 0) {
            MenuTextRow(title: "Clean Safe Files", isEnabled: canClean) {
                model.clean()
            }
            MenuTextRow(title: "Scan now", isEnabled: canScan) {
                model.scanNow()
            }
            MenuTextRow(title: "Open Purge") {
                openPurge()
            }
            MenuTextRow(title: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var canClean: Bool {
        if case .ready = model.state { return true }
        return false
    }

    private var canScan: Bool {
        switch model.state {
        case .checking, .cleaning: return false
        default: return true
        }
    }

    private var menuDivider: some View {
        Divider()
            .opacity(0.5)
            .padding(.horizontal, Metrics.dividerInset)
            .padding(.vertical, 4)
    }

    // MARK: Formatting

    private func openPurge() {
        NSApp.activate(ignoringOtherApps: true)
        // Skip the status-bar window; target the app's real window.
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private func menuBytes(_ bytes: Int64) -> String {
        formatBytes(bytes)
    }

    private func scannedAgoLabel(for date: Date) -> some View {
        ScannedAgoLabel(date: date, isPanelVisible: panelIsVisible)
    }
}

// MARK: - Scanned-ago label

/// Live relative timestamp: "just now" for the first few seconds, then tens of
/// seconds, then minutes/hours/days. Ticks on a common-modes timer so it keeps
/// updating through any tracking run loop, but only while the panel is on
/// screen — the hidden panel hierarchy persists between opens, and an always-on
/// timer there would wake the app once a second forever.
private struct ScannedAgoLabel: View {
    let date: Date
    let isPanelVisible: Bool

    @State private var now = Date()
    @State private var ticker: Timer?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
            Text(Self.agoCompact(from: date, to: now))
                .font(.system(size: 12))
        }
        .foregroundStyle(AppColors.textSecondary)
        .onAppear { setTicking(isPanelVisible) }
        .onDisappear { setTicking(false) }
        .onChange(of: isPanelVisible) { setTicking($0) }
    }

    private func setTicking(_ active: Bool) {
        ticker?.invalidate()
        ticker = nil
        guard active else { return }
        // Snap to the current time immediately: `now` went stale while hidden.
        now = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            now = Date()
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    static func agoCompact(from date: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(Int(seconds / 10) * 10)s ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

// MARK: - Blur-fade transition

/// Blur + fade + small vertical drift, usable on the macOS 13 deployment floor
/// (`.blurReplace` needs macOS 15).
private struct BlurFadeModifier: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    let offsetY: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(opacity)
            .offset(y: offsetY)
    }
}

extension AnyTransition {
    fileprivate static func blurFade(offsetY: CGFloat) -> AnyTransition {
        .modifier(
            active: BlurFadeModifier(radius: 6, opacity: 0, offsetY: offsetY),
            identity: BlurFadeModifier(radius: 0, opacity: 1, offsetY: 0)
        )
    }
}

// MARK: - Checking status line

/// The scanning hero: a spinner plus a playful status word that cycles while
/// the scan runs, each swap drifting up with a fade. Driven by a common-modes
/// timer so the cycle survives any tracking run loop (e.g. app menus open
/// while the panel is visible). The cycle only runs while the panel is on
/// screen: a scan can outlive a closed panel, and the hidden hierarchy would
/// otherwise keep animating (and waking the app) with nobody watching.
private struct CheckingStatusLine: View {
    let isPanelVisible: Bool

    private static let words = [
        "Pondering…",
        "Rummaging…",
        "Snooping around…",
        "Dusting shelves…",
        "Sifting…",
        "Counting crumbs…",
        "Peeking in caches…",
        "Lifting the rug…",
    ]

    @State private var index = Int.random(in: 0 ..< CheckingStatusLine.words.count)
    @State private var cycleTimer: Timer?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            // ZStack so the outgoing and incoming words overlap while animating
            // instead of sitting side by side in the HStack.
            ZStack(alignment: .leading) {
                Text(Self.words[index])
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .id(index)
                    .transition(.asymmetric(
                        insertion: .blurFade(offsetY: 5),
                        removal: .blurFade(offsetY: -5)
                    ))
            }
            Spacer(minLength: 0)
        }
        .onAppear { setCycling(isPanelVisible) }
        .onDisappear { setCycling(false) }
        .onChange(of: isPanelVisible) { setCycling($0) }
    }

    private func setCycling(_ active: Bool) {
        cycleTimer?.invalidate()
        cycleTimer = nil
        guard active else { return }
        let animation = MenuViewModel.swapAnimation
        let timer = Timer(timeInterval: 1.6, repeats: true) { _ in
            withAnimation(animation) {
                index = (index + 1) % Self.words.count
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cycleTimer = timer
    }
}

// MARK: - Reusable rows

/// Thin, rounded storage fill bar — our element, reused for the menu.
private struct MenuStorageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

/// Interactive plain menu row with the native selection highlight. The text and
/// icon flip to white while highlighted, like a native menu item.
private struct MenuTextRow: View {
    let title: String
    var systemImage: String?
    var titleColor: Color = AppColors.textPrimary
    var titleWeight: Font.Weight = .regular
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 16)
                }
                Text(title)
                    .fontWeight(titleWeight)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(rowForeground)
            .padding(.horizontal, MenuLayout.rowContentInset)
            .padding(.vertical, 5)
            .frame(minHeight: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if hovering, isEnabled {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .selectedContentBackgroundColor))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MenuLayout.rowInset)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
    }

    private var rowForeground: Color {
        if !isEnabled { return AppColors.textSecondary.opacity(MenuLayout.disabledRowOpacity) }
        return hovering ? Color.white : titleColor
    }
}

// MARK: - Open detection

/// Bridges to AppKit to detect every time the menu panel becomes key/visible.
/// `onAppear` is unreliable for repeat opens of a reused `.window` panel on the
/// 13.0 deployment target, so we observe the panel window's key notification.
/// Also hands the panel window to the model, which uses its visibility to
/// decide whether a finished scan needs a notification instead, and reports
/// on-screen visibility (via occlusion state) so panel timers can stop while
/// the reused hierarchy sits hidden between opens.
private struct MenuOpenDetector: NSViewRepresentable {
    let onOpen: () -> Void
    let onWindow: (NSWindow?) -> Void
    let onVisibilityChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onOpen = onOpen
        view.onWindow = onWindow
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.onOpen = onOpen
        (nsView as? TrackingView)?.onWindow = onWindow
        (nsView as? TrackingView)?.onVisibilityChange = onVisibilityChange
    }

    final class TrackingView: NSView {
        var onOpen: (() -> Void)?
        var onWindow: ((NSWindow?) -> Void)?
        var onVisibilityChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var occlusionObserver: NSObjectProtocol?

        // Configure the panel *before* it finishes moving on-screen. On the very
        // first open SwiftUI orders the window front with its default slide/fade
        // right after installing content, so setting `animationBehavior` only in
        // `viewDidMoveToWindow` lands too late and the first open still animates.
        // `viewWillMove(toWindow:)` gives us the incoming window earlier.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let newWindow {
                configure(newWindow)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
                self.occlusionObserver = nil
            }
            onWindow?(window)
            guard let window else {
                onVisibilityChange?(false)
                return
            }
            configure(window)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onOpen?()
            }
            // Occlusion tracks real on-screen presence: it flips false when the
            // panel is ordered out on close, unlike key status, which also drops
            // while the panel merely loses focus.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                self?.onVisibilityChange?(window.occlusionState.contains(.visible))
            }
            onVisibilityChange?(window.occlusionState.contains(.visible))
            // Fire once for the initial presentation.
            onOpen?()
        }

        /// Snap the panel on/off like a native status-bar menu instead of the
        /// default window-style fade/scale. Idempotent; safe to call repeatedly.
        private func configure(_ window: NSWindow) {
            window.animationBehavior = .none
            // Safety net for the first presentation: if SwiftUI already kicked
            // off an appearance animation before we set `.none`, drop any
            // in-flight layer animations and snap to fully shown.
            window.alphaValue = 1
            window.contentView?.superview?.layer?.removeAllAnimations()
            window.contentView?.layer?.removeAllAnimations()
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
            }
        }
    }
}
