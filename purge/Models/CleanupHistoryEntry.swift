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
    /// Sum of the sizes of items moved to the trash. Pending, not reclaimed.
    let bytesMovedToTrash: Int64
    /// Measured volume delta, present only when it was actually measured and cleared
    /// measurement noise. `nil` means unmeasured and must render as unknown: never
    /// substitute `bytesMovedToTrash` here.
    let bytesReclaimedOnVolume: Int64?
    let deletedItems: [CleanupHistoryDeletedItemDTO]
    let skippedItems: [CleanupHistorySkippedItemDTO]

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        trigger: CleanupTrigger,
        bytesMovedToTrash: Int64,
        bytesReclaimedOnVolume: Int64? = nil,
        deletedItems: [CleanupHistoryDeletedItemDTO],
        skippedItems: [CleanupHistorySkippedItemDTO] = []
    ) {
        self.id = id
        self.date = date
        self.trigger = trigger
        self.bytesMovedToTrash = bytesMovedToTrash
        self.bytesReclaimedOnVolume = bytesReclaimedOnVolume
        self.deletedItems = deletedItems
        self.skippedItems = skippedItems
    }

    enum CodingKeys: String, CodingKey {
        case id, date, trigger, bytesMovedToTrash, bytesReclaimedOnVolume, deletedItems, skippedItems
        /// Pre-measurement field. Held a sum of moved sizes that was labelled as freed
        /// space, so it decodes into `bytesMovedToTrash` and never into reclaimed.
        case totalFreedBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.date = try container.decode(Date.self, forKey: .date)
        self.trigger = try container.decode(CleanupTrigger.self, forKey: .trigger)
        if let moved = try container.decodeIfPresent(Int64.self, forKey: .bytesMovedToTrash) {
            self.bytesMovedToTrash = moved
        } else {
            self.bytesMovedToTrash = try container.decode(Int64.self, forKey: .totalFreedBytes)
        }
        self.bytesReclaimedOnVolume = try container.decodeIfPresent(Int64.self, forKey: .bytesReclaimedOnVolume)
        self.deletedItems = try container.decode([CleanupHistoryDeletedItemDTO].self, forKey: .deletedItems)
        self.skippedItems = try container.decodeIfPresent([CleanupHistorySkippedItemDTO].self, forKey: .skippedItems) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(bytesMovedToTrash, forKey: .bytesMovedToTrash)
        try container.encodeIfPresent(bytesReclaimedOnVolume, forKey: .bytesReclaimedOnVolume)
        try container.encode(deletedItems, forKey: .deletedItems)
        try container.encode(skippedItems, forKey: .skippedItems)
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
