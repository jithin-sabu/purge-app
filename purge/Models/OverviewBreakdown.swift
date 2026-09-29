import Foundation

/// A path Purge found and how much space it takes. A folder counts everything under it.
nonisolated struct OverviewSizedItem: Equatable, Sendable {
    let path: String
    let bytes: Int64

    init(path: String, bytes: Int64) {
        self.path = OverviewSizedItem.normalized(path)
        self.bytes = max(0, bytes)
    }

    static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

/// Where one category's figure comes from.
nonisolated enum OverviewCategorySource: Equatable, Sendable {
    /// Results from this session, itemised so overlaps can be removed.
    case live([OverviewSizedItem])
    /// Only the total from an earlier scan is known, so it is counted as recorded.
    case recorded(Int64)
    /// Nothing to show: never scanned, or not readable without Full Disk Access.
    case none
}

/// The whole disk split into what Purge found and everything else.
///
/// Used, free and total come straight from the volume, so they match what macOS
/// reports. The categories are Purge's own findings. Each byte is counted once, by
/// the first category in `OverviewCategory.allCases` order that finds it: an app's
/// total includes its cache folder, which App Caches has already counted, so the app
/// keeps only the rest. Everything else is the used space Purge did not sort.
nonisolated struct OverviewBreakdown: Equatable, Sendable {
    let totalBytes: Int64
    let usedBytes: Int64
    let freeBytes: Int64
    let categoryBytes: [OverviewCategory: Int64]

    var sortedBytes: Int64 {
        categoryBytes.values.reduce(0, +)
    }

    var everythingElseBytes: Int64 {
        max(0, usedBytes - sortedBytes)
    }

    func bytes(for category: OverviewCategory) -> Int64 {
        categoryBytes[category] ?? 0
    }

    /// Share of the whole disk, 0...1.
    func share(of bytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(totalBytes)))
    }

    init(
        totalBytes: Int64,
        freeBytes: Int64,
        sources: [OverviewCategory: OverviewCategorySource]
    ) {
        self.totalBytes = max(0, totalBytes)
        self.freeBytes = min(max(0, freeBytes), self.totalBytes)
        self.usedBytes = self.totalBytes - self.freeBytes

        var claims = ClaimedPaths()
        var result: [OverviewCategory: Int64] = [:]
        for category in OverviewCategory.allCases {
            switch sources[category] ?? .none {
            case .live(let items):
                var total: Int64 = 0
                for item in items {
                    total += claims.claim(item)
                }
                result[category] = total
            case .recorded(let bytes):
                result[category] = max(0, bytes)
            case .none:
                break
            }
        }
        categoryBytes = result
    }
}

/// Paths already counted, kept sorted so the folders under a new path can be found
/// with a binary search instead of a scan of every earlier claim.
nonisolated private struct ClaimedPaths {
    private var set = Set<String>()
    private var sorted: [String] = []
    /// What each claimed path added, after its own overlaps were taken out.
    private var contribution: [String: Int64] = [:]

    /// Counts the item and returns how many bytes it adds.
    mutating func claim(_ item: OverviewSizedItem) -> Int64 {
        guard !item.path.isEmpty, !isCovered(item.path) else { return 0 }
        let alreadyCounted = bytesClaimed(under: item.path)
        let added = max(0, item.bytes - alreadyCounted)
        insert(item.path)
        contribution[item.path] = added
        return added
    }

    /// True when the path, or a folder above it, is already counted.
    private func isCovered(_ path: String) -> Bool {
        var candidate = path
        while true {
            if set.contains(candidate) { return true }
            guard let slash = candidate.lastIndex(of: "/"), slash != candidate.startIndex else {
                return candidate != "/" && set.contains("/")
            }
            candidate = String(candidate[..<slash])
        }
    }

    /// Bytes already counted for paths inside this folder.
    private func bytesClaimed(under folder: String) -> Int64 {
        let prefix = folder == "/" ? "/" : folder + "/"
        var index = lowerBound(prefix)
        var total: Int64 = 0
        while index < sorted.count, sorted[index].hasPrefix(prefix) {
            total += contribution[sorted[index]] ?? 0
            index += 1
        }
        return total
    }

    private mutating func insert(_ path: String) {
        set.insert(path)
        sorted.insert(path, at: lowerBound(path))
    }

    private func lowerBound(_ value: String) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
