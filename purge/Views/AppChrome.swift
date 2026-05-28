import AppKit
import QuartzCore
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
    static let width: CGFloat = 220
    static let horizontalInset: CGFloat = 8
    static let navRowInnerPadding: CGFloat = 8
    static let selectionCornerRadius: CGFloat = 8
    /// Clears unified title-bar traffic lights with a little breathing room below.
    static let topContentInset: CGFloat = 42
}

/// Shared horizontal inset for Settings-style detail pages (App Caches, Dev Tools, Settings).
enum AppDetailPageLayout {
    static let horizontalInset: CGFloat = 24
    /// Space below the title bar before page content begins.
    static let topContentInset: CGFloat = 20
    static let verticalPadding: CGFloat = 12
    /// Clear band below a `safeAreaBar` page header before the scroll edge blur ramps up.
    static let scrollEdgeClearanceBelowHeader: CGFloat = 24
    /// Approximate height of `AppSectionPageHeader` (top inset + title + bottom padding).
    static let pageTitleChromeHeight: CGFloat = topContentInset + 28 + AppStyle.Spacing.small
    /// Extra line when a subtitle is shown (spacing + subheadline).
    static let pageSubtitleChromeHeight: CGFloat = 4 + 16

    static func pageHeaderChromeHeight(includesSubtitle: Bool) -> CGFloat {
        pageTitleChromeHeight + (includesSubtitle ? pageSubtitleChromeHeight : 0)
    }

    static func scrollEdgeInsetBelowPageHeader(includesSubtitle: Bool) -> CGFloat {
        pageHeaderChromeHeight(includesSubtitle: includesSubtitle) + scrollEdgeClearanceBelowHeader
    }
}

@available(macOS 26.0, *)
extension View {
    /// Sticky scan-tab chrome with a soft scroll edge blur as list rows pass underneath.
    func scanTabSoftScrollEdge<Chrome: View>(@ViewBuilder chrome: @escaping () -> Chrome) -> some View {
        safeAreaBar(edge: .top, spacing: 0, content: chrome)
            .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// About tab: an invisible page-header sized bar reserves space so cards blur as they pass
    /// underneath, while the visible animated title is owned by the persistent parent overlay.
    func aboutPageScrollEdge() -> some View {
        safeAreaBar(edge: .top, spacing: 0) {
            AppSectionPageHeader(title: "About")
                .opacity(0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

extension View {
    /// Keeps tab body content below a page header drawn in a parent `ZStack`.
    func underDetailPageHeader(includesSubtitle: Bool = false) -> some View {
        padding(.top, AppDetailPageLayout.pageHeaderChromeHeight(includesSubtitle: includesSubtitle))
    }
}

/// Page header matching Settings section typography (`.headline` + subtitle).
struct AppSectionPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppStyle.Spacing.medium) {
            VStack(alignment: .leading, spacing: 4) {
                AnimatedPageTitle(title)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AppStyle.Spacing.medium)

            trailing()
        }
        .padding(.horizontal, AppDetailPageLayout.horizontalInset)
        .padding(.top, AppDetailPageLayout.topContentInset)
        .padding(.bottom, AppStyle.Spacing.small)
    }
}

private struct AnimatedPageTitle: View {
    let title: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedTitle: String
    @State private var previousTitle: String?
    @State private var previousTitleVisible = false
    @State private var titleVisible = true
    @State private var animationToken = 0

    init(_ title: String) {
        self.title = title
        _displayedTitle = State(initialValue: title)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let previousTitle {
                Text(previousTitle)
                    .font(AppStyle.Typography.pageTitle)
                    .opacity(previousTitleVisible ? 1 : 0)
                    .offset(y: previousTitleVisible ? 0 : -5)
                    .blur(radius: previousTitleVisible ? 0 : 1.5)
            }

            Text(displayedTitle)
                .font(AppStyle.Typography.pageTitle)
                .opacity(titleVisible || reduceMotion ? 1 : 0)
                .offset(y: titleVisible || reduceMotion ? 0 : 6)
                .blur(radius: titleVisible || reduceMotion ? 0 : 0.8)
                .animation(titleAnimation, value: titleVisible)
                .id(animationToken)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .onChange(of: title) { newTitle in
            animateTitleChange(to: newTitle)
        }
    }

    private func animateTitleChange(to newTitle: String) {
        guard newTitle != displayedTitle else { return }

        if reduceMotion {
            displayedTitle = newTitle
            previousTitle = nil
            titleVisible = true
            return
        }

        previousTitle = displayedTitle
        previousTitleVisible = true

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            displayedTitle = newTitle
            animationToken += 1
            titleVisible = false
        }
        let currentToken = animationToken

        withAnimation(.easeOut(duration: 0.16)) {
            previousTitleVisible = false
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78, blendDuration: 0.04)) {
            titleVisible = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard animationToken == currentToken else { return }
            previousTitle = nil
        }
    }

    private var titleAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.28, dampingFraction: 0.8, blendDuration: 0.04)
    }
}

/// Scan and Clean Selected — top-trailing actions on App Caches / Dev Tools pages.
struct AppScanCleanActions: View {
    let onScan: () -> Void
    var scanPhase: PurgeStore.ScanPhase = .idle

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            AppScanButton(scanPhase: scanPhase, action: onScan)
            AppCleanSelectedButton()
        }
        .fixedSize()
    }
}

struct AppScanButton: View {
    let scanPhase: PurgeStore.ScanPhase
    let action: () -> Void

    private var isBusy: Bool {
        scanPhase == .scanning || scanPhase == .cancelling
    }

    private var title: String {
        switch scanPhase {
        case .cancelling:
            return "Cancelling..."
        case .scanning:
            return "Scanning..."
        case .idle, .completed:
            return "Scan"
        }
    }

    var body: some View {
        Button(action: action) {
            CleaningButtonLabel(
                title: title,
                systemImage: isBusy ? nil : "arrow.clockwise",
                isCleaning: isBusy
            )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(AppButtonStyle(variant: .bordered, isCapsule: true))
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(isBusy)
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

struct CleaningButtonLabel: View {
    let title: String
    let systemImage: String?
    var isCleaning: Bool = false
    var spinnerTint: Color = AppStyle.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if isCleaning {
                if reduceMotion {
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.62)
                        .frame(width: 13, height: 13)
                        .tint(spinnerTint)
                }
            } else if let systemImage {
                Image(systemName: systemImage)
            }

            Text(title)
        }
        .labelStyle(.titleAndIcon)
    }
}

struct SafeCleanupCelebrationOverlay: View {
    let freedBytes: Int64
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkmarkProgress: CGFloat = 0
    @State private var encouragement: CleanupCompletionEncouragement

    private let celebrationAccent = AppStyle.accent
    private let sheetBackground = Color(
        light: NSColor(calibratedWhite: 0.08, alpha: 1),
        dark: NSColor(calibratedWhite: 0.08, alpha: 1)
    )

    init(freedBytes: Int64, onDone: @escaping () -> Void) {
        self.freedBytes = freedBytes
        self.onDone = onDone
        _encouragement = State(initialValue: CleanupCompletionMessagePicker.randomMessage(for: freedBytes))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()

            if showsConfetti {
                CleanupCompletionConfettiBurst(color: celebrationAccent)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }

            VStack(spacing: AppStyle.Spacing.large) {
                Spacer(minLength: 0)

                CompletionCheckmarkBadge(progress: checkmarkProgress, color: celebrationAccent)
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)

                VStack(spacing: AppStyle.Spacing.small) {
                    Text("\(formatBytes(freedBytes)) freed")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    if let comparisonItems = OnboardingSizeComparison.items(for: freedBytes) {
                        OnboardingSizeComparisonLine(items: comparisonItems)
                            .foregroundStyle(.white.opacity(0.78))
                    }

                    Text(encouragement.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, AppStyle.Spacing.xSmall)
                }
                .frame(maxWidth: 560)

                Spacer(minLength: 0)

                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 11)
                        .background(celebrationAccent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 52)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(sheetBackground)
            .accessibilityElement(children: .contain)
        }
        .onAppear {
            if reduceMotion {
                checkmarkProgress = 1
            } else {
                withAnimation(.easeInOut(duration: 0.6)) {
                    checkmarkProgress = 1
                }
            }
            CleanupCompletionMessagePicker.storeLastShown(encouragement)
        }
        .environment(\.colorScheme, .dark)
    }

    private var showsConfetti: Bool {
        freedBytes >= CleanupCompletionMessagePicker.confettiThresholdBytes && !reduceMotion
    }
}

private struct CleanupCompletionEncouragement: Equatable {
    let key: String
    let text: String
}

private enum CleanupCompletionMessagePicker {
    static let confettiThresholdBytes: Int64 = 2 * oneGigabyte

    private static let oneMegabyte: Int64 = 1024 * 1024
    private static let oneGigabyte: Int64 = 1024 * 1024 * 1024
    private static let lastShownMessageKey = "cleanCompletion.lastShownMessageKey"

    static func randomMessage(
        for freedBytes: Int64,
        defaults: UserDefaults = .standard
    ) -> CleanupCompletionEncouragement {
        let messages = tier(for: freedBytes).messages
        guard messages.count > 1 else {
            return messages[0]
        }

        let lastShownKey = defaults.string(forKey: lastShownMessageKey)
        let eligibleMessages = messages.filter { $0.key != lastShownKey }

        return (eligibleMessages.isEmpty ? messages : eligibleMessages).randomElement() ?? messages[0]
    }

    static func storeLastShown(
        _ message: CleanupCompletionEncouragement,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(message.key, forKey: lastShownMessageKey)
    }

    private static func tier(for freedBytes: Int64) -> CleanupCompletionMessageTier {
        switch freedBytes {
        case ..<(500 * oneMegabyte):
            return .under500MB
        case ..<(2 * oneGigabyte):
            return .between500MBAnd2GB
        case ..<(10 * oneGigabyte):
            return .between2GBAnd10GB
        default:
            return .over10GB
        }
    }
}

private enum CleanupCompletionMessageTier: String {
    case under500MB
    case between500MBAnd2GB
    case between2GBAnd10GB
    case over10GB

    var messages: [CleanupCompletionEncouragement] {
        copy.enumerated().map { index, text in
            CleanupCompletionEncouragement(key: "\(rawValue).\(index)", text: text)
        }
    }

    private var copy: [String] {
        switch self {
        case .under500MB:
            return [
                "Every crumb counts. Your Mac approves.",
                "Small clean, big satisfaction.",
                "Your Mac just exhaled a little.",
                "Tidier than it was. That's enough.",
                "The digital equivalent of emptying your pockets.",
                "Baby steps. Your Mac feels it.",
                "Less junk. More you."
            ]
        case .between500MBAnd2GB:
            return [
                "Your Mac is breathing easier now.",
                "That's the stuff. Clean machine.",
                "Junk: gone. Vibes: immaculate.",
                "Your future self will thank you.",
                "Marie Kondo would be proud.",
                "That was satisfying and you know it.",
                "Your Mac just got a little faster and a lot happier."
            ]
        case .between2GBAnd10GB:
            return [
                "Now that's a clean. Well done.",
                "Your Mac remembers what it felt like to be young.",
                "Somewhere, a hard drive is smiling.",
                "You just gave your Mac room to breathe.",
                "That's not a clean. That's a transformation.",
                "Your Mac called. It says thank you.",
                "Digital spring cleaning. Chef's kiss."
            ]
        case .over10GB:
            return [
                "Absolute unit of a clean. Respect.",
                "Your Mac is basically new again.",
                "That's not cleaning. That's archaeology.",
                "Future you is living in a palace.",
                "Your Mac just did a happy dance.",
                "The junk was real. Now it's gone. You did that.",
                "If your Mac could hug you, it would."
            ]
        }
    }
}

private struct CleanupCompletionConfettiBurst: View {
    let color: Color

    @State private var isAnimating = false

    private let particles = CleanupCompletionConfettiParticle.all

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(particles) { particle in
                    particleView(for: particle)
                        .foregroundStyle(color.opacity(particle.opacity))
                        .scaleEffect(isAnimating ? particle.endScale : 0.6)
                        .opacity(isAnimating ? 0 : 1)
                        .position(
                            x: proxy.size.width / 2 + particle.xOffset,
                            y: proxy.size.height - 72 + (isAnimating ? particle.rise : 0)
                        )
                        .animation(
                            .easeOut(duration: 1.35).delay(particle.delay),
                            value: isAnimating
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            isAnimating = false
            DispatchQueue.main.async {
                isAnimating = true
            }
        }
    }

    @ViewBuilder
    private func particleView(for particle: CleanupCompletionConfettiParticle) -> some View {
        switch particle.kind {
        case .dot:
            Circle()
                .frame(width: particle.size, height: particle.size)
        case .sparkle:
            Image(systemName: "sparkle")
                .font(.system(size: particle.size, weight: .semibold))
        }
    }
}

private struct CleanupCompletionConfettiParticle: Identifiable {
    enum Kind {
        case dot
        case sparkle
    }

    let id: Int
    let kind: Kind
    let xOffset: CGFloat
    let rise: CGFloat
    let size: CGFloat
    let opacity: Double
    let endScale: CGFloat
    let delay: Double

    static let all: [CleanupCompletionConfettiParticle] = [
        .init(id: 0, kind: .dot, xOffset: -150, rise: -142, size: 6, opacity: 0.72, endScale: 1.2, delay: 0.00),
        .init(id: 1, kind: .sparkle, xOffset: -108, rise: -190, size: 12, opacity: 0.78, endScale: 0.9, delay: 0.06),
        .init(id: 2, kind: .dot, xOffset: -64, rise: -126, size: 5, opacity: 0.66, endScale: 1.1, delay: 0.12),
        .init(id: 3, kind: .dot, xOffset: -24, rise: -218, size: 7, opacity: 0.75, endScale: 1.0, delay: 0.02),
        .init(id: 4, kind: .sparkle, xOffset: 18, rise: -168, size: 10, opacity: 0.82, endScale: 0.95, delay: 0.10),
        .init(id: 5, kind: .dot, xOffset: 58, rise: -230, size: 5, opacity: 0.7, endScale: 1.15, delay: 0.16),
        .init(id: 6, kind: .dot, xOffset: 104, rise: -136, size: 6, opacity: 0.64, endScale: 1.2, delay: 0.04),
        .init(id: 7, kind: .sparkle, xOffset: 148, rise: -200, size: 11, opacity: 0.76, endScale: 0.9, delay: 0.14),
        .init(id: 8, kind: .dot, xOffset: 194, rise: -156, size: 4, opacity: 0.6, endScale: 1.1, delay: 0.08)
    ]
}

private struct CompletionCheckmarkBadge: View {
    let progress: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.92), lineWidth: 5)

            AnimatedCompletionCheckmark(progress: progress, color: color)
                .padding(22)
        }
    }
}

private struct AnimatedCompletionCheckmark: View {
    let progress: CGFloat
    let color: Color

    var body: some View {
        CompletionCheckmarkShape()
            .trim(from: 0, to: progress)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
            )
    }
}

private struct CompletionCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.56))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.78))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.26))
        return path
    }
}

struct SafeCleanupCelebrationBlurModifier: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static var safeCleanupCelebrationBlur: AnyTransition {
        .modifier(
            active: SafeCleanupCelebrationBlurModifier(radius: 18, opacity: 0),
            identity: SafeCleanupCelebrationBlurModifier(radius: 0, opacity: 1)
        )
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

enum AppSidebarAnimation {
    static let duration: TimeInterval = 0.28
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

private struct AnimatedSidebarCollapseConfigurator: NSViewRepresentable {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let reduceMotion: Bool

    func makeCoordinator() -> AnimatedSidebarCollapseCoordinator {
        AnimatedSidebarCollapseCoordinator()
    }

    func makeNSView(context: Context) -> ConfiguratorHostingView {
        let view = ConfiguratorHostingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ConfiguratorHostingView, context: Context) {
        context.coordinator.columnVisibility = $columnVisibility
        context.coordinator.reduceMotion = reduceMotion
        nsView.coordinator = context.coordinator
        nsView.configureSidebarCollapse()
    }

    final class ConfiguratorHostingView: NSView {
        weak var coordinator: AnimatedSidebarCollapseCoordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureSidebarCollapse()
        }

        func configureSidebarCollapse() {
            guard let window else { return }
            coordinator?.configure(in: window)
        }
    }
}

private final class AnimatedSidebarCollapseCoordinator: NSResponder {
    var columnVisibility: Binding<NavigationSplitViewVisibility>?
    var reduceMotion = false

    private weak var splitViewController: NSSplitViewController?
    private var isTogglingSidebar = false

    func configure(in window: NSWindow) {
        guard let splitView = window.contentView?.firstDescendant(where: { $0 is NSSplitView }) as? NSSplitView,
              let controller = splitView.delegate as? NSSplitViewController else {
            return
        }

        splitViewController = controller
        configureSidebarItem(in: controller)
        installResponder(before: splitView)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        guard let sidebarItem else {
            _ = nextResponder?.tryToPerform(#selector(toggleSidebar(_:)), with: sender)
            return
        }
        guard !isTogglingSidebar else { return }

        let shouldCollapse = !sidebarItem.isCollapsed
        setSidebarCollapsed(shouldCollapse)
    }

    private var sidebarItem: NSSplitViewItem? {
        splitViewController?.splitViewItems.first
    }

    private func configureSidebarItem(in controller: NSSplitViewController) {
        guard let item = controller.splitViewItems.first else { return }

        item.canCollapse = true
        item.canCollapseFromWindowResize = false
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.minimumThickness = SidebarLayout.width
        item.maximumThickness = SidebarLayout.width
    }

    private func installResponder(before splitView: NSSplitView) {
        guard splitView.nextResponder !== self else { return }

        nextResponder = splitView.nextResponder
        splitView.nextResponder = self
    }

    private func syncColumnVisibility(_ visibility: NavigationSplitViewVisibility) {
        guard columnVisibility?.wrappedValue != visibility else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            columnVisibility?.wrappedValue = visibility
        }
    }

    private func setSidebarCollapsed(_ isCollapsed: Bool) {
        let targetVisibility: NavigationSplitViewVisibility = isCollapsed ? .detailOnly : .all
        guard let sidebarItem else {
            syncColumnVisibility(targetVisibility)
            return
        }
        guard sidebarItem.isCollapsed != isCollapsed else {
            syncColumnVisibility(targetVisibility)
            return
        }

        if reduceMotion {
            sidebarItem.isCollapsed = isCollapsed
            splitViewController?.splitView.layoutSubtreeIfNeeded()
            syncColumnVisibility(targetVisibility)
            return
        }

        isTogglingSidebar = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AppSidebarAnimation.duration
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            sidebarItem.animator().isCollapsed = isCollapsed
            splitViewController?.splitView.animator().layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            self?.syncColumnVisibility(targetVisibility)
            self?.splitViewController?.splitView.layoutSubtreeIfNeeded()
            self?.isTogglingSidebar = false
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

    func animatedSidebarCollapse(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        reduceMotion: Bool
    ) -> some View {
        background(
            AnimatedSidebarCollapseConfigurator(
                columnVisibility: columnVisibility,
                reduceMotion: reduceMotion
            )
        )
    }

    func detailColumnCompactTop() -> some View {
        modifier(DetailColumnCompactTopModifier())
    }

    func sidebarCompactTop() -> some View {
        modifier(SidebarCompactTopModifier())
    }
}

