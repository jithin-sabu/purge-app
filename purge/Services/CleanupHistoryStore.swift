import Combine
import Foundation

@MainActor
final class CleanupHistoryStore: ObservableObject {
    static let shared = CleanupHistoryStore()

    private static let filename = "cleanup_history.json"
    private let maxEntries = 100

    @Published private(set) var archive: CleanupHistoryFile

    init() {
        let url = Self.fileURL()
        archive = CleanupHistoryStore.load(from: url) ?? CleanupHistoryFile()
    }

    nonisolated static func fileURL() -> URL {
        let baseDir: URL
        if TestHost.isActive() {
            // Tests run inside a hosted copy of the app. A clean a test drives must
            // never reach the user's History, so they get a scratch folder (#171).
            baseDir = TestHost.supportDirectory()
        } else {
            baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("io.getpurge.app", isDirectory: true)
                ?? FileManager.default.temporaryDirectory
        }
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
        let url = Self.fileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(archive) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    func append(id: UUID = UUID(), trigger: CleanupTrigger, report: DeletionReport) {
        archive.append(Self.entry(id: id, trigger: trigger, report: report), maxEntries: maxEntries)
        persist()
    }

    /// The entry a clean's report becomes. Each item keeps whether it went to the
    /// Trash, so History never lists a simulator as moved there (#170).
    static func entry(id: UUID, trigger: CleanupTrigger, report: DeletionReport) -> CleanupHistoryEntry {
        let items = report.deletedItems.map {
            CleanupHistoryDeletedItemDTO(path: $0.path, sizeBytes: $0.sizeBytes, movedToTrash: $0.movedToTrash)
        }

        let skipped = report.skippedItems.map {
            CleanupHistorySkippedItemDTO(path: $0.path, reason: $0.reason, isUserVisible: $0.isUserVisible)
        }

        // Reclaimed is recorded only when the volume actually moved. A clean that only
        // trashes files reclaims nothing until the trash is emptied, so this is
        // usually nil, and that is the honest answer.
        return CleanupHistoryEntry(
            id: id,
            date: report.timestamp,
            trigger: trigger,
            bytesMovedToTrash: report.bytesMovedToTrash,
            bytesReclaimedOnVolume: report.reportableBytesReclaimedOnVolume,
            deletedItems: items,
            skippedItems: skipped
        )
    }

    /// A removal of the Apple Intelligence models (#133). Nothing went to the
    /// Trash: the items carry Apple's figure for each set that went, and
    /// reclaimed is the same measure every other entry uses, the volume's
    /// available space as System Settings shows it, nil unless it cleared the
    /// noise floor. The raw-block delta is not kept here; the row shows it once.
    func appendAppleIntelligenceRemoval(
        sets: [AppleIntelligenceModelSet],
        bytesBefore: AppleIntelligenceReading,
        freedShownBytes: Int64?
    ) {
        let items = sets.map { set -> CleanupHistoryDeletedItemDTO in
            let bytes = bytesBefore.sets.first { $0.set.name == set.name }?.latestBytes ?? 0
            return CleanupHistoryDeletedItemDTO(path: set.title, sizeBytes: bytes)
        }
        let entry = CleanupHistoryEntry(
            trigger: .manual,
            bytesMovedToTrash: 0,
            bytesReclaimedOnVolume: freedShownBytes,
            deletedItems: items,
            kind: .appleIntelligenceModels
        )
        archive.append(entry, maxEntries: maxEntries)
        persist()
    }

    /// A Remove Download run (#106). Nothing went to the Trash: the items are the
    /// files whose downloads went, each with the space it freed here, and the
    /// skipped ones with why. Every file is still in iCloud.
    func appendICloudDownloadRemoval(_ report: ICloudDownloadReport) {
        let entry = CleanupHistoryEntry(
            date: report.date,
            trigger: .manual,
            bytesMovedToTrash: 0,
            deletedItems: report.removed.map {
                CleanupHistoryDeletedItemDTO(path: $0.path, sizeBytes: $0.bytesFreed, movedToTrash: false)
            },
            skippedItems: report.skipped.map {
                CleanupHistorySkippedItemDTO(path: $0.path, reason: $0.reasonKey, isUserVisible: true)
            },
            kind: .iCloudDownloadsRemoved
        )
        archive.append(entry, maxEntries: maxEntries)
        persist()
    }

    func clear() {
        archive.clear()
        persist()
    }
}
