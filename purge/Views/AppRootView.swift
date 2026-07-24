import AppKit
import SwiftUI

struct AppRootView: View {
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
  @State private var isOnboardingExitingToHome = false
  @State private var isMainAppRevealed = false
  @EnvironmentObject private var store: PurgeStore
  @EnvironmentObject private var diskStore: DiskSummaryStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Onboarding cannot be completed without Full Disk Access, so this only catches installs that
  /// arrived past onboarding without it: an update from a pre-onboarding build, or access revoked
  /// in System Settings. Everything downstream can then assume access is granted.
  private var showsAccessGate: Bool {
    hasCompletedOnboarding && !store.hasFullDiskAccess
  }

  private var showsAppChrome: Bool {
    (hasCompletedOnboarding || isOnboardingExitingToHome) && !showsAccessGate
  }

  private var showsMainApp: Bool {
    (hasCompletedOnboarding || isMainAppRevealed || reduceMotion) && !showsAccessGate
  }

  var body: some View {
    ZStack {
      ContentView(isLifecycleActive: hasCompletedOnboarding && store.hasFullDiskAccess)
        .opacity(showsMainApp ? 1 : 0)
        .blur(radius: showsMainApp ? 0 : OnboardingTransitions.dismissBlurRadius)
        .allowsHitTesting(showsMainApp)
        .accessibilityHidden(!showsMainApp)
      if !hasCompletedOnboarding {
        OnboardingFlowView(
          hasCompletedOnboarding: $hasCompletedOnboarding,
          isExitingToHome: $isOnboardingExitingToHome
        )
        .allowsHitTesting(!isOnboardingExitingToHome)
      } else if showsAccessGate {
        FullDiskAccessGateView(onGranted: startScanAfterAccessGranted)
      }
    }
    .toolbar(showsAppChrome ? .visible : .hidden, for: .windowToolbar)
    // Returning from System Settings is the moment access typically changes, and `scenePhase`
    // never reports it on macOS (probe-proven), so the app-level notification is the signal.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      store.refreshPermission()
    }
    .onAppear {
      isMainAppRevealed = hasCompletedOnboarding
    }
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

  /// The gate hands over to a working app: nothing else re-checks access, so the first scan is
  /// started here rather than left to `ContentView`, which was mounted (and bailed) without it.
  private func startScanAfterAccessGranted() {
    guard store.hasFullDiskAccess, !store.isScanningAll else { return }
    Task { await store.scanAll() }
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
