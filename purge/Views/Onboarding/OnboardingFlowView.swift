import SwiftUI

struct OnboardingFlowView: View {
  @Binding var hasCompletedOnboarding: Bool
  @Binding var isExitingToHome: Bool
  @EnvironmentObject private var store: PurgeStore
  @EnvironmentObject private var diskStore: DiskSummaryStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var step: OnboardingStep = .welcome
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

  private enum LookDeeperExit {
    case home
    case review
  }

  @AppStorage("onboarding.pendingCelebration") private var pendingCelebration = false

  var body: some View {
  ZStack {
    AppColors.bgBase
      .ignoresSafeArea()

    VStack(spacing: 0) {
      stepBody
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, OnboardingLayout.horizontalPadding)
        .padding(.top, OnboardingLayout.verticalPadding)

      if showsFooter {
        footer
          .padding(.horizontal, OnboardingLayout.horizontalPadding)
          .padding(.bottom, OnboardingLayout.verticalPadding)
          .padding(.top, step == .results ? AppStyle.Spacing.xSmall : AppStyle.Spacing.medium)
      }
    }

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
          onGranted: exitAfterLookDeeper
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
        VStack(spacing: AppStyle.Spacing.xxSmall) {
          Text("Your documents, photos, and projects are never touched.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          Text("Cleaned items move to your Trash so you can recover anything. Empty Trash to reclaim the space.")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        OnboardingPrimaryButton(
          title: isResultsCleaning ? "Cleaning..." : cleanNowTitle,
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
      return "Clean \(formatBytes(bytes)) now"
    }
    return store.hasFullDiskAccess ? "Clean now" : "Continue"
  }

  private func exitToReviewPath() {
    lookDeeperExit = .review
    guard store.hasFullDiskAccess else {
      advance(to: .lookDeeper)
      return
    }
    exitAfterLookDeeper()
  }

  /// Leaves onboarding the way the user chose before the look-deeper step.
  private func exitAfterLookDeeper() {
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
    // A limited scan on a tidy Mac can find nothing to clean. Nothing moved, so
    // the ask opens with "only looked in the easy places" rather than "That was".
    guard !candidates.isEmpty else {
      if !store.hasFullDiskAccess {
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
