import Combine
import Foundation

@MainActor
final class CleanupHistoryStore: ObservableObject {
    static let shared = CleanupHistoryStore()

    private static let filename = "cleanup_history.json"
    private let maxEntries = 100

    @Published private(set) var archive: CleanupHistoryFile

    init() {
        let url = Self.applicationSupportFileURL()
        archive = CleanupHistoryStore.load(from: url) ?? CleanupHistoryFile()
    }

    private static func applicationSupportFileURL() -> URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("io.getpurge.app", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        if !FileManager.default.fileExists(atPath: baseDir.path) {
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }
        return baseDir.appendingPathComponent(Self.filename, isDirectory: false)
    }

    private static func load(from url: URL) -> CleanupHistoryFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CleanupHistoryFile.self, from: data)
    }

    private func persist() {
        let url = Self.applicationSupportFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(archive) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    func append(trigger: CleanupTrigger, report: DeletionReport) {
        let items = report.deletedItems.map {
            CleanupHistoryDeletedItemDTO(path: $0.path, sizeBytes: $0.sizeBytes)
        }

        let skipped = report.skippedItems.map {
            CleanupHistorySkippedItemDTO(path: $0.path, reason: $0.reason, isUserVisible: $0.isUserVisible)
        }

        // Reclaimed is recorded only when the volume actually moved. A clean that only
        // trashes files reclaims nothing until the trash is emptied, so this is
        // usually nil, and that is the honest answer.
        let entry = CleanupHistoryEntry(
            date: report.timestamp,
            trigger: trigger,
            bytesMovedToTrash: report.bytesMovedToTrash,
            bytesReclaimedOnVolume: report.reportableBytesReclaimedOnVolume,
            deletedItems: items,
            skippedItems: skipped
        )
        archive.append(entry, maxEntries: maxEntries)
        persist()
    }

    func clear() {
        archive.clear()
        persist()
    }
}
