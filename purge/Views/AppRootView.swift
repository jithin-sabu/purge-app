import AppKit
import SwiftUI

struct AppRootView: View {
  @AppStorage(FirstRunGate.onboardingCompletedKey) private var hasCompletedOnboarding = false
  @State private var isOnboardingExitingToHome = false
  @State private var isMainAppRevealed = false
  @EnvironmentObject private var store: PurgeStore
  @EnvironmentObject private var diskStore: DiskSummaryStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openWindow) private var openWindow

  /// There is no access gate: without Full Disk Access the app runs limited scans and the
  /// tabs that need more say so themselves. See `ScanAccess` and `LookDeeperView`.
  private var showsAppChrome: Bool {
    hasCompletedOnboarding || isOnboardingExitingToHome
  }

  private var showsMainApp: Bool {
    hasCompletedOnboarding || isMainAppRevealed || reduceMotion
  }

  /// Whether `ContentView` should exist at all. Distinct from `showsMainApp`, which only
  /// controls its opacity during the onboarding hand-off.
  private var showsMainAppContent: Bool {
    hasCompletedOnboarding || isOnboardingExitingToHome
  }

  var body: some View {
    ZStack {
      // Mounted only once it is about to be needed. Keeping it in the hierarchy for the
      // whole of onboarding meant the full main app — including the App Caches list and
      // every one of its rows — was laid out and rendered behind the onboarding overlay
      // at `opacity(0)`, competing with the step transitions for the main thread.
      // Profiling the onboarding flow showed `ScanResultRow` and
      // `AppCachesView.cacheResultsListContent` bodies running while onboarding was on
      // screen. The pre-mount before the reveal is preserved: `isOnboardingExitingToHome`
      // flips first, and `revealMainAppAfterMount` already waits 120ms before fading in.
      if showsMainAppContent {
        ContentView(isLifecycleActive: hasCompletedOnboarding)
          .opacity(showsMainApp ? 1 : 0)
          .blur(radius: showsMainApp ? 0 : OnboardingTransitions.dismissBlurRadius)
          .allowsHitTesting(showsMainApp)
          .accessibilityHidden(!showsMainApp)
      }
      if !hasCompletedOnboarding {
        OnboardingFlowView(
          hasCompletedOnboarding: $hasCompletedOnboarding,
          isExitingToHome: $isOnboardingExitingToHome
        )
        .allowsHitTesting(!isOnboardingExitingToHome)
      }
    }
    .toolbar(showsAppChrome ? .visible : .hidden, for: .windowToolbar)
    // Returning from System Settings is the moment access typically changes, and `scenePhase`
    // never reports it on macOS (probe-proven), so the app-level notification is the signal.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      store.refreshPermission()
    }
    .onChange(of: store.hasFullDiskAccess) { _ in
      handleAccessChange()
    }
    .onAppear {
      isMainAppRevealed = hasCompletedOnboarding
    }
    // The status item's label normally registers this. In on-demand mode there is
    // no status item, so without this a deleted-apps review could not build a
    // window after a windowless launch.
    .task { AppWindowPresenter.registerOpenWindowAction(openWindow) }
    .onChange(of: isOnboardingExitingToHome) { isExiting in
      if isExiting {
        revealMainAppAfterMount()
      } else if !hasCompletedOnboarding {
        isMainAppRevealed = false
      }
    }
    .onChange(of: hasCompletedOnboarding) { isCompleted in
      if isCompleted {
        isMainAppRevealed = true
      } else if !isOnboardingExitingToHome {
        isMainAppRevealed = false
      }
    }
  }

  /// A grant made in System Settings while the look-deeper screen is closed still
  /// gets a rescan and a word about what turned up. The screen reveals its own
  /// grants and claims them first, and onboarding has its own step for this.
  private func handleAccessChange() {
    guard !TestHost.isActive() else { return }
    let isNewGrant = store.consumeFullDiskAccessGrant()
    guard isNewGrant, hasCompletedOnboarding, !store.isLookDeeperPresented else { return }
    Task { await store.revealFullDiskAccessGrant() }
  }

  private func revealMainAppAfterMount() {
    guard !hasCompletedOnboarding else {
      isMainAppRevealed = true
      return
    }
    isMainAppRevealed = false

    guard !reduceMotion else {
      isMainAppRevealed = true
      return
    }

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard isOnboardingExitingToHome, !hasCompletedOnboarding else { return }
      withAnimation(.easeInOut(duration: OnboardingTransitions.dismissDuration)) {
        isMainAppRevealed = true
      }
    }
  }
}
