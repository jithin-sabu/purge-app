import SwiftUI

struct OnboardingFirstScanStep: View {
  @EnvironmentObject private var store: PurgeStore
  @ObservedObject var revealController: OnboardingScanRevealController

  let onScanComplete: () -> Void

  @State private var scanStarted = false
  @State private var scanBeganAt = Date()

  private static let minimumScanDuration: TimeInterval = 2
  private static let rowInsertionTransition: AnyTransition = .asymmetric(
    insertion: .opacity.combined(with: .offset(y: 8)),
    removal: .opacity
  )

  var body: some View {
    VStack(alignment: .center, spacing: AppStyle.Spacing.medium) {
      OnboardingLoadingStepTitle(baseText: "Running your first scan")

      OnboardingProgressBar(progress: combinedProgress)
        .padding(.bottom, AppStyle.Spacing.xSmall)
        .frame(maxWidth: .infinity)

      OnboardingFadingScrollView(maxHeight: OnboardingLayout.scrollingListMaxHeight) {
        LazyVStack(spacing: 8) {
          ForEach(revealController.revealedItems) { item in
            ScanListRow(
              icon: .symbol("folder.fill"),
              title: item.title,
              subtitle: nil,
              formattedSize: item.formattedSize,
              primaryBadgeText: nil,
              primaryBadgeTone: .neutral
            )
            .frame(height: OnboardingLayout.scanRowHeight)
            .transition(Self.rowInsertionTransition)
          }
        }
        .padding(.bottom, AppStyle.Spacing.xSmall)
      }
      .accessibilityLabel("Items found, \(revealController.revealedItems.count)")

      Spacer(minLength: 0)
    }
    .frame(maxWidth: OnboardingLayout.contentMaxWidth, maxHeight: .infinity, alignment: .top)
    .onAppear {
      guard !scanStarted else { return }
      scanStarted = true
      scanBeganAt = Date()

      Task {
        await store.scanAll()
        revealController.markSourceScanFinished()
      }

      revealController.startReveal(
        itemProvider: { store.onboardingScanFindings() },
        scanFinished: {
          revealController.sourceScanFinished
            && !store.isScanningAll
            && !store.isEnrichingGeneral
            && !store.isEnrichingDeveloper
        },
        onReadyForResults: finishOnboardingScan
      )
    }
    .onDisappear {
      revealController.cancel()
    }
  }

  private var combinedProgress: Double {
    let scanProgress: Double = store.isScanningAll ? 0.65 : 1
    return min(1, max(revealController.simulatedProgress, scanProgress * 0.35 + revealController.simulatedProgress * 0.65))
  }

  private func finishOnboardingScan() {
    Task { @MainActor in
      let remaining = Self.minimumScanDuration - Date().timeIntervalSince(scanBeganAt)
      if remaining > 0 {
        try? await Task.sleep(for: .seconds(remaining))
      }
      guard scanStarted else { return }
      onScanComplete()
    }
  }
}
