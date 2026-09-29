import SwiftUI

/// The one place Purge asks for Full Disk Access.
///
/// Purge works without it (see `ScanAccess`), so this is an offer, not a gate:
/// it says what the permission unlocks, what Purge will not do with it, and has
/// a real way out. Onboarding shows it after the first clean; the main window
/// shows it as a sheet from the sidebar notice and the locked tabs.
///
/// When access lands while it is on screen, the same view runs the deeper scan
/// and shows what the permission found, right where the user said yes.
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
  /// After the reveal, when the user moves on.
  let onFinished: () -> Void
  /// When "Let Purge in" opens System Settings.
  var onOpenSettings: () -> Void = {}

  private enum Phase {
    case asking
    case scanning
    case revealed(LockedPlacesFindings)
  }

  @EnvironmentObject private var store: PurgeStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var phase: Phase = .asking
  @State private var didOpenSettings = false

  static let contentWidth: CGFloat = 620
  /// Long enough to read "Looking deeper" even when the scan is instant.
  private static let minimumScanDuration: Duration = .milliseconds(1500)

  var body: some View {
    Group {
      switch phase {
      case .asking:
        askingBody
      case .scanning:
        scanningBody
      case .revealed(let findings):
        revealedBody(findings)
      }
    }
    .frame(maxWidth: Self.contentWidth)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: phaseKey)
    .task { await pollUntilGranted() }
  }

  /// `Phase` carries findings that are not `Equatable`; the animation only needs
  /// to know which screen is up.
  private var phaseKey: Int {
    switch phase {
    case .asking: return 0
    case .scanning: return 1
    case .revealed: return 2
    }
  }

  private var askingBody: some View {
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

      // What access unlocks, as tiles, then what Purge promises, as one quiet row.
      // Each promise is something Purge does, not a limit on the permission:
      // Full Disk Access itself can read and write, so "can't" would not be true.
      HStack(spacing: AppStyle.Spacing.small) {
        LookDeeperTile(symbol: "square.stack.3d.up", text: "App Store app caches")
        LookDeeperTile(symbol: "doc.text.magnifyingglass", text: "Big forgotten files")
        LookDeeperTile(symbol: "shippingbox", text: "Deleted apps' leftovers")
      }
      .onboardingBlurIn(index: 2)

      VStack(spacing: AppStyle.Spacing.small) {
        HStack(spacing: AppStyle.Spacing.large) {
          LookDeeperPromise(symbol: "eye", text: "Only cleans when you say")
          LookDeeperPromise(symbol: "icloud.slash", text: "Nothing leaves your Mac")
          LookDeeperPromise(symbol: "trash", text: "Everything goes to the Trash")
        }

        Text("macOS calls this Full Disk Access. Turn it off anytime in System Settings.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .onboardingBlurIn(index: 3)

      VStack(spacing: AppStyle.Spacing.small) {
        OnboardingPrimaryButton(title: "Let Purge in", systemImage: "arrow.up.forward", action: letPurgeIn)
        OnboardingSecondaryButton(title: "Not now", action: onNotNow)
          .keyboardShortcut(.cancelAction)

        if didOpenSettings {
          Text("Turn on Purge in System Settings, then come back. If macOS offers to reopen Purge, go ahead.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
        }
      }
      .onboardingBlurIn(index: 4)
    }
    .transition(OnboardingTransitions.stepTransition(reduceMotion: reduceMotion))
  }

  private var scanningBody: some View {
    VStack(spacing: AppStyle.Spacing.small) {
      OnboardingLoadingStepTitle(baseText: "Looking deeper")
      Text("Checking the places that were locked.")
        .font(.title3)
        .foregroundStyle(.secondary)
    }
    .transition(OnboardingTransitions.stepTransition(reduceMotion: reduceMotion))
  }

  @ViewBuilder
  private func revealedBody(_ findings: LockedPlacesFindings) -> some View {
    VStack(spacing: AppStyle.Spacing.large) {
      if findings.isWorthLeadingWith {
        VStack(spacing: 0) {
          Text(formatBytes(findings.bytes))
            .font(.system(size: 56, weight: .bold, design: .rounded))
            .monospacedDigit()
          Text("more to clean, from places that were locked")
            .font(.title2.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .onboardingBlurIn(index: 0)

        VStack(alignment: .leading, spacing: AppStyle.Spacing.xSmall) {
          ForEach(Array(findings.categories.enumerated()), id: \.element.id) { index, category in
            OnboardingResultsCategoryRow(
              symbol: category.symbol,
              title: category.title,
              formattedSize: formatBytes(category.bytes)
            )
            .onboardingBlurIn(index: index + 1)
          }
        }
        .frame(maxWidth: 300)

        Text("Large Files and the uninstaller are open now too.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .onboardingBlurIn(index: findings.categories.count + 1)
      } else {
        OnboardingStepTitle(text: "Purge can see everything now")
          .onboardingBlurIn(index: 0)
        Text(Self.smallFindingsMessage(findings))
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .onboardingBlurIn(index: 1)
      }

      OnboardingPrimaryButton(title: findings.isWorthLeadingWith ? "Show me" : "Continue") {
        finish(with: findings)
      }
      .padding(.top, AppStyle.Spacing.small)
    }
    .transition(OnboardingTransitions.stepTransition(reduceMotion: reduceMotion))
  }

  static func smallFindingsMessage(_ findings: LockedPlacesFindings) -> String {
    if findings.isPartial {
      return "Large Files and the uninstaller are ready. Purge is still checking your projects, so more may turn up."
    }
    return findings.bytes > 0
      ? "Large Files and the uninstaller are ready, and Purge found a little more to clean too."
      : "Large Files and the uninstaller are ready. Nothing big was hiding in the locked folders."
  }

  private var leadText: String {
    switch context {
    case .onboarding(didClean: true):
      return "That was the easy part. More clutter hides in folders macOS keeps locked."
    case .onboarding(didClean: false), .sheet:
      return "Some clutter hides in folders macOS keeps locked."
    }
  }

  private func letPurgeIn() {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      didOpenSettings = true
    }
    onOpenSettings()
    openFullDiskAccessSettings()
  }

  /// In onboarding, "Show me" lands on the tab that holds most of what was found.
  private func finish(with findings: LockedPlacesFindings) {
    if case .onboarding = context, findings.isWorthLeadingWith {
      store.selectedTab = findings.categories.first?.title == PurgeStore.devArtifactCategoryTitle
        ? .devTools
        : .appCaches
    }
    onFinished()
  }

  /// macOS grants access to a running process without telling it, so the only way
  /// to notice is to keep probing. Off the main actor, and only while on screen.
  /// Also covers a relaunch: if access is already on when this appears, the
  /// reveal starts straight away.
  private func pollUntilGranted() async {
    while !Task.isCancelled {
      let granted = await store.probeFullDiskAccess()
      if granted != store.hasFullDiskAccess {
        store.applyFullDiskAccess(granted)
      }
      if granted {
        await revealDeeperScan()
        return
      }
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
    }
  }

  private func revealDeeperScan() async {
    // Claim the grant so the sidebar does not announce it a second time.
    store.consumeFullDiskAccessGrant()
    phase = .scanning
    let started = ContinuousClock.now
    let findings = await store.scanLockedPlaces()
    let remaining = Self.minimumScanDuration - (ContinuousClock.now - started)
    if remaining > .zero {
      try? await Task.sleep(for: remaining)
    }
    guard !Task.isCancelled else { return }
    phase = .revealed(findings)
  }
}

/// One thing access unlocks: an icon over two or three words.
private struct LookDeeperTile: View {
  let symbol: String
  let text: String

  var body: some View {
    VStack(spacing: AppStyle.Spacing.xSmall) {
      Image(systemName: symbol)
        .font(.system(size: 20, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .accessibilityHidden(true)
      Text(text)
        .font(.callout)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 88)
    .padding(.horizontal, AppStyle.Spacing.small)
    .background(AppColors.bgCard, in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous)
        .stroke(AppColors.borderSubtle)
    }
    .accessibilityElement(children: .combine)
  }
}

/// One promise: a small icon and a few words, in a single row with the others.
private struct LookDeeperPromise: View {
  let symbol: String
  let text: String

  var body: some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: symbol)
        .accessibilityHidden(true)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .fixedSize()
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
      onFinished: { dismiss() }
    )
    .padding(.horizontal, OnboardingLayout.horizontalPadding)
    .padding(.vertical, OnboardingLayout.verticalPadding)
    .frame(width: LookDeeperView.contentWidth + OnboardingLayout.horizontalPadding * 2)
    .background(AppColors.bgBase)
  }
}

#Preview {
  LookDeeperView(context: .onboarding(didClean: true), onNotNow: {}, onFinished: {})
    .environmentObject(PurgeStore())
    .padding(40)
    .frame(width: AppWindowLayout.width, height: AppWindowLayout.minHeight)
}
