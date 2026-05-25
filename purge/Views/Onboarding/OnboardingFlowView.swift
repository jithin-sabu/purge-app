import SwiftUI

struct OnboardingFlowView: View {
  @Binding var hasCompletedOnboarding: Bool
  @Binding var isExitingToHome: Bool
  @EnvironmentObject private var store: PurgeStore
  @EnvironmentObject private var diskStore: DiskSummaryStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  @State private var step: OnboardingStep = .welcome
  @StateObject private var revealController = OnboardingScanRevealController()
  @State private var celebrationFreedBytes: Int64 = 0
  @State private var pinnedCleanupCandidates: [PurgeStore.DeletionCandidate] = []
  @State private var isResultsCleaning = false

  @AppStorage("onboarding.pendingCelebration") private var pendingCelebration = false

  var body: some View {
  ZStack {
    AppStyle.canvas
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

    if let freedBytes = store.interactiveSafeCleanupFreedBytes {
      SafeCleanupCelebrationOverlay(freedBytes: freedBytes) {
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
    value: store.interactiveSafeCleanupFreedBytes != nil
  )
  .frame(
    minWidth: AppWindowLayout.width,
    minHeight: AppWindowLayout.minHeight
  )
  .tint(AppStyle.accent)
  .onChange(of: scenePhase) { phase in
    guard phase == .active, step == .permissions else { return }
    store.refreshPermission()
  }
  }

  private var showsFooter: Bool {
    switch step {
    case .firstScan, .cleaning, .celebration:
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
      case .permissions:
        OnboardingPermissionsStep()
      case .preferences:
        OnboardingPreferencesStep()
      case .firstScan:
        OnboardingFirstScanStep(
          revealController: revealController,
          onScanComplete: { advance(to: .results) }
        )
      case .results:
        OnboardingResultsStep()
      case .cleaning:
        OnboardingCleaningStep(pinnedCandidates: pinnedCleanupCandidates) { freedBytes in
          celebrationFreedBytes = freedBytes
          advance(to: .celebration)
        }
      case .celebration:
        OnboardingCelebrationView(freedBytes: celebrationFreedBytes) {
          finishOnboarding()
        }
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
        OnboardingPrimaryButton(title: "Get started") {
          advance(to: .permissions)
        }
      case .permissions:
        OnboardingPrimaryButton(
          title: "Grant permissions",
          isEnabled: store.hasFullDiskAccess
        ) {
          grantPermissions(andSkipOptional: false)
        }
        OnboardingSecondaryButton(title: "Skip optional ones for now", style: .outlined) {
          grantPermissions(andSkipOptional: true)
        }
        if !store.hasFullDiskAccess {
          OnboardingSecondaryButton(title: "Open Privacy Settings") {
            openFullDiskAccessSettings()
            store.refreshPermission()
          }
        }
      case .preferences:
        OnboardingPrimaryButton(title: "Looks good, continue") {
          OnboardingPreferencesStep.applyToScheduledPreferences()
          advance(to: .firstScan)
        }
      case .results:
        Text("Your documents, photos, and projects are never touched.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, AppStyle.Spacing.xxSmall)
        OnboardingPrimaryButton(
          title: isResultsCleaning ? "Cleaning..." : cleanNowTitle,
          isLoading: isResultsCleaning
        ) {
          startResultsCleanup()
        }
        OnboardingSecondaryButton(title: "Review everything first", style: .outlined) {
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
    let bytes = store.safeRecoverableBytes
    if bytes > 0 {
      return "Clean \(formatBytes(bytes)) now"
    }
    return "Clean now"
  }

  private func grantPermissions(andSkipOptional: Bool) {
    if !store.hasFullDiskAccess {
      openFullDiskAccessSettings()
    }
    store.refreshPermission()
    if !andSkipOptional {
      Task {
        _ = await ScheduledCleanupNotifier.requestAuthorizationIfNeeded()
        _ = LoginItemRegistrar.register()
      }
    }
    guard store.hasFullDiskAccess else { return }
    advance(to: .preferences)
  }

  private func exitToReviewPath() {
    pendingCelebration = true
    UserDefaults.standard.set(SafetyFilter.all.rawValue, forKey: "filter.appCaches")
    store.selectedTab = .appCaches

    if reduceMotion {
      completeExitToHome()
      return
    }

    isExitingToHome = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(OnboardingTransitions.dismissDuration))
      guard isExitingToHome else { return }
      completeExitToHome()
    }
  }

  private func startResultsCleanup() {
    guard !isResultsCleaning else { return }
    let candidates = store.manualSafeCleanupCandidates()
    guard !candidates.isEmpty else { return }

    pinnedCleanupCandidates = candidates
    isResultsCleaning = true
    guard store.beginInteractiveSafeCleanup(candidates: candidates, reduceMotion: reduceMotion) else {
      isResultsCleaning = false
      return
    }

    Task { @MainActor in
      let summary = await store.performManualSafeCleanNow(pinnedCandidates: candidates)
      if store.errorMessage == nil {
        store.completeInteractiveSafeCleanup(freedBytes: summary.freedBytes)
      } else {
        isResultsCleaning = false
        store.cancelInteractiveSafeCleanup()
      }
    }
  }

  private func completeResultsCleanupCelebration() {
    isResultsCleaning = false
    pendingCelebration = false

    if reduceMotion {
      store.dismissInteractiveSafeCleanupCelebration()
      finishOnboarding()
      return
    }

    withAnimation(.easeInOut(duration: 0.35)) {
      store.dismissInteractiveSafeCleanupCelebration()
    }

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 350_000_000)
      finishOnboarding()
    }
  }

  private func completeExitToHome() {
    isExitingToHome = false
    hasCompletedOnboarding = true
    diskStore.refresh()
  }

  private func finishOnboarding() {
    pendingCelebration = false
    hasCompletedOnboarding = true
    diskStore.refresh()
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
}
