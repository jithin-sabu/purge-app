import AppKit
import SwiftUI

/// Full-window gate shown when the app is past onboarding but Full Disk Access is missing —
/// an install that updated from a pre-onboarding build, or one where access was revoked in
/// System Settings.
///
/// This is the app's *only* in-app access surface. Every scan needs FDA, so rather than each
/// tab, the menu, and the scan paths each explaining the problem, the whole window waits here
/// until access is granted and then hands over to a fully working app. Nothing downstream ever
/// has to ask again.
struct FullDiskAccessGateView: View {
  @EnvironmentObject private var store: PurgeStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var didOpenSettings = false

  /// Called once access flips to granted, so the app can start its first scan.
  let onGranted: () -> Void

  var body: some View {
    ZStack {
      AppColors.bgBase
        .ignoresSafeArea()

      VStack(spacing: AppStyle.Spacing.medium) {
        Image(systemName: "lock.shield")
          .font(.system(size: 40))
          .foregroundStyle(.secondary)
          .onboardingBlurIn(index: 0)

        OnboardingStepTitle(text: "Purge needs Full Disk Access")
          .onboardingBlurIn(index: 1)

        Text("Every scan reads protected Library folders, so Purge can't find anything without it. Turn Purge on in System Settings and this window continues on its own.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: OnboardingLayout.contentMaxWidth)
          .onboardingBlurIn(index: 2)

        OnboardingPrimaryButton(title: "Open System Settings", systemImage: "arrow.up.forward") {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            didOpenSettings = true
          }
          openFullDiskAccessSettings()
          store.refreshPermission()
        }
        .padding(.top, AppStyle.Spacing.xSmall)
        .onboardingBlurIn(index: 3)

        if didOpenSettings {
          Text("Find Purge under Privacy & Security → Full Disk Access, toggle it on, then come back.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: OnboardingLayout.contentMaxWidth)
            .transition(.opacity)
        }
      }
      .padding(.horizontal, OnboardingLayout.horizontalPadding)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task { await pollUntilGranted() }
  }

  /// macOS grants FDA to a running process without any callback, so the only way to notice is
  /// to keep probing. Cheap (three directory listings) and only alive while this gate is up.
  private func pollUntilGranted() async {
    while !Task.isCancelled {
      store.refreshPermission()
      if store.hasFullDiskAccess {
        onGranted()
        return
      }
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
    }
  }
}

#Preview {
  FullDiskAccessGateView(onGranted: {})
    .environmentObject(PurgeStore())
    .frame(width: AppWindowLayout.width, height: AppWindowLayout.defaultHeight)
}
