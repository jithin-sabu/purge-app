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
    static let width: CGFloat = 210
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
    static let pageTitleChromeHeight: CGFloat = topContentInset + 24 + AppStyle.Spacing.small
    /// Extra line when a subtitle is shown (spacing + subheadline).
    static let pageSubtitleChromeHeight: CGFloat = 4 + 16

    static func pageHeaderChromeHeight(includesSubtitle: Bool) -> CGFloat {
        pageTitleChromeHeight + (includesSubtitle ? pageSubtitleChromeHeight : 0)
    }
}

@available(macOS 26.0, *)
extension View {
    /// Sticky scan-tab chrome with a soft scroll edge blur as list rows pass underneath.
    func scanTabSoftScrollEdge<Chrome: View>(@ViewBuilder chrome: @escaping () -> Chrome) -> some View {
        safeAreaBar(edge: .top, spacing: 0, content: chrome)
            .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// An invisible page-header sized bar reserves space so cards blur as they pass
    /// underneath, while the visible animated title is owned by the persistent parent overlay.
    func detailPageScrollEdge(title: String) -> some View {
        safeAreaBar(edge: .top, spacing: 0) {
            AppSectionPageHeader(title: title)
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

/// Single home for both deletion phases: presented in `.cleaning` when the user
/// confirms deletion, it flips to `.complete` in place when the engine finishes.
/// Sessions created already-`.complete` (safe cleanup, onboarding) render the
/// completion layout immediately, exactly as before.
struct SafeCleanupCelebrationOverlay: View {
    @ObservedObject var session: DeletionSession
    let onDone: () -> Void

    @EnvironmentObject private var store: PurgeStore
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

    private static let confettiThresholdBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let minimumCleaningDwell: TimeInterval = 1.2

    private let celebrationAccent = AppStyle.accent
    private let sheetBackground = Color(
        light: NSColor(calibratedWhite: 0.08, alpha: 1),
        dark: NSColor(calibratedWhite: 0.08, alpha: 1)
    )

    init(session: DeletionSession, onDone: @escaping () -> Void) {
        self.session = session
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
        _displayedBytes = State(initialValue: mountsComplete ? session.finalBytesFreed : 0)
        _displayedFraction = State(initialValue: mountsComplete ? 1 : 0)
        _tagline = State(initialValue: mountsComplete ? TimeTagline.select(for: session.elapsedSeconds) : nil)
        _boltFlashToken = State(
            initialValue: mountsComplete && session.elapsedSeconds < 3 ? 1 : 0
        )
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
                    .scaleEffect(checkmarkScale)
                    .opacity(checkmarkVisible ? 1 : 0)
                    .accessibilityHidden(true)

                VStack(spacing: AppStyle.Spacing.small) {
                    Text(formatBytes(displayedBytes))
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text(subtitleText)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)

                    // The cleaning-phase progress group draws into the slot the
                    // completion lines occupy (always laid out, opacity-toggled),
                    // so neither phase ever shifts the other's elements.
                    ZStack(alignment: .top) {
                        VStack(spacing: AppStyle.Spacing.small) {
                            if let comparisonItems = OnboardingSizeComparison.items(for: comparisonBytes) {
                                OnboardingSizeComparisonLine(items: comparisonItems)
                                    .foregroundStyle(.white.opacity(0.78))
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

                Spacer(minLength: 0)

                VStack(spacing: AppStyle.Spacing.small) {
                    if session.phase == .complete, session.failedCount > 0 {
                        CleanFailureDisclosure(
                            failures: session.failedItems,
                            isExpanded: $failuresExpanded,
                            retryingIDs: retryingFailureIDs,
                            onOpenSettings: openFullDiskAccessSettings,
                            onRetry: retryFailure
                        )
                    }

                    if reservesTrashDisclaimerSpace {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                            Text("Empty your Trash to reclaim this space.")
                        }
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    }

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
                    .disabled(!footerVisible)
                }
                .opacity(footerVisible ? 1 : 0)
            }
            .padding(.horizontal, 52)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(sheetBackground)
            .accessibilityElement(children: .contain)
        }
        .onAppear(perform: handleAppear)
        .onChange(of: session.phase) { phase in
            guard phase == .complete else { return }
            beginCompletionSequence()
        }
        .onChange(of: session.bytesFreed) { newValue in
            mirrorLiveProgress(bytesFreed: newValue)
        }
        .onDisappear { sequenceTask?.cancel() }
        .environment(\.colorScheme, .dark)
    }

    private var progressGroup: some View {
        VStack(spacing: AppStyle.Spacing.xSmall) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.14))
                    Capsule(style: .continuous)
                        .fill(celebrationAccent)
                        .frame(width: max(0, min(1, displayedFraction)) * geo.size.width)
                }
            }
            .frame(height: 4)

            Text(currentItemText)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cleaning, \(formatBytes(displayedBytes)) of \(formatBytes(session.totalBytes))")
    }

    private var subtitleText: String {
        subtitleShowsComplete ? "moved to Trash" : "of \(formatBytes(session.totalBytes)) selected"
    }

    private var currentItemText: String {
        session.currentItemName.map { "Cleaning \($0)…" } ?? "Cleaning…"
    }

    private func retryFailure(_ item: CleanFailureItem) {
        guard !retryingFailureIDs.contains(item.id) else { return }
        retryingFailureIDs.insert(item.id)
        Task {
            let freedBytes = await store.retryCleanFailure(item, session: session)
            retryingFailureIDs.remove(item.id)
            guard let freedBytes else { return }
            if reduceMotion {
                displayedBytes += freedBytes
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    displayedBytes += freedBytes
                }
            }
        }
    }

    /// Shown in the complete phase only when something actually went to Trash.
    /// During cleaning the (invisible) footer reserves its space so nothing shifts.
    private var reservesTrashDisclaimerSpace: Bool {
        session.phase == .cleaning || session.movedToTrashCount > 0
    }

    /// Reserves comparison-line space from the selected total during cleaning;
    /// switches to the exact engine result at completion.
    private var comparisonBytes: Int64 {
        session.phase == .complete ? session.finalBytesFreed : session.totalBytes
    }

    private var showsConfetti: Bool {
        confettiArmed && session.finalBytesFreed >= Self.confettiThresholdBytes && !reduceMotion
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
    }

    private func mirrorLiveProgress(bytesFreed: Int64) {
        guard session.phase == .cleaning, !didBeginCompletion else { return }
        let fraction = session.totalBytes > 0
            ? min(1.0, Double(bytesFreed) / Double(session.totalBytes))
            : 0
        if reduceMotion {
            displayedBytes = bytesFreed
            displayedFraction = fraction
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                displayedBytes = bytesFreed
                displayedFraction = fraction
            }
        }
    }

    private func beginCompletionSequence() {
        guard !didBeginCompletion else { return }
        didBeginCompletion = true

        sequenceTask = Task { @MainActor in
            let finalBytes = session.finalBytesFreed
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
            withAnimation(.easeInOut(duration: 0.3)) {
                footerVisible = true
            }
        }
    }
}

private enum CompletionCelebrationAccent {
    static let timeHighlight = Color(red: 1, green: 0.78, blue: 0.05)
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
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 0) {
                Text("done in ")
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                Text(timeText)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .font(.system(.body, design: .rounded, weight: .medium))
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

    private static let flashColor = CompletionCelebrationAccent.timeHighlight
    private static let chargeSpring = Animation.spring(response: 0.58, dampingFraction: 0.62)

    var body: some View {
        ZStack {
            if echoGeneration > 0, !reduceMotion {
                CompletionBoltEchoRings(color: Self.flashColor, generation: echoGeneration)
            }

            ZStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.tertiary)
                    .opacity(isEnergized ? 0 : 1)
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Self.flashColor)
                    .opacity(isEnergized ? 1 : 0)
            }
            .scaleEffect(isEnergized ? 1.12 : 1)
            .rotationEffect(.degrees(isEnergized ? 14 : -12))
        }
        .font(.caption)
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
            ? "1 item couldn't be cleaned"
            : "\(failures.count) items couldn't be cleaned"
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
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
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
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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

private struct CleanFailureRow: View {
    let failure: CleanFailureItem
    let isRetrying: Bool
    let onOpenSettings: () -> Void
    let onRetry: (CleanFailureItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: failure.reason.systemImage)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(failure.displayName)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(failure.reason.explanation)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if failure.reason.showsOpenSettings || failure.reason.showsRetry {
                    HStack(spacing: 10) {
                        if failure.reason.showsOpenSettings {
                            Button("Open Settings", action: onOpenSettings)
                                .buttonStyle(CleanFailureActionButtonStyle())
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
                                    Text("Retry")
                                }
                            }
                            .buttonStyle(CleanFailureActionButtonStyle())
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

private struct CleanFailureActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.72))
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
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.Radius.chip, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            }
    }

    private var foregroundColor: Color {
        switch tone {
        case .accent: return .white
        default: return color
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .accent: return AppStyle.accent
        case .neutral:
            return Color(
                light: NSColor.black.withAlphaComponent(0.06),
                dark: NSColor.white.withAlphaComponent(0.1)
            )
        default: return color.opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch tone {
        case .accent: return AppStyle.accent.opacity(0.85)
        case .neutral: return AppStyle.hairline
        default: return color.opacity(0.22)
        }
    }

    private var color: Color {
        switch tone {
        case .neutral: return AppStyle.formLabel
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
                    .font(.system(size: 13, weight: .medium))
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

/// Blocks window close and app quit while a cleaning run is mid-flight.
/// `isCleaningActive` is wired to `PurgeStore` once at launch.
@MainActor
enum CleaningQuitGuard {
    static var isCleaningActive: () -> Bool = { false }

    /// Returns `true` when the user chooses to interrupt the clean anyway.
    static func confirmInterruption() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Purge is still cleaning"
        alert.informativeText = "Purge is still cleaning. Quitting now may leave some items partially removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Cleaning")
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

