import SwiftUI

/// The one place Purge asks for Full Disk Access.
///
/// Purge works without it (see `ScanAccess`), so this is an offer, not a gate:
/// it says what the permission unlocks, what Purge will not do with it, and has
/// a real way out. Onboarding shows it after the first clean; the main window
/// shows it as a sheet from the sidebar notice and the locked tabs.
struct LookDeeperView: View {
  enum Context {
    /// Last onboarding step. `didClean` is false when the user went to review
    /// the list instead of cleaning, so the opening line can't say "That was".
    case onboarding(didClean: Bool)
    /// A sheet in the main window.
    case sheet
  }

  let context: Context
  /// "Not now". Onboarding finishes; the sheet closes.
  let onNotNow: () -> Void
  /// Called once, when access flips to granted while this is on screen.
  let onGranted: () -> Void

  @EnvironmentObject private var store: PurgeStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var didOpenSettings = false
  @State private var didReportGrant = false

  static let contentWidth: CGFloat = 620

  var body: some View {
    VStack(spacing: AppStyle.Spacing.large) {
      VStack(spacing: AppStyle.Spacing.small) {
        OnboardingStepTitle(text: "Want Purge to look deeper?")
          .onboardingBlurIn(index: 0)

        Text(leadText)
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .onboardingBlurIn(index: 1)
      }

      HStack(alignment: .top, spacing: AppStyle.Spacing.small) {
        LookDeeperListCard(title: "What's in there", rows: [
          .init(symbol: "square.stack.3d.up", text: "Caches from App Store apps"),
          .init(symbol: "arrow.down.circle", text: "Big forgotten files in Downloads, Documents and Desktop"),
          .init(symbol: "shippingbox", text: "Bits left behind by apps you've already deleted"),
        ])
        LookDeeperListCard(title: "What Purge won't do", rows: [
          .init(symbol: "hand.raised", text: "Delete anything unless you ask. Large files are only ever shown to you."),
          .init(symbol: "desktopcomputer", text: "Send your files anywhere. Everything stays on your Mac."),
          .init(symbol: "trash", text: "Skip the Trash. Anything Purge removes can be put back."),
        ])
      }
      .onboardingBlurIn(index: 2)

      Text("Apple calls this switch Full Disk Access. The name sounds bigger than it is. It's the only way macOS lets an app see these folders, and you can turn it off in System Settings whenever you want.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .onboardingBlurIn(index: 3)

      VStack(spacing: AppStyle.Spacing.small) {
        OnboardingPrimaryButton(title: "Let Purge in", systemImage: "arrow.up.forward", action: letPurgeIn)
        OnboardingSecondaryButton(title: "Not now", action: onNotNow)
          .keyboardShortcut(.cancelAction)

        if didOpenSettings {
          Text("System Settings is open. Turn on Purge under Full Disk Access, then come back here. If macOS offers to quit and reopen Purge, go ahead.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
        }
      }
      .onboardingBlurIn(index: 4)
    }
    .frame(maxWidth: Self.contentWidth)
    .task { await pollUntilGranted() }
  }

  private var leadText: String {
    switch context {
    case .onboarding(didClean: true):
      return "That was the easy stuff. macOS keeps a few folders locked, and a lot of clutter tends to hide in them."
    case .onboarding(didClean: false), .sheet:
      return "So far Purge has only looked in the easy places. macOS keeps a few folders locked, and a lot of clutter tends to hide in them."
    }
  }

  private func letPurgeIn() {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      didOpenSettings = true
    }
    openFullDiskAccessSettings()
  }

  /// macOS grants access to a running process without telling it, so the only way
  /// to notice is to keep probing. Off the main actor, and only while on screen.
  private func pollUntilGranted() async {
    while !Task.isCancelled {
      let granted = await store.probeFullDiskAccess()
      if granted != store.hasFullDiskAccess {
        store.applyFullDiskAccess(granted)
      }
      if granted, !didReportGrant {
        didReportGrant = true
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

private struct LookDeeperListCard: View {
  struct Row: Identifiable {
    let symbol: String
    let text: String
    var id: String { text }
  }

  let title: String
  let rows: [Row]

  var body: some View {
    VStack(alignment: .leading, spacing: AppStyle.Spacing.small) {
      Text(title)
        .font(.subheadline.weight(.semibold))

      ForEach(rows) { row in
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.Spacing.xSmall) {
          Image(systemName: row.symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .accessibilityHidden(true)
          Text(row.text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(AppStyle.Spacing.medium)
    .background(AppColors.bgCard, in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
        .stroke(AppColors.borderSubtle)
    }
    .accessibilityElement(children: .combine)
  }
}

/// `LookDeeperView` as a sheet over the main window.
struct LookDeeperSheet: View {
  @EnvironmentObject private var store: PurgeStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    LookDeeperView(
      context: .sheet,
      onNotNow: { dismiss() },
      onGranted: {
        dismiss()
        Task { await store.scanAll() }
      }
    )
    .padding(.horizontal, OnboardingLayout.horizontalPadding)
    .padding(.vertical, OnboardingLayout.verticalPadding)
    .frame(width: LookDeeperView.contentWidth + OnboardingLayout.horizontalPadding * 2)
    .background(AppColors.bgBase)
  }
}

#Preview {
  LookDeeperView(context: .onboarding(didClean: true), onNotNow: {}, onGranted: {})
    .environmentObject(PurgeStore())
    .padding(40)
    .frame(width: AppWindowLayout.width, height: AppWindowLayout.minHeight)
}
