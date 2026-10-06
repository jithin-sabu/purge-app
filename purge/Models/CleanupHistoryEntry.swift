import Foundation

nonisolated enum CleanupTrigger: String, Codable, Hashable {
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

    enum CodingKeys: String, CodingKey {
        case entries
    }

    /// Skips an entry it cannot read instead of failing the whole file. A failed
    /// file loads as empty and the next clean overwrites it, which would lose every
    /// clean an older version recorded, and those feed the yearly ledger.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .entries)
        var entries: [CleanupHistoryEntry] = []
        while !list.isAtEnd {
            if let entry = try? list.decode(CleanupHistoryEntry.self) {
                entries.append(entry)
            } else if (try? list.decode(SkippedEntry.self)) == nil {
                break
            }
        }
        self.entries = entries
    }

    /// Decodes nothing, which moves the list past an unreadable entry.
    private struct SkippedEntry: Decodable {
        init(from decoder: Decoder) throws {}
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
