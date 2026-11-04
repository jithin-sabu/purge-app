import Combine
import Foundation
import SwiftUI

@MainActor
final class OnboardingScanRevealController: ObservableObject {
  @Published private(set) var revealedItems: [OnboardingScanFinding] = []
  @Published private(set) var simulatedProgress: Double = 0
  @Published private(set) var sourceScanFinished = false

  private var revealTask: Task<Void, Never>?

  /// Discovered findings keyed by stable id (file path, or category+source
  /// fallback). A repeat emission overwrites the existing entry instead of
  /// queueing a duplicate row.
  private var bufferedByID: [String: OnboardingScanFinding] = [:]
  /// Discovery order of stable ids, so revealed rows keep a stable sequence.
  private var bufferOrder: [String] = []
  /// Stable ids already published into `revealedItems`.
  private var revealedIDs: Set<String> = []

  /// Cadence between revealing one buffered item and the next. Paces the
  /// streaming list so rows stagger in rather than appearing all at once.
  private static let revealIntervalNanoseconds: UInt64 = 550_000_000
  /// Poll interval while waiting for the scan to surface more items.
  private static let idlePollNanoseconds: UInt64 = 200_000_000

  func startReveal(
    itemProvider: @escaping () -> [OnboardingScanFinding],
    scanFinished: @escaping () -> Bool,
    onReadyForResults: @escaping () -> Void
  ) {
    cancel()
    revealedItems = []
    simulatedProgress = 0
    sourceScanFinished = false
    bufferedByID = [:]
    bufferOrder = []
    revealedIDs = []

    revealTask = Task {
      while !Task.isCancelled {
        // Fold the latest snapshot into the dedup buffer. Reveal happens on our
        // own cadence below, so the published array changes at most once per
        // tick — never per raw discovered item.
        ingest(itemProvider())

        if let next = nextUnrevealedID() {
          revealItem(id: next)
          try? await Task.sleep(nanoseconds: Self.revealIntervalNanoseconds)
          continue
        }

        if scanFinished() {
          withAnimation(.easeInOut(duration: 0.4)) {
            simulatedProgress = 1
          }
          onReadyForResults()
          return
        }

        try? await Task.sleep(nanoseconds: Self.idlePollNanoseconds)
      }
    }
  }

  /// Deduplicates the latest snapshot into the buffer by stable id.
  private func ingest(_ items: [OnboardingScanFinding]) {
    for item in items {
      if bufferedByID[item.id] == nil {
        bufferOrder.append(item.id)
      }
      bufferedByID[item.id] = item
    }
  }

  private func nextUnrevealedID() -> String? {
    bufferOrder.first { !revealedIDs.contains($0) }
  }

  /// Publishes a single buffered item and moves the progress bar on.
  private func revealItem(id: String) {
    guard let item = bufferedByID[id] else { return }
    revealedIDs.insert(id)

    withAnimation(.easeOut(duration: 0.4)) {
      revealedItems.append(item)
    }
    withAnimation(.linear(duration: 0.55)) {
      simulatedProgress = Self.progress(afterRevealingFrom: simulatedProgress)
    }
  }

  /// The bar never fills while the scan runs: only `scanFinished` sets 1.
  nonisolated static let runningProgressCeiling = 0.9

  /// Where the bar goes when a row is revealed while the scan runs. It used to
  /// go to the share of found rows already shown. The reveal catches up with
  /// the scan after the first row, so that share was 1 and the bar sat full
  /// while the scan went on (#183). Each row now closes part of the gap to
  /// `runningProgressCeiling`: about two thirds of the way after 8 rows.
  nonisolated static func progress(afterRevealingFrom current: Double) -> Double {
    current + (runningProgressCeiling - current) * 0.12
  }

  func markSourceScanFinished() {
    sourceScanFinished = true
  }

  func cancel() {
    revealTask?.cancel()
    revealTask = nil
  }

  deinit {
    revealTask?.cancel()
  }
}
