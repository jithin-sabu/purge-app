import SwiftUI

struct OnboardingFirstScanStep: View {
  @EnvironmentObject private var store: PurgeStore
  @ObservedObject var revealController: OnboardingScanRevealController

  let onScanComplete: () -> Void

  @State private var scanStarted = false

  private static let rowInsertionTransition: AnyTransition = .asymmetric(
    insertion: .opacity.combined(with: .offset(y: 8)),
    removal: .opacity
  )

  var body: some View {
    VStack(alignment: .center, spacing: AppStyle.Spacing.medium) {
      OnboardingStepTitle(text: "Running your first scan.")

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
            .transition(Self.rowInsertionTransition)
          }
        }
        .padding(.bottom, AppStyle.Spacing.xSmall)
        .animation(.easeOut(duration: 0.45), value: revealController.revealedItems.count)
      }
      .accessibilityLabel("Items found, \(revealController.revealedItems.count)")

      Spacer(minLength: 0)
    }
    .frame(maxWidth: OnboardingLayout.contentMaxWidth, maxHeight: .infinity, alignment: .top)
    .onAppear {
      guard !scanStarted else { return }
      scanStarted = true
      Task { await store.scanAll() }
      revealController.startReveal(
        itemProvider: { store.onboardingScanFindings() },
        scanFinished: {
          !store.isScanningAll && !store.isEnrichingGeneral && !store.isEnrichingDeveloper
        },
        onReadyForResults: onScanComplete
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
}
