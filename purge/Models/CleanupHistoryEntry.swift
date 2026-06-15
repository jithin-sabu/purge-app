import Foundation

enum CleanupTrigger: String, Codable, Hashable {
    case manual
    case scheduled
}

struct CleanupHistoryDeletedItemDTO: Codable, Hashable, Identifiable {
    var id: String { path }

    let path: String
    /// Bytes recorded before deletion.
    let sizeBytes: Int64
}

struct CleanupHistorySkippedItemDTO: Codable, Hashable, Identifiable {
    var id: String { path }

    let path: String
    let reason: String
    let isUserVisible: Bool
}

/// One persisted cleanup session (manual or scheduled).
struct CleanupHistoryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    let date: Date
    let trigger: CleanupTrigger
    let totalFreedBytes: Int64
    let deletedItems: [CleanupHistoryDeletedItemDTO]
    let skippedItems: [CleanupHistorySkippedItemDTO]

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        trigger: CleanupTrigger,
        totalFreedBytes: Int64,
        deletedItems: [CleanupHistoryDeletedItemDTO],
        skippedItems: [CleanupHistorySkippedItemDTO] = []
    ) {
        self.id = id
        self.date = date
        self.trigger = trigger
        self.totalFreedBytes = totalFreedBytes
        self.deletedItems = deletedItems
        self.skippedItems = skippedItems
    }

    enum CodingKeys: String, CodingKey {
        case id, date, trigger, totalFreedBytes, deletedItems, skippedItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.date = try container.decode(Date.self, forKey: .date)
        self.trigger = try container.decode(CleanupTrigger.self, forKey: .trigger)
        self.totalFreedBytes = try container.decode(Int64.self, forKey: .totalFreedBytes)
        self.deletedItems = try container.decode([CleanupHistoryDeletedItemDTO].self, forKey: .deletedItems)
        self.skippedItems = try container.decodeIfPresent([CleanupHistorySkippedItemDTO].self, forKey: .skippedItems) ?? []
    }
}

struct CleanupHistoryFile: Codable {
    /// Newest-first list; capped at entry limit.
    var entries: [CleanupHistoryEntry]

    init(entries: [CleanupHistoryEntry] = []) {
        self.entries = entries
    }

    mutating func append(_ entry: CleanupHistoryEntry, maxEntries: Int) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
    }

    mutating func clear() {
        entries.removeAll()
    }
}
