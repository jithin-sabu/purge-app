import Foundation

struct DeletedItem: Identifiable {
    let id: UUID
    let path: String
    let sizeBytes: Int64
    /// Friendly label from the main list (e.g. explanation headline); nil if unknown.
    let displayName: String?

    init(path: String, sizeBytes: Int64, displayName: String? = nil) {
        self.id = UUID()
        self.path = path
        self.sizeBytes = sizeBytes
        self.displayName = displayName
    }
}

struct FailedDeletionItem: Identifiable {
    let id = UUID()
    let path: String
    let reason: String
}

struct SkippedDeletionItem: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let reason: String
    /// `true` when the user should see a "skipped for safety" notice.
    /// `false` for silent never-delete blocks.
    let isUserVisible: Bool
}

struct DeletionReport: Identifiable {
    let id = UUID()
    let totalDeleted: Int64
    let deletedItems: [DeletedItem]
    let failedItems: [FailedDeletionItem]
    let skippedItems: [SkippedDeletionItem]
    let volumeCapacity: Int64
    let availableCapacityBefore: Int64
    let availableCapacityAfter: Int64
    let timestamp: Date

    var actualFreedBytes: Int64 {
        max(0, availableCapacityAfter - availableCapacityBefore)
    }

    var hasUserVisibleSkips: Bool {
        skippedItems.contains { $0.isUserVisible }
    }
}

final class FileDeleter {
    private let scanner = CacheScanner()
    private(set) var deletionLog: [DeletionReport] = []

    /// - Parameter pathToDisplayName: Keys should be standardized file paths (`URL.standardizedFileURL.path`).
    func deleteItems(at urls: [URL], pathToDisplayName: [String: String] = [:]) async throws -> DeletionReport {
        var totalDeleted: Int64 = 0
        var deletedItems: [DeletedItem] = []
        var failedItems: [FailedDeletionItem] = []
        var skippedItems: [SkippedDeletionItem] = []
        let volumeURL = FileManager.default.homeDirectoryForCurrentUser
        let capacityBefore = volumeCapacitySnapshot(for: volumeURL)

        for url in urls {
            let standardizedPath = url.standardizedFileURL.path
            let friendlyTitle = pathToDisplayName[standardizedPath]
            let decision = DeletionSafetyPolicy.evaluate(url)
            switch decision {
            case .allow:
                let size = scanner.calculateFolderSize(at: url)
                do {
                    try FileManager.default.removeItem(at: url)
                    totalDeleted += size
                    deletedItems.append(DeletedItem(path: url.path, sizeBytes: size, displayName: friendlyTitle))
                } catch {
                    failedItems.append(FailedDeletionItem(path: url.path, reason: error.localizedDescription))
                }

            case .blockedNeverDelete, .blockedNotWhitelisted:
                let reason = decision.skipReason ?? "Skipped for safety"
                skippedItems.append(
                    SkippedDeletionItem(
                        path: url.path,
                        reason: reason,
                        isUserVisible: decision.isUserVisibleSkip
                    )
                )
            }
        }

        let capacityAfter = volumeCapacitySnapshot(for: volumeURL)
        let report = DeletionReport(
            totalDeleted: totalDeleted,
            deletedItems: deletedItems,
            failedItems: failedItems,
            skippedItems: skippedItems,
            volumeCapacity: capacityAfter.total,
            availableCapacityBefore: capacityBefore.available,
            availableCapacityAfter: capacityAfter.available,
            timestamp: Date()
        )
        deletionLog.append(report)
        return report
    }

    private func volumeCapacitySnapshot(for url: URL) -> (total: Int64, available: Int64) {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (
            Int64(values?.volumeTotalCapacity ?? 0),
            Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }
}
