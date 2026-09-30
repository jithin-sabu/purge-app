import Foundation

/// The last finished scan of one Overview category: when it finished and what it
/// found. Kept across launches so the Overview has real figures to show for a
/// category that was not rescanned at launch, dated so nobody mistakes them for live.
nonisolated struct ScanRecord: Codable, Equatable, Sendable {
    var completedAt: Date
    var bytes: Int64
    var count: Int
    /// App Caches and Dev Tools only: how much of it is safe to clean, the one
    /// figure their Overview rows show. Absent in records saved before it existed.
    var safeBytes: Int64? = nil
}

nonisolated struct ScanRecordStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(for category: OverviewCategory) -> String {
        "overview.scanRecord.\(category.rawValue)"
    }

    func record(for category: OverviewCategory) -> ScanRecord? {
        guard let data = defaults.data(forKey: Self.key(for: category)) else { return nil }
        return try? JSONDecoder().decode(ScanRecord.self, from: data)
    }

    func allRecords() -> [OverviewCategory: ScanRecord] {
        var records: [OverviewCategory: ScanRecord] = [:]
        for category in OverviewCategory.allCases {
            records[category] = record(for: category)
        }
        return records
    }

    func save(_ record: ScanRecord, for category: OverviewCategory) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key(for: category))
    }
}
