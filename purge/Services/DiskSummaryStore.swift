import Combine
import Foundation
import SwiftUI

@MainActor
final class DiskSummaryStore: ObservableObject {
    @Published private(set) var totalDiskBytes: Int64 = 0
    @Published private(set) var usedDiskBytes: Int64 = 0
    @Published private(set) var freeDiskBytes: Int64 = 0

    init() {
        refresh()
    }

    func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return }

        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        totalDiskBytes = total
        freeDiskBytes = free
        usedDiskBytes = max(0, total - free)
    }
}
