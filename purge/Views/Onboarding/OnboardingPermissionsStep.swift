import SwiftUI

struct OnboardingPermissionsStep: View {
  @EnvironmentObject private var store: PurgeStore

  @State private var loginItemRegistered = false
  @State private var loginItemFailed = false
  @State private var didOpenFullDiskAccessSettings = false

  var body: some View {
    VStack(alignment: .center, spacing: AppStyle.Spacing.medium) {
      OnboardingStepTitle(text: "A couple of quick permissions...")

      VStack(spacing: AppStyle.Spacing.small) {
        OnboardingPermissionRow(
          title: "Full disk access",
          description: "Lets Purge find caches and junk across your entire Mac. Nothing can be scanned without it.",
          badgeText: "Required",
          badgeTone: .accent,
          buttonTitle: "Open settings",
          isGranted: store.hasFullDiskAccess,
          action: requestFullDiskAccess
        )
        .onboardingBlurIn(index: 0)

        OnboardingPermissionRow(
          title: "Login item",
          description: "Keeps Purge running quietly in the background so it's always working for you.",
          badgeText: "Optional",
          badgeTone: .neutral,
          buttonTitle: "Enable login item",
          isGranted: loginItemRegistered,
          statusText: loginItemFailed ? "Not enabled" : nil,
          action: enableLoginItem
        )
        .onboardingBlurIn(index: 1)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, AppStyle.Spacing.large)

      if didOpenFullDiskAccessSettings && !store.hasFullDiskAccess {
        Text("We opened System Settings. Find Purge in the list and toggle it on, then come back here.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, AppStyle.Spacing.small)
          .transition(.opacity)
      }

      if !store.hasFullDiskAccess {
        Text("Grant Full Disk Access to continue — it's the one thing Purge can't work without.")
          .font(.caption)
          .foregroundStyle(AppColors.tagCheckText)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: OnboardingLayout.contentMaxWidth, maxHeight: .infinity, alignment: .top)
    .onAppear { refreshLoginItemStatus() }
    .task { await pollFullDiskAccess() }
  }

  private func refreshLoginItemStatus() {
    loginItemRegistered = LoginItemRegistrar.isRegistered
    loginItemFailed = false
  }

  private func requestFullDiskAccess() {
    withAnimation(.easeInOut(duration: 0.2)) {
      didOpenFullDiskAccessSettings = true
    }
    // No re-check here: this only opens System Settings, so access cannot have been
    // granted yet, and the probe lists three Library directories on the main thread.
    // `pollFullDiskAccess` is already running for this step and picks the grant up
    // within a second, off the main actor.
    openFullDiskAccessSettings()
  }

  private func enableLoginItem() {
    let registered = LoginItemRegistrar.register()
    withAnimation(.easeInOut(duration: 0.2)) {
      loginItemRegistered = registered
      loginItemFailed = !registered
    }
  }

  private func pollFullDiskAccess() async {
    while !Task.isCancelled {
      // Probes off the main actor and publishes only on a change, so the once-a-second
      // poll cannot stutter the step's animations. See `probeFullDiskAccess`.
      let granted = await store.probeFullDiskAccess()
      if granted != store.hasFullDiskAccess {
        withAnimation(.easeInOut(duration: 0.2)) {
          store.applyFullDiskAccess(granted)
        }
      }

      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        break
      }
    }
  }
}
