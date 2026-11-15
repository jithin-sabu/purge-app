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
    /// Large Files only: the size and last-used filters the count was taken under.
    /// Absent in records saved before it existed, which are shown as they were.
    var largeFileFilter: LargeFileFilterSnapshot? = nil
    /// Large Files only: how many files of each kind the count holds, and their size,
    /// for the tab to show while it scans again (#283). Kinds and totals, never a
    /// file name. Absent in records saved before it existed.
    var largeFileCategories: [LargeFileCategoryTotal]? = nil

    /// One kind of large file in a record. The kind is kept by its raw name, so a
    /// record from a build with a kind this one lacks still reads.
    struct LargeFileCategoryTotal: Codable, Equatable, Sendable {
        var category: String
        var count: Int
        var bytes: Int64
    }

    /// Per-kind totals of `files`, in the order the tab's chips use.
    static func largeFileCategoryTotals(of files: [LargeFile]) -> [LargeFileCategoryTotal] {
        var counts: [LargeFileCategory: (count: Int, bytes: Int64)] = [:]
        for file in files {
            let current = counts[file.category] ?? (0, 0)
            counts[file.category] = (current.count + 1, current.bytes + file.sizeBytes)
        }
        return LargeFileCategory.allCases.compactMap { category in
            guard let total = counts[category] else { return nil }
            return LargeFileCategoryTotal(category: category.rawValue, count: total.count, bytes: total.bytes)
        }
    }

    /// Takes `removed` files back off the per-kind totals; a kind left with none goes.
    /// The tuple is in the store's own order: a reordered tuple array is converted
    /// at run time and that cast fails.
    mutating func removeLargeFiles(_ removed: [(bytes: Int64, category: LargeFileCategory)]) {
        guard var categories = largeFileCategories else { return }
        for file in removed {
            guard let index = categories.firstIndex(where: { $0.category == file.category.rawValue }) else { continue }
            categories[index].count = max(0, categories[index].count - 1)
            categories[index].bytes = max(0, categories[index].bytes - file.bytes)
        }
        largeFileCategories = categories.filter { $0.count > 0 }
    }
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
