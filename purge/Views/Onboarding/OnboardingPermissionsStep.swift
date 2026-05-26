import SwiftUI

struct OnboardingPermissionsStep: View {
  @EnvironmentObject private var store: PurgeStore

  @State private var loginItemRegistered = false
  @State private var loginItemFailed = false
  @State private var didOpenFullDiskAccessSettings = false

  var body: some View {
    VStack(alignment: .center, spacing: AppStyle.Spacing.medium) {
      OnboardingStepTitle(text: "A couple of quick permissions.")

      VStack(spacing: AppStyle.Spacing.small) {
        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
          OnboardingPermissionRow(
            symbol: "externaldrive.fill.badge.checkmark",
            title: "Full disk access",
            description: "Lets Purge find caches and junk across your entire Mac. Without this, scanning is limited.",
            badgeText: "Required",
            badgeTone: .accent,
            isGranted: store.hasFullDiskAccess
          )
          .contentShape(Rectangle())
          .onTapGesture(perform: requestFullDiskAccess)
          .accessibilityAddTraits(.isButton)

          if didOpenFullDiskAccessSettings && !store.hasFullDiskAccess {
            Text("We opened System Settings. Find Purge in the list and toggle it on, then come back here.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, AppStyle.Spacing.small)
              .transition(.opacity)
          }
        }
        .onboardingBlurIn(index: 0)

        OnboardingPermissionRow(
          symbol: "power",
          title: "Login item",
          description: "Keeps Purge running quietly in the background so it's always working for you.",
          badgeText: "Optional",
          badgeTone: .neutral,
          isGranted: loginItemRegistered,
          statusText: loginItemFailed ? "Not enabled" : nil
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: enableLoginItem)
        .accessibilityAddTraits(.isButton)
        .onboardingBlurIn(index: 1)
      }
      .frame(maxWidth: .infinity)

      if !store.hasFullDiskAccess {
        Text("Full Disk Access is required before your first scan.")
          .font(.caption)
          .foregroundStyle(AppStyle.warning)
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
    openFullDiskAccessSettings()
    refreshFullDiskAccess()
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
      await MainActor.run {
        refreshFullDiskAccess()
      }

      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        break
      }
    }
  }

  private func refreshFullDiskAccess() {
    withAnimation(.easeInOut(duration: 0.2)) {
      store.refreshPermission()
    }
  }
}
