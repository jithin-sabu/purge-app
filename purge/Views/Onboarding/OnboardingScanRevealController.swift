import Combine
import Foundation
import SwiftUI

@MainActor
final class OnboardingScanRevealController: ObservableObject {
  @Published private(set) var revealedItems: [OnboardingScanFinding] = []
  @Published private(set) var simulatedProgress: Double = 0
  @Published private(set) var isRevealComplete = false
  @Published private(set) var sourceScanFinished = false

  private var revealTask: Task<Void, Never>?

  func startReveal(
    itemProvider: @escaping () -> [OnboardingScanFinding],
    scanFinished: @escaping () -> Bool,
    onReadyForResults: @escaping () -> Void
  ) {
    cancel()
    revealedItems = []
    simulatedProgress = 0
    isRevealComplete = false
    sourceScanFinished = false

    revealTask = Task {
      var queueIndex = 0

      while !Task.isCancelled {
        let realItems = itemProvider()

        if queueIndex < realItems.count {
          let next = realItems[queueIndex]
          let targetProgress = min(1, Double(queueIndex + 1) / Double(max(realItems.count, 1)))
          withAnimation(.easeOut(duration: 0.4)) {
            revealedItems.append(next)
          }
          withAnimation(.linear(duration: 0.55)) {
            simulatedProgress = targetProgress
          }
          queueIndex += 1
          try? await Task.sleep(nanoseconds: 550_000_000)
          continue
        }

        if scanFinished() {
          withAnimation(.easeInOut(duration: 0.4)) {
            simulatedProgress = 1
          }
          isRevealComplete = true
          onReadyForResults()
          return
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
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
