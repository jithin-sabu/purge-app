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
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.xs, style: .continuous))

            Text("Purge")
                .font(AppStyle.Typography.sectionTitle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Purge")
    }
}

/// Sidebar column insets — brand mark and nav selection share the same leading edge.
enum SidebarLayout {
    static let width: CGFloat = 240
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
    /// Remaining clear band below a `safeAreaBar` page header before content begins.
    /// `AppSectionPageHeader` already pads `Spacing.small` under the title, so this tops
    /// that up to `topContentInset` — the gap under the title then matches the one above
    /// it and the band reads centered on the title. On macOS 26 it lives inside the bar
    /// (see `detailPageScrollEdge`) so the scroll edge effect spans it; older systems pad
    /// it onto the scroll content instead.
    static let clearanceBelowHeader: CGFloat = topContentInset - AppStyle.Spacing.small
    /// Clear band under the Select All row so the first card sits a small gap below it.
    static let scanTabSelectAllBottomPadding: CGFloat = 14
    /// Approximate height of `AppSectionPageHeader` (top inset + title + bottom padding).
    static let pageTitleChromeHeight: CGFloat = topContentInset + 24 + AppStyle.Spacing.small
    /// Extra line when a subtitle is shown (spacing + subheadline).
    static let pageSubtitleChromeHeight: CGFloat = 4 + 16

    static func pageHeaderChromeHeight(includesSubtitle: Bool) -> CGFloat {
        pageTitleChromeHeight + (includesSubtitle ? pageSubtitleChromeHeight : 0)
    }
}

@available(macOS 26.0, *)
extension View {
    /// A page-header sized bar reserves the band the title occupies (the visible animated
    /// title is owned by the persistent parent overlay, so this copy is invisible) and
    /// carries the clearance below it. Its translucent surface is tied to scroll position:
    /// absent at the top so the band is flush with the page background, fading in as
    /// content starts passing underneath. The system scroll edge effect doesn't render on
    /// these pages (the detail column pulls its content up under the hidden title bar), so
    /// the material is driven here instead.
    func detailPageScrollEdge(title: String, includesSubtitle: Bool = false) -> some View {
        modifier(DetailPageScrollEdgeModifier(title: title, includesSubtitle: includesSubtitle))
    }
}

@available(macOS 26.0, *)
private struct DetailPageScrollEdgeModifier: ViewModifier {
    let title: String
    /// Reserves the subtitle line too, for pages whose visible header shows one.
    var includesSubtitle = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 at rest, 1 once content has scrolled far enough to need a surface behind the title.
    @State private var surfaceProgress: CGFloat = 0

    /// Short ramp: the surface should be there as soon as anything slides under the title.
    private static let rampDistance: CGFloat = 12
    /// Even fully ramped the glass stays partial — enough to separate the title from the
    /// rows behind it without settling into a panel.
    private static let maxSurfaceOpacity: CGFloat = 0.55

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                let target = min(1, max(0, offset / Self.rampDistance))
                guard abs(target - surfaceProgress) > 0.01 else { return }
                if reduceMotion {
                    surfaceProgress = target
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { surfaceProgress = target }
                }
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                AppSectionPageHeader(title: title, subtitle: includesSubtitle ? " " : nil)
                    .padding(.bottom, AppDetailPageLayout.clearanceBelowHeader)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity)
                    .background {
                        // Ultra thin, not regular: the band should read as blurred glass with
                        // the rows still legible through it, not as an opaque panel.
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(surfaceProgress * Self.maxSurfaceOpacity)
                    }
            }
            .scrollEdgeEffectHidden(true, for: .top)
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
                        .font(AppStyle.Typography.metadata)
                        .foregroundStyle(AppColors.textSecondary)
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

extension View {
    /// Shared inset for the Select All row on scan tabs.
    func scanTabSelectAllRowLayout() -> some View {
        padding(.horizontal, AppDetailPageLayout.horizontalInset)
            .padding(.top, AppStyle.Spacing.xSmall)
            .padding(.bottom, AppDetailPageLayout.scanTabSelectAllBottomPadding)
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
                Text(LocalizedStringKey(previousTitle))
                    .font(AppStyle.Typography.pageTitle)
                    .opacity(previousTitleVisible ? 1 : 0)
                    .offset(y: previousTitleVisible ? 0 : -5)
                    .blur(radius: previousTitleVisible ? 0 : 1.5)
            }

            Text(LocalizedStringKey(displayedTitle))
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

enum ScanQueueLabels {
    /// A scan button whose scan is waiting behind another one.
    static let queued = String(localized: "Up next...")
}

/// Scan and Clean Selected — top-trailing actions on App Caches / Dev Tools pages.
struct AppScanCleanActions: View {
    let onScan: () -> Void
    var scanPhase: PurgeStore.ScanPhase = .idle
    var isQueued = false

    var body: some View {
        HStack(spacing: AppStyle.Spacing.xSmall) {
            AppScanButton(scanPhase: scanPhase, isQueued: isQueued, action: onScan)
            AppCleanSelectedButton()
        }
        .fixedSize()
    }
}

struct AppScanButton: View {
    let scanPhase: PurgeStore.ScanPhase
    /// Waiting its turn behind another scan in the queue.
    var isQueued = false
    let action: () -> Void

    private var isBusy: Bool {
        isQueued || scanPhase == .scanning || scanPhase == .cancelling
    }

    private var title: String {
        if isQueued { return ScanQueueLabels.queued }
        switch scanPhase {
        case .cancelling:
            return String(localized: "Cancelling...")
        case .scanning:
            return String(localized: "Scanning...")
        case .idle, .completed:
            return String(localized: "Scan")
        }
    }

    var body: some View {
        Button(action: action) {
            CleaningButtonLabel(
                title: title,
                systemImage: isBusy ? nil : "arrow.clockwise",
                isCleaning: isBusy
            )
        }
        .buttonStyle(.purge(.secondary))
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(isBusy)
    }
}

struct AppCleanSelectedButton: View {
    @EnvironmentObject private var store: PurgeStore

    var body: some View {
        // Scan-tab selection lives in its own object; scope observes it so the
        // count/label and enabled state update when a scan-tab selection changes.
        ScanSelectionScope(selection: store.scanSelection, isSelected: { _ in false }) { _ in
            Button {
                store.showDeletionSheet = true
            } label: {
                AnimatedDeleteActionLabel(
                    inactiveTitle: String(localized: "Clean Selected"),
                    activeTitle: String(localized: "Clean Selected"),
                    selectedCount: store.selectedCount,
                    selectedBytes: store.selectedTotalBytes
                )
            }
            .buttonStyle(.purge(.primary))
            .disabled(store.selectedCount == 0 || store.isDeleting)
        }
    }
}

struct CleaningButtonLabel: View {
    let title: String
    let systemImage: String?
    var isCleaning: Bool = false

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
                }
            } else if let systemImage {
                Image(systemName: systemImage)
            }

            Text(LocalizedStringKey(title))
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: title)
        }
        .labelStyle(.titleAndIcon)
    }
}

struct AnimatedDeleteActionLabel: View {
    let inactiveTitle: String
    let activeTitle: String
    let selectedCount: Int
    /// When nil, the active label shows no byte suffix (e.g. Uninstall, where the
    /// review sheet owns the exact total).
    var selectedBytes: Int64? = nil
    var systemImage = "trash.fill"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measuredTextWidth: CGFloat?

    private var hasSelection: Bool {
        selectedCount > 0
    }

    private var widthAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.92, blendDuration: 0.12)
    }

    private var textAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.5)
    }

    private var accessibilityTitle: String {
        guard hasSelection else { return inactiveTitle }
        if let selectedBytes {
            return String(localized: "\(activeTitle), \(formatBytes(selectedBytes)) selected")
        }
        return String(localized: "\(activeTitle), \(selectedCount) selected")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)

            ZStack(alignment: .leading) {
                textContent
                    .fixedSize(horizontal: true, vertical: false)

                textContent
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(AnimatedDeleteActionWidthReader())
                    .accessibilityHidden(true)
            }
            .frame(width: measuredTextWidth, alignment: .leading)
            .clipped()
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .onPreferenceChange(AnimatedDeleteActionWidthKey.self) { width in
            guard width > 0 else { return }
            if reduceMotion {
                measuredTextWidth = width
            } else {
                withAnimation(widthAnimation) {
                    measuredTextWidth = width
                }
            }
        }
    }

    private var textContent: some View {
        HStack(spacing: 0) {
            Text(LocalizedStringKey(hasSelection ? activeTitle : inactiveTitle))
                .contentTransition(reduceMotion ? .identity : .opacity)

            if hasSelection, selectedBytes != nil {
                selectionSuffix
                    .transition(suffixTransition)
            }
        }
        .animation(widthAnimation, value: hasSelection)
        .animation(textAnimation, value: selectedBytes)
    }

    @ViewBuilder
    private var selectionSuffix: some View {
        if let selectedBytes {
            HStack(spacing: 0) {
                Text(" (")
                Text(formatBytes(selectedBytes))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text(")")
            }
        }
    }

    /// The suffix enters by being revealed as the label grows (an opacity fade
    /// reads cleanly there). On exit the label shrinks, which would otherwise
    /// drag the fading suffix leftward over the title — so removal moves it out
    /// toward the trailing edge instead, mirroring the way it came in.
    private var suffixTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity,
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }
}

private struct AnimatedDeleteActionWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AnimatedDeleteActionWidthReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: AnimatedDeleteActionWidthKey.self, value: proxy.size.width)
        }
    }
}

/// Single home for both deletion phases: presented in `.cleaning` when the user
/// confirms deletion, it flips to `.complete` in place when the engine finishes.
/// Sessions created already-`.complete` (safe cleanup, onboarding) render the
/// completion layout immediately, exactly as before.
struct SafeCleanupCelebrationOverlay: View {
    @ObservedObject var session: DeletionSession
    /// Onboarding says "Continue" when another step follows.
    var doneTitle = "Done"
    /// Onboarding passes `false`: that screen is still part of setup.
    var allowsSupportNudge = true
    let onDone: () -> Void

    @EnvironmentObject private var store: PurgeStore
    @ObservedObject private var helperPrefs = PrivilegedHelperPreferenceStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkmarkProgress: CGFloat = 0
    @State private var checkmarkScale: CGFloat
    @State private var checkmarkVisible: Bool
    @State private var subtitleShowsComplete: Bool
    @State private var completionLinesVisible: Bool
    @State private var footerVisible: Bool
    @State private var progressGroupVisible: Bool
    @State private var confettiArmed: Bool
    @State private var displayedBytes: Int64
    @State private var displayedFraction: Double
    @State private var tagline: TimeTagline.Selection?
    @State private var appearedAt = Date()
    @State private var didBeginCompletion = false
    @State private var sequenceTask: Task<Void, Never>?
    @State private var failuresExpanded = false
    @State private var retryingFailureIDs: Set<UUID> = []
    @State private var boltFlashToken = 0
    /// Set once per screen when the lifetime total reached a new milestone.
    @State private var supportMilestoneBytes: Int64?
    /// The quiet line under Done, for big cleans between milestones.
    @State private var supportFooterLine: SupportNudge.Line?
    @State private var supportLinkOpened = false

    private static let confettiThresholdBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let minimumCleaningDwell: TimeInterval = 1.2

    private let celebrationAccent = AppColors.textPrimary
    /// Follows the app's appearance, like the window behind it.
    private let sheetBackground = AppColors.surfaceBase

    init(
        session: DeletionSession,
        doneTitle: String = "Done",
        allowsSupportNudge: Bool = true,
        onDone: @escaping () -> Void
    ) {
        self.session = session
        self.doneTitle = doneTitle
        self.allowsSupportNudge = allowsSupportNudge
        self.onDone = onDone
        // Sessions created already-complete mount straight into the final layout;
        // live runs mount in the cleaning phase even if the engine has since finished
        // (the completion sequence then runs from onAppear, honoring the dwell).
        let mountsComplete = session.phase == .complete && !session.isLiveRun
        _checkmarkScale = State(initialValue: mountsComplete ? 1 : 0.85)
        _checkmarkVisible = State(initialValue: mountsComplete)
        _subtitleShowsComplete = State(initialValue: mountsComplete)
        _completionLinesVisible = State(initialValue: mountsComplete)
        _footerVisible = State(initialValue: mountsComplete)
        _progressGroupVisible = State(initialValue: !mountsComplete)
        _confettiArmed = State(initialValue: mountsComplete)
        _displayedBytes = State(initialValue: mountsComplete ? session.finalBytesMovedToTrash : 0)
        _displayedFraction = State(initialValue: mountsComplete ? 1 : 0)
        _tagline = State(initialValue: mountsComplete ? TimeTagline.select(for: session.elapsedSeconds) : nil)
        _boltFlashToken = State(
            initialValue: mountsComplete && session.elapsedSeconds < 3 ? 1 : 0
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppColors.scrim
                .ignoresSafeArea()

            if showsConfetti {
                CleanupCompletionConfettiBurst(color: celebrationAccent)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }

            VStack(spacing: AppStyle.Spacing.large) {
                Spacer(minLength: 0)

                if hidesSuccessChrome {
                    // Nothing moved: the panel is the whole story, centered on its own.
                    administratorPanel
                        .frame(maxWidth: 460)
                } else {
                    CompletionCheckmarkBadge(progress: checkmarkProgress, color: celebrationAccent)
                        .frame(width: 88, height: 88)
                        .scaleEffect(checkmarkScale)
                        .opacity(checkmarkVisible ? 1 : 0)
                        .accessibilityHidden(true)

                    VStack(spacing: AppStyle.Spacing.small) {
                        Text(formatBytes(displayedBytes))
                            .font(AppStyle.Typography.display)
                            .foregroundStyle(AppColors.textPrimary)
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)

                        Text(subtitleText)
                            .font(AppStyle.Typography.sectionTitle)
                            .foregroundStyle(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)

                        // The cleaning-phase progress group draws into the slot the
                        // completion lines occupy (always laid out, opacity-toggled),
                        // so neither phase ever shifts the other's elements.
                        ZStack(alignment: .top) {
                            VStack(spacing: AppStyle.Spacing.small) {
                                if let comparisonItems = OnboardingSizeComparison.items(for: comparisonBytes) {
                                    OnboardingSizeComparisonLine(items: comparisonItems)
                                        .foregroundStyle(AppColors.textSecondary)
                                }

                                if tagline != nil {
                                    CompletionTimeTagline(
                                        elapsedSeconds: session.elapsedSeconds,
                                        boltFlashToken: boltFlashToken
                                    )
                                    .padding(.top, AppStyle.Spacing.xSmall)
                                }
                            }
                            .opacity(completionLinesVisible ? 1 : 0)

                            progressGroup
                                .frame(height: 0, alignment: .top)
                                .opacity(progressGroupVisible ? 1 : 0)
                        }
                    }
                    .frame(maxWidth: 560)
                }

                Spacer(minLength: 0)

                VStack(spacing: AppStyle.Spacing.small) {
                    // When the header is hidden the panel already stands above; only
                    // show it here (beneath the success number) when the header stayed.
                    if session.phase == .complete, !administratorFailures.isEmpty, !hidesSuccessChrome {
                        administratorPanel
                    }

                    if session.phase == .complete, !otherFailures.isEmpty {
                        CleanFailureDisclosure(
                            failures: otherFailures,
                            isExpanded: $failuresExpanded,
                            retryingIDs: retryingFailureIDs,
                            onOpenSettings: openFullDiskAccessSettings,
                            onRetry: retryFailure
                        )
                    }

                    if session.phase == .complete, let supportMilestoneBytes {
                        SupportNudgeCard(
                            milestoneBytes: supportMilestoneBytes,
                            linkOpened: supportLinkOpened,
                            onOpenLink: openSupportLink
                        )
                        .padding(.bottom, AppStyle.Spacing.xSmall)
                        .transition(.opacity)
                    }

                    if reservesTrashDisclaimerSpace {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                            Text("Empty your Trash to reclaim this space.")
                        }
                        .font(AppStyle.Typography.body.weight(.medium))
                        .foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                    }

                    // The helper moved a protected app but could not hand every file
                    // back, so say so plainly rather than implying a spotless Trash.
                    if session.phase == .complete, session.trashOwnershipWarning {
                        HStack(spacing: 5) {
                            Image(systemName: "key")
                            Text("Emptying the Trash may ask for your password.")
                        }
                        .font(AppStyle.Typography.body.weight(.medium))
                        .foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                    }

                    Button(doneTitle, action: onDone)
                        .buttonStyle(.purge(.primary, size: .large, width: .fixed(300)))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!footerVisible)

                    if session.phase == .complete, let supportFooterLine {
                        SupportFooterLink(
                            line: supportFooterLine,
                            linkOpened: supportLinkOpened,
                            onOpenLink: openSupportLink
                        )
                            .padding(.top, AppStyle.Spacing.xxSmall)
                            .transition(.opacity)
                    }
                }
                .opacity(footerVisible ? 1 : 0)
            }
            .padding(.horizontal, 52)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(sheetBackground)
            .accessibilityElement(children: .contain)
        }
        .onAppear {
            handleAppear()
            helperPrefs.refresh()
        }
        // Keep a foreground refresh as a fallback if approval took longer than the
        // short background monitor or the app was reopened later.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            helperPrefs.refresh()
        }
        // Approval happens outside Purge. The preference store watches for macOS to
        // enable the helper; when it does, finish the uninstall the user already
        // confirmed instead of making them press a second removal button.
        .onChange(of: helperPrefs.isEnabled) { isEnabled in
            guard isEnabled else { return }
            retryAdministratorFailures()
        }
        .onChange(of: session.phase) { phase in
            guard phase == .complete else { return }
            beginCompletionSequence()
        }
        .onChange(of: session.bytesMovedToTrash) { newValue in
            mirrorLiveProgress(bytesMovedToTrash: newValue)
        }
        .onDisappear { sequenceTask?.cancel() }
    }

    private var progressGroup: some View {
        VStack(spacing: AppStyle.Spacing.xSmall) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(AppColors.fillSecondaryPressed)
                    Capsule(style: .continuous)
                        .fill(celebrationAccent)
                        .frame(width: max(0, min(1, displayedFraction)) * geo.size.width)
                }
            }
            .frame(height: 4)

            Text(currentItemText)
                .font(AppStyle.Typography.body.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cleaning, \(formatBytes(displayedBytes)) of \(formatBytes(session.totalBytes))")
    }

    /// The completion line states what happened and what has not happened yet. The
    /// files are in the trash and still on the volume; nothing is reclaimed until the
    /// trash is emptied, so this must never read as an achievement.
    private var subtitleText: String {
        subtitleShowsComplete ? String(localized: "moved to trash, not yet reclaimed") : String(localized: "of \(formatBytes(session.totalBytes))")
    }

    private var currentItemText: String {
        session.currentItemName.map { String(localized: "Cleaning \($0)…") } ?? String(localized: "Cleaning…")
    }

    private func retryFailure(_ item: CleanFailureItem) {
        guard !retryingFailureIDs.contains(item.id) else { return }
        retryingFailureIDs.insert(item.id)
        Task {
            let movedBytes = await store.retryCleanFailure(item, session: session)
            retryingFailureIDs.remove(item.id)
            guard let movedBytes else { return }
            if reduceMotion {
                displayedBytes += movedBytes
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    displayedBytes += movedBytes
                }
            }
        }
    }

    /// Locked-app failures get the reassuring setup panel; everything else keeps the
    /// terse disclosure. Split so a run that hits both still shows each correctly.
    private var administratorFailures: [CleanFailureItem] {
        session.failedItems.filter { $0.reason == .needsAdministrator }
    }

    private var otherFailures: [CleanFailureItem] {
        session.failedItems.filter { $0.reason != .needsAdministrator }
    }

    /// One button for both jobs: set the helper up the first time, or manually retry
    /// if automatic continuation did not finish. Re-read the live status first so a
    /// tap after approval removes the app instead of reopening System Settings.
    private func handleAdministratorAction() {
        helperPrefs.refresh()
        if helperPrefs.isEnabled {
            retryAdministratorFailures()
        } else {
            helperPrefs.setEnabled(true)
        }
    }

    private func retryAdministratorFailures() {
        for item in administratorFailures { retryFailure(item) }
    }

    private func revealAdministratorItemInFinder() {
        guard let first = administratorFailures.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first.path)])
    }

    /// When the only outcome is a locked app and nothing actually moved, the success
    /// header (checkmark, "0 bytes", timing) is just noise around a "0". Drop it and
    /// let the permission panel stand on its own. As soon as something did move, the
    /// header earns its place again and the panel sits beneath it.
    private var hidesSuccessChrome: Bool {
        session.phase == .complete
            && !administratorFailures.isEmpty
            && session.movedToTrashCount == 0
            && session.finalBytesMovedToTrash == 0
    }

    private var administratorPanel: some View {
        NeedsAdministratorPanel(
            items: administratorFailures,
            isHelperEnabled: helperPrefs.isEnabled,
            needsApproval: helperPrefs.needsApproval,
            isWorking: !retryingFailureIDs.isDisjoint(with: Set(administratorFailures.map(\.id))),
            onPrimaryAction: handleAdministratorAction,
            onRevealInFinder: revealAdministratorItemInFinder
        )
    }

    /// Shown in the complete phase only when something actually went to Trash.
    /// During cleaning the (invisible) footer reserves its space so nothing shifts.
    private var reservesTrashDisclaimerSpace: Bool {
        session.phase == .cleaning || session.movedToTrashCount > 0
    }

    /// Reserves comparison-line space from the selected total during cleaning;
    /// switches to the exact engine result at completion.
    private var comparisonBytes: Int64 {
        session.phase == .complete ? session.finalBytesMovedToTrash : session.totalBytes
    }

    private var showsConfetti: Bool {
        // Don't celebrate when something still needs the user's attention.
        confettiArmed
            && administratorFailures.isEmpty
            && session.finalBytesMovedToTrash >= Self.confettiThresholdBytes
            && !reduceMotion
    }

    private func handleAppear() {
        appearedAt = Date()
        guard session.phase == .complete else { return }
        if session.isLiveRun {
            // Engine finished before the view mounted (tiny cleans): run the
            // full cleaning -> complete choreography, dwell included.
            beginCompletionSequence()
            return
        }
        if reduceMotion {
            checkmarkProgress = 1
        } else {
            withAnimation(.easeInOut(duration: 0.6)) {
                checkmarkProgress = 1
            }
        }
        if let tagline {
            TimeTagline.store(tagline)
        }
        resolveSupportNudge()
    }

    /// Runs once the run is complete and the store has added it to the lifetime
    /// total. A milestone gets the card; a big clean between milestones may get the
    /// quiet line under Done (see `SupportNudge.showsFooterLink`), never both. Any failure keeps both away: that screen has
    /// other work to do.
    private func resolveSupportNudge() {
        guard allowsSupportNudge, supportMilestoneBytes == nil, supportFooterLine == nil,
              session.failedItems.isEmpty else { return }
        if let milestone = SupportNudge.milestone(
            lifetimeBytes: store.totalMovedToTrashBytes,
            cleanBytes: session.finalBytesMovedToTrash
        ) {
            SupportNudge.recordShown(milestoneBytes: milestone)
            supportMilestoneBytes = milestone
        } else if SupportNudge.showsFooterLink(cleanBytes: session.finalBytesMovedToTrash) {
            supportFooterLine = SupportNudge.selectLine(for: SupportNudge.CleanFacts(
                bytes: session.finalBytesMovedToTrash,
                itemCount: session.movedToTrashCount,
                lifetimeBytes: store.totalMovedToTrashBytes
            ))
        }
    }

    private func openSupportLink() {
        SupportNudge.recordLinkOpened()
        NSWorkspace.shared.open(SupportNudge.url)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            supportLinkOpened = true
        }
    }

    private func mirrorLiveProgress(bytesMovedToTrash: Int64) {
        guard session.phase == .cleaning, !didBeginCompletion else { return }
        let fraction = session.totalBytes > 0
            ? min(1.0, Double(bytesMovedToTrash) / Double(session.totalBytes))
            : 0
        if reduceMotion {
            displayedBytes = bytesMovedToTrash
            displayedFraction = fraction
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                displayedBytes = bytesMovedToTrash
                displayedFraction = fraction
            }
        }
    }

    private func beginCompletionSequence() {
        guard !didBeginCompletion else { return }
        didBeginCompletion = true

        sequenceTask = Task { @MainActor in
            let finalBytes = session.finalBytesMovedToTrash
            tagline = TimeTagline.select(for: session.elapsedSeconds)
            if let tagline {
                TimeTagline.store(tagline)
            }

            if reduceMotion {
                displayedBytes = finalBytes
                displayedFraction = 1
                checkmarkProgress = 1
                checkmarkScale = 1
                confettiArmed = true
                resolveSupportNudge()
                withAnimation(.easeInOut(duration: 0.35)) {
                    progressGroupVisible = false
                    subtitleShowsComplete = true
                    checkmarkVisible = true
                    completionLinesVisible = true
                    footerVisible = true
                }
                if session.elapsedSeconds < 3 {
                    boltFlashToken += 1
                }
                return
            }

            // Minimum dwell: a KB-scale clean settles the counter and bar over
            // the remaining time so it reads as a moment, not a flash.
            let sinceAppear = Date().timeIntervalSince(appearedAt)
            let settleDuration = sinceAppear < Self.minimumCleaningDwell
                ? Self.minimumCleaningDwell - sinceAppear
                : 0.25
            withAnimation(.easeOut(duration: settleDuration)) {
                displayedBytes = finalBytes
                displayedFraction = 1
            }
            try? await Task.sleep(nanoseconds: UInt64(settleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.3)) {
                progressGroupVisible = false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(.easeInOut(duration: 0.3)) {
                subtitleShowsComplete = true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            confettiArmed = true
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                checkmarkVisible = true
                checkmarkScale = 1
            }
            withAnimation(.easeInOut(duration: 0.6)) {
                checkmarkProgress = 1
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeInOut(duration: 0.3)) {
                completionLinesVisible = true
            }
            if session.elapsedSeconds < 3 {
                boltFlashToken += 1
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            // Inserted with the footer so the header glides up once, instead of
            // jumping while the counter is still settling.
            withAnimation(.easeInOut(duration: 0.3)) {
                resolveSupportNudge()
                footerVisible = true
            }
        }
    }
}

/// The milestone version of the support ask: one pill naming the lifetime total,
/// with the coffee link as a small secondary button. Shown once per milestone (see
/// `SupportNudge`), so it has no dismiss.
private struct SupportNudgeCard: View {
    let milestoneBytes: Int64
    let linkOpened: Bool
    let onOpenLink: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rosette")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityHidden(true)

            Text("Over \(formatBytes(milestoneBytes)) cleaned up with Purge")
                .font(AppStyle.Typography.rowTitle)
                .foregroundStyle(AppColors.textPrimary)

            Text("·")
                .font(AppStyle.Typography.rowTitle)
                .foregroundStyle(AppColors.textTertiary)
                .accessibilityHidden(true)

            if linkOpened {
                Text("Thanks, that means a lot.")
                    .font(AppStyle.Typography.rowTitle)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.trailing, 6)
            } else {
                Button(action: onOpenLink) {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer")
                }
                .buttonStyle(.purge(.secondary, size: .small))
            }
        }
        .lineLimit(1)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(AppColors.surfaceCard))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The everyday version of the support ask: one dim line under Done, no dismiss.
/// The line changes with each clean (see `SupportNudge.lines(for:)`); only the
/// coffee part is the link, so it reads as a fact plus an option.
private struct SupportFooterLink: View {
    let line: SupportNudge.Line
    let linkOpened: Bool
    let onOpenLink: () -> Void

    private var text: AttributedString {
        var text = AttributedString(line.prefix)
        var link = AttributedString(line.linkText)
        link.link = SupportNudge.url
        link.foregroundColor = AppColors.textSecondary
        link.underlineStyle = .single
        text.append(link)
        return text
    }

    var body: some View {
        Group {
            if linkOpened {
                Text("Thanks, that means a lot.")
            } else {
                Text(text)
                    .environment(\.openURL, OpenURLAction { _ in
                        onOpenLink()
                        return .handled
                    })
            }
        }
        .font(AppStyle.Typography.callout)
        .foregroundStyle(AppColors.textTertiary)
    }
}

private struct CompletionTimeTagline: View {
    let elapsedSeconds: Double
    let boltFlashToken: Int

    private var isFastClean: Bool {
        elapsedSeconds < 3
    }

    private var timeText: String {
        TimeTagline.timeText(for: elapsedSeconds)
    }

    var body: some View {
        HStack(spacing: 5) {
            if isFastClean {
                CompletionBoltAnchor(flashToken: boltFlashToken)
            } else {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }

            HStack(spacing: 0) {
                Text("done in ")
                    .fontWeight(.regular)
                    .foregroundStyle(AppColors.textSecondary)
                Text(timeText)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .font(AppStyle.Typography.body.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }
}

private struct CompletionBoltAnchor: View {
    let flashToken: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEnergized = false
    @State private var lastSeenToken = 0
    @State private var echoGeneration = 0
    @State private var chargeTask: Task<Void, Never>?

    private static let flashColor = AppColors.accentCelebrate
    private static let chargeSpring = Animation.spring(response: 0.58, dampingFraction: 0.62)

    var body: some View {
        ZStack {
            if echoGeneration > 0, !reduceMotion {
                CompletionBoltEchoRings(color: Self.flashColor, generation: echoGeneration)
            }

            ZStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(AppColors.textTertiary)
                    .opacity(isEnergized ? 0 : 1)
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Self.flashColor)
                    .opacity(isEnergized ? 1 : 0)
            }
            .scaleEffect(isEnergized ? 1.12 : 1)
            .rotationEffect(.degrees(isEnergized ? 14 : -12))
        }
        .font(AppStyle.Typography.metadata)
        .animation(reduceMotion ? nil : Self.chargeSpring, value: isEnergized)
        .onAppear { reactToToken(flashToken) }
        .onChange(of: flashToken) { reactToToken($0) }
        .onDisappear { chargeTask?.cancel() }
    }

    private func reactToToken(_ token: Int) {
        guard token > 0, token != lastSeenToken else { return }
        lastSeenToken = token
        chargeTask?.cancel()

        guard !reduceMotion else {
            isEnergized = true
            return
        }

        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) {
            isEnergized = false
        }

        chargeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            echoGeneration += 1
            isEnergized = true
        }
    }
}

private struct CompletionBoltEchoRings: View {
    let color: Color
    let generation: Int

    var body: some View {
        ZStack {
            CompletionBoltEchoRing(color: color, delay: 0)
                .id("\(generation)-0")
            CompletionBoltEchoRing(color: color, delay: 0.13)
                .id("\(generation)-1")
        }
    }
}

private struct CompletionBoltEchoRing: View {
    let color: Color
    let delay: Double

    @State private var expanded = false

    var body: some View {
        Image(systemName: "bolt")
            .font(.caption)
            .foregroundStyle(color)
            .scaleEffect(expanded ? 2.15 : 0.9)
            .opacity(expanded ? 0 : 0.62)
            .rotationEffect(.degrees(expanded ? 16 : -12))
            .onAppear {
                expanded = false
                withAnimation(.easeOut(duration: 0.68).delay(delay)) {
                    expanded = true
                }
            }
    }
}

private struct CleanFailureDisclosure: View {
    let failures: [CleanFailureItem]
    @Binding var isExpanded: Bool
    let retryingIDs: Set<UUID>
    let onOpenSettings: () -> Void
    let onRetry: (CleanFailureItem) -> Void

    private var summaryText: String {
        failures.count == 1
            ? String(localized: "1 item couldn't be cleaned")
            : String(localized: "\(failures.count) items couldn't be cleaned")
    }

    private var visibleFailures: [CleanFailureItem] {
        Array(failures.prefix(3))
    }

    private var hiddenCount: Int {
        max(0, failures.count - visibleFailures.count)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(summaryText)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .font(AppStyle.Typography.callout)
                .foregroundStyle(AppColors.textTertiary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleFailures) { failure in
                        CleanFailureRow(
                            failure: failure,
                            isRetrying: retryingIDs.contains(failure.id),
                            onOpenSettings: onOpenSettings,
                            onRetry: onRetry
                        )
                    }

                    if hiddenCount > 0 {
                        Text("+\(hiddenCount) more")
                            .font(AppStyle.Typography.metadata)
                            .foregroundStyle(AppColors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: 360)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .multilineTextAlignment(.center)
    }
}

/// The completion-screen treatment for apps that are locked to an administrator.
/// Not an error and not a silent success: it names what's held, says in one line why,
/// reassures in one line that nothing is really deleted, and offers a single action —
/// set the helper up once, or (once set up) remove everything held.
private struct NeedsAdministratorPanel: View {
    let items: [CleanFailureItem]
    let isHelperEnabled: Bool
    let needsApproval: Bool
    let isWorking: Bool
    let onPrimaryAction: () -> Void
    let onRevealInFinder: () -> Void

    private var isSingle: Bool { items.count == 1 }

    private var title: String {
        String(localized: "macOS needs your permission")
    }

    /// Only when several are held: name them so the count isn't a mystery.
    private var namesLine: String? {
        guard !isSingle else { return nil }
        let names = items.map(\.displayName)
        switch names.count {
        case 2: return String(localized: "\(names[0]) and \(names[1])")
        case 3: return String(localized: "\(names[0]), \(names[1]), and \(names[2])")
        default: return String(localized: "\(names[0]), \(names[1]), and \(names.count - 2) more")
        }
    }

    private var explanation: String {
        isSingle
            ? String(localized: "An administrator installed \(items[0].displayName), so macOS needs your permission before it can move to the Trash.")
            : String(localized: "An administrator installed them, so macOS needs your permission before they can move to the Trash.")
    }

    private var trustLine: String {
        isSingle
            ? String(localized: "Moved to the Trash, not deleted. Restore it anytime.")
            : String(localized: "Moved to the Trash, not deleted. Restore them anytime.")
    }

    private var primaryTitle: String {
        // Approval pending: the button's job is to reopen Settings, so say so rather
        // than "Set up," which reads as if setup hasn't started.
        if needsApproval { return String(localized: "Open System Settings") }
        if !isHelperEnabled { return String(localized: "Set up secure removal") }
        return isSingle ? String(localized: "Remove \(items[0].displayName)") : String(localized: "Remove \(items.count) apps")
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .accessibilityHidden(true)

                Text(LocalizedStringKey(title))
                    .font(AppStyle.Typography.sectionTitle)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)

                if let namesLine {
                    Text(namesLine)
                        .font(AppStyle.Typography.sectionTitle.weight(.regular))
                        .foregroundStyle(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                }

                Text(LocalizedStringKey(explanation))
                    .font(AppStyle.Typography.sectionTitle.weight(.regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

            statusLine

            VStack(spacing: 12) {
                Button(action: onPrimaryAction) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(primaryTitle)
                    }
                }
                .buttonStyle(.purge(.primary, size: .large, width: .fill))
                .disabled(isWorking)

                if isSingle {
                    Button("Remove in Finder instead", action: onRevealInFinder)
                        .buttonStyle(.purge(.secondary, size: .large, width: .fill))
                }

                Text(trustLine)
                    .font(AppStyle.Typography.body)
                    .foregroundStyle(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.Radius.xl, style: .continuous)
                .fill(AppColors.surfaceCard)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.Radius.xl, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if isHelperEnabled {
            Label("Secure removal is on", systemImage: "checkmark.seal.fill")
                .font(AppStyle.Typography.rowTitle)
                .foregroundStyle(AppColors.statusSafeText)
        } else if needsApproval {
            Text("In System Settings ▸ Login Items, switch Purge on under \"Background App Activity,\" then come back.")
                .font(AppStyle.Typography.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CleanFailureRow: View {
    let failure: CleanFailureItem
    let isRetrying: Bool
    let onOpenSettings: () -> Void
    let onRetry: (CleanFailureItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: failure.reason.systemImage)
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(failure.displayName)
                    .font(AppStyle.Typography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(LocalizedStringKey(failure.reason.explanation))
                    .font(AppStyle.Typography.metadata)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if failure.reason.showsOpenSettings || failure.reason.showsRetry {
                    HStack(spacing: 10) {
                        if failure.reason.showsOpenSettings {
                            Button("Open Settings", action: onOpenSettings)
                                .buttonStyle(.purge(.quiet, size: .small))
                        }
                        if failure.reason.showsRetry {
                            Button {
                                onRetry(failure)
                            } label: {
                                if isRetrying {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.7)
                                } else {
                                    Text(failure.reason.retryTitle)
                                }
                            }
                            .buttonStyle(.purge(.quiet, size: .small))
                            .disabled(isRetrying)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(LocalizedStringKey(text))
            .font(AppStyle.Typography.metadataEmphasis)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.sm, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            }
    }

    private var foregroundColor: Color {
        switch tone {
        case .accent: return AppColors.textSecondary
        case .neutral: return AppColors.statusUnsureText
        case .safe: return AppColors.statusSafeText
        case .warning: return AppColors.statusCheckText
        case .danger: return AppColors.statusDangerText
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .accent: return AppColors.fillSecondary
        case .neutral: return AppColors.statusUnsureFill
        case .safe: return AppColors.statusSafeFill
        case .warning: return AppColors.statusCheckFill
        case .danger: return AppColors.statusDangerFill
        }
    }

    private var borderColor: Color {
        switch tone {
        case .accent: return AppColors.borderSubtle
        case .neutral: return AppColors.statusUnsureText.opacity(0.22)
        case .safe: return AppColors.statusSafeText.opacity(0.22)
        case .warning: return AppColors.statusCheckText.opacity(0.22)
        case .danger: return AppColors.statusDangerText.opacity(0.22)
        }
    }
}

/// Drives the outline→filled swap on the selected sidebar icon. The selected row
/// owns the only animated state change; deselection is applied in a nil transaction
/// so the previous row does not play the same replacement effect in reverse.
private struct AppNavIcon: View {
    let systemImage: String
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fillProgress: Double?

    var body: some View {
        ZStack {
            Image(systemName: systemImage)
                .opacity(1 - currentFillProgress)

            Image(systemName: filledSystemImage)
                .opacity(currentFillProgress)
                .scaleEffect(0.86 + (0.14 * currentFillProgress))
        }
        .font(AppStyle.Typography.rowTitle)
        .frame(width: 16)
        .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
            .onAppear {
                fillProgress = isSelected ? 1 : 0
            }
            .onChange(of: isSelected) { selected in
                updateFillProgress(isSelected: selected)
            }
            .onChange(of: systemImage) { _ in
                setFillProgressWithoutAnimation(isSelected ? 1 : 0)
            }
    }

    private var currentFillProgress: Double {
        fillProgress ?? (isSelected ? 1 : 0)
    }

    private var filledSystemImage: String {
        "\(systemImage).fill"
    }

    private func updateFillProgress(isSelected selected: Bool) {
        guard !reduceMotion else {
            setFillProgressWithoutAnimation(selected ? 1 : 0)
            return
        }

        if selected {
            setFillProgressWithoutAnimation(0)
            withAnimation(.snappy(duration: 0.2)) {
                fillProgress = 1
            }
        } else {
            setFillProgressWithoutAnimation(0)
        }
    }

    private func setFillProgressWithoutAnimation(_ progress: Double) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            fillProgress = progress
        }
    }
}

struct AppNavRow: View {
    /// Trailing detail: a category's size, or a spinner while its scan runs.
    enum Accessory: Equatable {
        case none
        case value(String, isDimmed: Bool)
        case progress
    }

    let title: String
    let systemImage: String
    let isSelected: Bool
    var accessory: Accessory = .none
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppStyle.Spacing.xSmall) {
                AppNavIcon(systemImage: systemImage, isSelected: isSelected)
                Text(LocalizedStringKey(title))
                    .font(AppStyle.Typography.body.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: AppStyle.Spacing.xSmall)
                accessoryView
            }
            .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
            .padding(.horizontal, SidebarLayout.navRowInnerPadding)
            .padding(.vertical, 6)
            .background(navBackground, in: RoundedRectangle(cornerRadius: SidebarLayout.selectionCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .value(let text, let isDimmed):
            Text(LocalizedStringKey(text))
                .font(AppStyle.Typography.metadataEmphasis)
                .monospacedDigit()
                .foregroundStyle(isDimmed ? AppColors.textTertiary.opacity(0.5) : AppColors.textTertiary)
                .lineLimit(1)
        case .progress:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
                .accessibilityLabel("Scanning")
        }
    }

    private var navBackground: Color {
        if isSelected {
            return AppColors.fillSecondary
        }
        if isHovering {
            return AppColors.surfaceRaised
        }
        return .clear
    }
}

struct AppSortMenu: View {
    @Binding var selection: SortOption

    var body: some View {
        AppDropdown(
            options: SortOption.allCases,
            selection: selection,
            optionLabel: { $0.displayName },
            onSelect: { selection = $0 }
        ) {
            Label(selection.shortDisplayName, systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.purge(.secondary))
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

/// Blocks window close and app quit while a cleaning run is mid-flight.
/// `isCleaningActive` is wired to `PurgeStore` once at launch.
@MainActor
enum CleaningQuitGuard {
    static var isCleaningActive: () -> Bool = { false }

    /// Returns `true` when the user chooses to interrupt the clean anyway.
    static func confirmInterruption() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Purge is still cleaning")
        alert.informativeText = String(localized: "Purge is still cleaning. Quitting now may leave some items partially removed.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        alert.addButton(withTitle: String(localized: "Keep Cleaning"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Shared gate for `windowShouldClose` / `applicationShouldTerminate`.
    static func shouldAllowTermination() -> Bool {
        guard isCleaningActive() else { return true }
        return confirmInterruption()
    }
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard MainActor.assumeIsolated({ CleaningQuitGuard.shouldAllowTermination() }) else {
            return false
        }
        if let chainedDelegate,
           chainedDelegate.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            return chainedDelegate.windowShouldClose!(sender)
        }
        return true
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

/// Fills the detail column and pulls its content up under the hidden title bar
/// so the page header sits flush with the top of the window.
private struct DetailColumnCompactTopModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
    }
}

/// Pulls the sidebar header + nav up under the hidden title bar so the brand mark
/// clears the traffic lights without the system reserving a separate strip.
/// Only fills height — the sidebar's width is fixed by an earlier `.frame(width:)`,
/// so expanding width here would let it claim extra space in the parent `HStack`.
private struct SidebarCompactTopModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
    }
}

extension View {
    func fixedAppWindowWidth() -> some View {
        background(FixedWindowWidthConfigurator())
    }

    func detailColumnCompactTop() -> some View {
        modifier(DetailColumnCompactTopModifier())
    }

    func sidebarCompactTop() -> some View {
        modifier(SidebarCompactTopModifier())
    }
}
