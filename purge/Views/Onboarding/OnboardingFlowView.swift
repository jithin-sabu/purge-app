import SwiftUI

struct OnboardingFlowView: View {
  @Binding var hasCompletedOnboarding: Bool
  @Binding var isExitingToHome: Bool
  @EnvironmentObject private var store: PurgeStore
  @EnvironmentObject private var diskStore: DiskSummaryStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var step: OnboardingStep
  @StateObject private var revealController = OnboardingScanRevealController()
  @State private var celebrationMovedToTrashBytes: Int64 = 0
  @State private var pinnedCleanupCandidates: [PurgeStore.DeletionCandidate] = []
  @State private var resultsSnapshot: OnboardingResultsSnapshot?
  @State private var isResultsCleaning = false
  /// Where the flow goes once the look-deeper step is done: home after a clean, or
  /// into App Caches for someone who chose to review the list first.
  @State private var lookDeeperExit: LookDeeperExit = .home
  /// Whether anything was cleaned before the look-deeper step, which sets its
  /// opening line.
  @State private var didCleanBeforeLookDeeper = false

  private enum LookDeeperExit: String {
    case home
    case review
  }

  @AppStorage("onboarding.pendingCelebration") private var pendingCelebration = false
  /// Set when the flow reaches the look-deeper step. A relaunch comes back to it:
  /// macOS may offer to quit and reopen Purge after the Settings toggle, where the
  /// reveal picks up the grant, and someone who quits there before opening
  /// Settings has still finished the scan and maybe a clean.
  @AppStorage(Self.pendingDeeperScanKey) private var pendingDeeperScan = false
  static let pendingDeeperScanKey = "onboarding.pendingDeeperScan"
  /// Saved with `pendingDeeperScan` so the relaunch keeps where the step leads
  /// and how it opens: "Review everything first" still ends in App Caches, and a
  /// clean that already happened still gets "That was the easy part".
  static let lookDeeperExitKey = "onboarding.lookDeeperExit"
  static let didCleanBeforeLookDeeperKey = "onboarding.didCleanBeforeLookDeeper"

  init(hasCompletedOnboarding: Binding<Bool>, isExitingToHome: Binding<Bool>) {
    _hasCompletedOnboarding = hasCompletedOnboarding
    _isExitingToHome = isExitingToHome
    let defaults = UserDefaults.standard
    let resumesLookDeeper = defaults.bool(forKey: Self.pendingDeeperScanKey)
    _step = State(initialValue: resumesLookDeeper ? .lookDeeper : .welcome)
    if resumesLookDeeper {
      let exit = defaults.string(forKey: Self.lookDeeperExitKey).flatMap(LookDeeperExit.init(rawValue:))
      _lookDeeperExit = State(initialValue: exit ?? .home)
      _didCleanBeforeLookDeeper = State(initialValue: defaults.bool(forKey: Self.didCleanBeforeLookDeeperKey))
    }
  }

  var body: some View {
  ZStack {
    AppColors.surfaceBase
      .ignoresSafeArea()

    VStack(spacing: 0) {
      stepBody
        // Results sizes to its content so it and the footer center as one group.
        // Filling the height left the footer pinned to the bottom with a wide gap
        // under the category list.
        .frame(maxWidth: .infinity, maxHeight: step == .results ? nil : .infinity)
        .padding(.horizontal, OnboardingLayout.horizontalPadding)
        .padding(.top, OnboardingLayout.verticalPadding)

      if showsFooter {
        footer
          .padding(.horizontal, OnboardingLayout.horizontalPadding)
          .padding(.bottom, OnboardingLayout.verticalPadding)
          .padding(.top, step == .results ? OnboardingLayout.resultsFooterGap : AppStyle.Spacing.medium)
      }
    }
    .frame(maxHeight: .infinity)

    if let session = store.interactiveSafeCleanupSession {
      SafeCleanupCelebrationOverlay(
        session: session,
        doneTitle: store.hasFullDiskAccess ? "Done" : "Continue"
      ) {
        completeResultsCleanupCelebration()
      }
      .transition(reduceMotion ? .opacity : .safeCleanupCelebrationBlur)
      .zIndex(50)
    }
  }
  .onboardingExitBlur(isExiting: isExitingToHome, reduceMotion: reduceMotion)
  .animation(
    reduceMotion ? nil : .easeInOut(duration: OnboardingTransitions.dismissDuration),
    value: isExitingToHome
  )
  .animation(
    reduceMotion ? nil : .easeInOut(duration: 0.35),
    value: store.interactiveSafeCleanupSession != nil
  )
  .frame(
    minWidth: AppWindowLayout.width,
    minHeight: AppWindowLayout.minHeight
  )
  .tint(AppColors.textPrimary)
  }

  private var showsFooter: Bool {
    switch step {
    case .firstScan, .cleaning, .celebration, .lookDeeper:
      return false
    default:
      return true
    }
  }

  @ViewBuilder
  private var stepBody: some View {
    Group {
      switch step {
      case .welcome:
        OnboardingWelcomeStep()
      case .firstScan:
        OnboardingFirstScanStep(
          revealController: revealController,
          onScanComplete: { advance(to: .results) }
        )
      case .results:
        OnboardingResultsStep(snapshot: resultsSnapshot)
      case .cleaning:
        OnboardingCleaningStep(pinnedCandidates: pinnedCleanupCandidates) { movedBytes in
          celebrationMovedToTrashBytes = movedBytes
          advance(to: .celebration)
        }
      case .celebration:
        OnboardingCelebrationView(bytesMovedToTrash: celebrationMovedToTrashBytes) {
          finishOnboarding()
        }
      case .lookDeeper:
        LookDeeperView(
          context: .onboarding(didClean: didCleanBeforeLookDeeper),
          onNotNow: exitAfterLookDeeper,
          onFinished: exitAfterLookDeeper
        )
        .frame(maxHeight: .infinity)
      }
    }
    .id(step)
    .transition(OnboardingTransitions.stepTransition(reduceMotion: reduceMotion))
  }

  @ViewBuilder
  private var footer: some View {
    VStack(spacing: AppStyle.Spacing.small) {
      switch step {
      case .welcome:
        OnboardingPrimaryButton(title: "Get started", systemImage: "arrow.forward") {
          advance(to: .firstScan)
        }
      case .results:
        // The label says where things go, the way Finder's "Move to Trash" does, so
        // no caption has to explain it. Emptying the Trash is covered afterwards by
        // the celebration, which is when it matters.
        OnboardingPrimaryButton(
          title: isResultsCleaning ? "Moving to Trash..." : cleanNowTitle,
          leadingSystemImage: isResultsCleaning ? nil : "trash",
          isLoading: isResultsCleaning
        ) {
          startResultsCleanup()
        }
        OnboardingSecondaryButton(title: "Review everything first") {
          exitToReviewPath()
        }
        .disabled(isResultsCleaning)
      default:
        EmptyView()
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var cleanNowTitle: String {
    let bytes = resultsSnapshot?.totalBytes ?? store.safeRecoverableBytes
    if bytes > 0 {
      return "Move \(formatBytes(bytes)) to Trash"
    }
    // Nothing to move, so the button only moves the flow on.
    return "Continue"
  }

  private func exitToReviewPath() {
    lookDeeperExit = .review
    guard store.hasFullDiskAccess else {
      advance(to: .lookDeeper)
      return
    }
    exitAfterLookDeeper()
  }

  /// Purge can quit anywhere on the look-deeper step, and macOS may quit and
  /// reopen it once the toggle is on. Everything the step needs on the other side
  /// goes into defaults, not just the step itself.
  private func rememberLookDeeperForRelaunch() {
    let defaults = UserDefaults.standard
    defaults.set(lookDeeperExit.rawValue, forKey: Self.lookDeeperExitKey)
    defaults.set(didCleanBeforeLookDeeper, forKey: Self.didCleanBeforeLookDeeperKey)
    pendingDeeperScan = true
  }

  /// Leaves onboarding the way the user chose before the look-deeper step.
  private func exitAfterLookDeeper() {
    pendingDeeperScan = false
    UserDefaults.standard.removeObject(forKey: Self.lookDeeperExitKey)
    UserDefaults.standard.removeObject(forKey: Self.didCleanBeforeLookDeeperKey)
    switch lookDeeperExit {
    case .home:
      finishOnboarding()
    case .review:
      pendingCelebration = true
      UserDefaults.standard.set(SafetyFilter.all.rawValue, forKey: "filter.appCaches")
      store.selectedTab = .appCaches
      beginExitToHome()
    }
  }

  private func startResultsCleanup() {
    guard !isResultsCleaning else { return }
    let candidates = store.manualSafeCleanupCandidates()
    // A tidy Mac can have nothing to clean. Nothing moved, so without access the
    // ask opens with "Some clutter hides" rather than "That was"; with access
    // there is nothing left to offer and onboarding is done.
    guard !candidates.isEmpty else {
      if store.hasFullDiskAccess {
        finishOnboarding()
      } else {
        lookDeeperExit = .home
        advance(to: .lookDeeper)
      }
      return
    }

    pinnedCleanupCandidates = candidates
    resultsSnapshot = OnboardingResultsSnapshot(
      totalBytes: candidates.reduce(Int64(0)) { $0 + $1.sizeBytes },
      categories: store.onboardingResultsCategories
    )
    isResultsCleaning = true
    guard store.beginInteractiveSafeCleanup(candidates: candidates, reduceMotion: reduceMotion) else {
      isResultsCleaning = false
      resultsSnapshot = nil
      return
    }

    Task { @MainActor in
      let summary = await store.performManualSafeCleanNow(pinnedCandidates: candidates)
      if store.errorMessage == nil {
        store.completeInteractiveSafeCleanup(summary: summary)
      } else {
        isResultsCleaning = false
        resultsSnapshot = nil
        store.cancelInteractiveSafeCleanup()
      }
    }
  }

  private func completeResultsCleanupCelebration() {
    isResultsCleaning = false

    // Without access, the celebration hands over to the look-deeper step instead
    // of the main window. The overlay fades out over it.
    if !store.hasFullDiskAccess {
      lookDeeperExit = .home
      didCleanBeforeLookDeeper = true
      clearCleanupPresentationState()
      store.dismissInteractiveSafeCleanupCelebration()
      advance(to: .lookDeeper)
      return
    }

    if reduceMotion {
      store.dismissInteractiveSafeCleanupCelebration()
      finishOnboardingImmediately()
      return
    }

    clearCleanupPresentationState()
    isExitingToHome = true
    completeExitToHomeAfterDismissal()
  }

  private func completeExitToHome() {
    store.dismissInteractiveSafeCleanupCelebration()
    hasCompletedOnboarding = true
    isExitingToHome = false
    diskStore.refresh()
  }

  private func finishOnboarding() {
    clearCleanupPresentationState()
    beginExitToHome()
  }

  private func finishOnboardingImmediately() {
    clearCleanupPresentationState()
    completeExitToHome()
  }

  private func beginExitToHome() {
    if reduceMotion {
      completeExitToHome()
      return
    }

    isExitingToHome = true
    completeExitToHomeAfterDismissal()
  }

  private func completeExitToHomeAfterDismissal() {
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(OnboardingTransitions.dismissDuration))
      guard isExitingToHome else { return }
      completeExitToHome()
    }
  }

  private func clearCleanupPresentationState() {
    pendingCelebration = false
    store.onboardingCelebrationMovedToTrashBytes = nil
    store.lastDeletionReport = nil
  }

  private func advance(to next: OnboardingStep) {
    if next == .lookDeeper { rememberLookDeeperForRelaunch() }
    if reduceMotion {
      step = next
    } else {
      withAnimation(.easeInOut(duration: 0.45)) {
        step = next
      }
    }
  }
}

#Preview {
  OnboardingFlowView(
    hasCompletedOnboarding: .constant(false),
    isExitingToHome: .constant(false)
  )
  .environmentObject(PurgeStore())
  .environmentObject(DiskSummaryStore())
  .environmentObject(TrashStore())
}
