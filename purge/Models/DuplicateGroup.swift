import Foundation

/// A set of Large Files whose contents are byte-for-byte identical.
///
/// Membership is by `LargeFile.id` (the standardized path) rather than by value,
/// so a group survives the passes that rebuild the `LargeFile` structs and so a
/// row's lookup stays a dictionary hit — see `DuplicateIndex`.
nonisolated struct DuplicateGroup: Identifiable, Hashable {
    /// The shared content digest. Stable across scans for unchanged files, which
    /// makes it usable as a sort key that doesn't reshuffle between runs.
    let id: String

    /// Every copy in the group, in path order — they are all the same size, so
    /// there is nothing else to rank them by, and sorting keeps the group stable
    /// from run to run.
    let fileIDs: [String]

    /// Logical size of a single copy. Every member has the same one — that is
    /// what put them in the same bucket.
    let sizeBytes: Int64

    var copyCount: Int { fileIDs.count }

    /// What deleting all but one copy would free. Deliberately not
    /// `sizeBytes * copyCount`: the point of a duplicate group is that one copy
    /// is worth keeping.
    var reclaimableBytes: Int64 { sizeBytes * Int64(copyCount - 1) }
}

/// The finished result of a duplicate pass: the groups themselves plus the
/// reverse lookup rows use.
///
/// `groupIDByFileID` exists because the "N copies" badge is read from every
/// visible row on every render. Searching `groups` per row would be O(rows ×
/// groups) inside a SwiftUI `body` — the same class of per-render cost that
/// standardizing URLs in computed properties used to impose on this list.
nonisolated struct DuplicateIndex: Equatable {
    /// Ordered by reclaimable bytes, biggest win first.
    let groups: [DuplicateGroup]
    let groupIDByFileID: [String: String]

    /// Copy count and group position, precomputed per file. Both are read from
    /// every visible row on every render (the badge) and from the comparator
    /// during sorting, so neither may be a search through `groups`.
    private let copyCountByFileID: [String: Int]
    private let rankByFileID: [String: Int]

    static let empty = DuplicateIndex(groups: [])

    /// Builds the reverse lookups from the groups, and orders groups by the space
    /// they stand to free so the biggest win sorts first.
    init(groups: [DuplicateGroup]) {
        let ordered = groups.sorted {
            $0.reclaimableBytes != $1.reclaimableBytes
                ? $0.reclaimableBytes > $1.reclaimableBytes
                : $0.id < $1.id
        }
        var lookup: [String: String] = [:]
        var counts: [String: Int] = [:]
        var ranks: [String: Int] = [:]
        for (rank, group) in ordered.enumerated() {
            for fileID in group.fileIDs {
                lookup[fileID] = group.id
                counts[fileID] = group.copyCount
                ranks[fileID] = rank
            }
        }
        self.groups = ordered
        self.groupIDByFileID = lookup
        self.copyCountByFileID = counts
        self.rankByFileID = ranks
    }

    var isEmpty: Bool { groups.isEmpty }

    /// Number of files that sit in some duplicate group — what the Duplicates
    /// chip counts. Not the number of groups: the chip counts rows, like every
    /// other chip in that row does.
    var duplicateFileCount: Int { groupIDByFileID.count }

    /// How many byte-identical copies this file has siblings in, nil when it
    /// isn't in a group.
    func copyCount(forFileID fileID: String) -> Int? {
        copyCountByFileID[fileID]
    }

    func group(forFileID fileID: String) -> DuplicateGroup? {
        guard let rank = rankByFileID[fileID], groups.indices.contains(rank) else { return nil }
        return groups[rank]
    }

    /// Rank used to lay duplicate rows out group-by-group. Files in the same
    /// group share a rank, so sorting on it puts copies next to each other with
    /// the most reclaimable group on top. Non-members sort last.
    func groupRank(forFileID fileID: String) -> Int {
        rankByFileID[fileID] ?? .max
    }

    /// Drops files that no longer exist and any group left with fewer than two
    /// copies. Called after a delete: a group of two that loses one member is no
    /// longer a duplicate, and leaving the survivor badged "2 copies" would be a
    /// lie about the disk.
    func removing(fileIDs removed: Set<String>) -> DuplicateIndex {
        guard !removed.isEmpty else { return self }
        let surviving = groups.compactMap { group -> DuplicateGroup? in
            let kept = group.fileIDs.filter { !removed.contains($0) }
            guard kept.count > 1 else { return nil }
            guard kept.count != group.fileIDs.count else { return group }
            return DuplicateGroup(id: group.id, fileIDs: kept, sizeBytes: group.sizeBytes)
        }
        return DuplicateIndex(groups: surviving)
    }
}
