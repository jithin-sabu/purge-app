import SwiftUI

struct OnboardingCleaningStep: View {
  @EnvironmentObject private var store: PurgeStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let pinnedCandidates: [PurgeStore.DeletionCandidate]
  let onFinished: (Int64) -> Void

  @State private var visibleItems: [OnboardingScanFinding] = []
  @State private var cleaningStarted = false
  @State private var initialItemCount = 0

  var body: some View {
    VStack(alignment: .center, spacing: AppStyle.Spacing.medium) {
      OnboardingStepTitle(text: "Cleaning safe items…")

      OnboardingProgressBar(progress: cleaningProgress)
        .padding(.bottom, AppStyle.Spacing.xSmall)
        .frame(maxWidth: .infinity)

      OnboardingFadingScrollView(maxHeight: OnboardingLayout.scrollingListMaxHeight) {
        VStack(spacing: 8) {
          ForEach(visibleItems) { item in
            ScanListRow(
              icon: .symbol("folder.fill"),
              title: item.title,
              subtitle: nil,
              formattedSize: item.formattedSize,
              primaryBadgeText: nil
            )
            .transition(OnboardingTransitions.listRowRemoval(reduceMotion: reduceMotion))
          }
        }
        .padding(.bottom, AppStyle.Spacing.xSmall)
        .animation(.easeInOut(duration: 0.45), value: visibleItems.count)
      }
      .accessibilityLabel("Items being cleaned, \(visibleItems.count)")

      Spacer(minLength: 0)
    }
    .frame(maxWidth: OnboardingLayout.contentMaxWidth, maxHeight: .infinity, alignment: .top)
    .onAppear {
      guard !cleaningStarted else { return }
      cleaningStarted = true
      let items = Self.findings(from: pinnedCandidates)
      initialItemCount = items.count
      visibleItems = items
      Task { await runCleaning() }
    }
  }

  private var cleaningProgress: Double {
    guard initialItemCount > 0 else { return store.isDeleting ? 0.5 : 1 }
    let cleared = initialItemCount - visibleItems.count
    return Double(cleared) / Double(initialItemCount)
  }

  private func runCleaning() async {
    let expectedFreedBytes = pinnedCandidates.reduce(Int64(0)) { $0 + $1.sizeBytes }

    async let cleanTask = store.performManualSafeCleanNow(pinnedCandidates: pinnedCandidates)

    for _ in pinnedCandidates.indices {
      try? await Task.sleep(nanoseconds: 380_000_000)
      guard !visibleItems.isEmpty else { continue }
      withAnimation(.easeInOut(duration: 0.4)) {
        visibleItems.removeFirst()
      }
    }

    let summary = await cleanTask
    withAnimation(.easeInOut(duration: 0.3)) {
      visibleItems = []
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    onFinished(summary.freedBytes > 0 ? summary.freedBytes : expectedFreedBytes)
  }

  private static func findings(from candidates: [PurgeStore.DeletionCandidate]) -> [OnboardingScanFinding] {
    candidates.map { OnboardingScanFinding(title: $0.title, formattedSize: $0.formattedSize) }
  }
}
