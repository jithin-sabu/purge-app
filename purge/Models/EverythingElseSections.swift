import Foundation

/// One row on the Everything else page (#159): a folder over the floor, a group's
/// smaller folders in one line, a group a limited scan could not read, or one of
/// the lines that stand for something Purge did not walk folder by folder.
nonisolated struct EverythingElseItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case folder(EverythingElseFolder)
        /// The folders under the floor, and the loose files, in one line, with
        /// the biggest of them by name.
        case smaller(count: Int, biggest: [EverythingElseFolder])
        /// Needs Full Disk Access to read.
        case locked
        /// The Trash, macOS or System Data: one figure, no folder to list.
        case system
    }

    let group: EverythingElseGroup
    let kind: Kind
    let bytes: Int64

    var id: String {
        switch kind {
        case .folder(let folder): return folder.path
        case .smaller: return "smaller.\(group.rawValue)"
        case .locked: return "locked.\(group.rawValue)"
        case .system: return "system.\(group.rawValue)"
        }
    }

    var isLocked: Bool { kind == .locked }
}

/// One bucket's card on the page: what you can do about the space, its total, and
/// its rows biggest first, across every group in it.
nonisolated struct EverythingElseSection: Identifiable, Equatable, Sendable {
    /// Rows a card shows before "N more".
    static let collapsedRowLimit = 4

    let bucket: EverythingElseBucket
    let bytes: Int64
    let items: [EverythingElseItem]

    var id: String { bucket.rawValue }

    /// The cards in bucket order, leaving out buckets with nothing to show.
    /// `onlyGroup` is the tile picked on the map: the cards then list that
    /// group alone.
    static func sections(for breakdown: EverythingElseBreakdown, onlyGroup: EverythingElseGroup? = nil) -> [EverythingElseSection] {
        EverythingElseBucket.allCases.compactMap { bucket in
            let groups = bucket.groups.filter { onlyGroup == nil || $0 == onlyGroup }
            // `Self.`: the local shadows the method, and the compiler CI runs
            // (Xcode 26.6) resolves the bare name to the local.
            let items = groups.flatMap { Self.items(for: $0, in: breakdown) }.sorted(by: rowOrder)
            guard !items.isEmpty else { return nil }
            let bytes = groups.reduce(Int64(0)) { $0 + breakdown.bytes(for: $1) }
            return EverythingElseSection(bucket: bucket, bytes: bytes, items: items)
        }
    }

    /// The rows one group adds.
    static func items(for group: EverythingElseGroup, in breakdown: EverythingElseBreakdown) -> [EverythingElseItem] {
        switch group {
        case .trash:
            // Nil means the Trash can't be read without Full Disk Access.
            guard let bytes = breakdown.trashBytes else {
                return [EverythingElseItem(group: group, kind: .locked, bytes: 0)]
            }
            return bytes > 0 ? [EverythingElseItem(group: group, kind: .system, bytes: bytes)] : []
        case .macOS:
            guard let bytes = breakdown.macOSBytes, bytes > 0 else { return [] }
            return [EverythingElseItem(group: group, kind: .system, bytes: bytes)]
        case .systemData:
            let bytes = breakdown.systemDataBytes
            return bytes > 0 ? [EverythingElseItem(group: group, kind: .system, bytes: bytes)] : []
        case .otherApps, .mediaLibraries, .mailAndMessages, .protectedCaches,
             .developer, .appData, .documents, .otherUsers:
            guard let figures = breakdown[group] else { return [] }
            if figures.isLocked, figures.bytes == 0 {
                return [EverythingElseItem(group: group, kind: .locked, bytes: 0)]
            }
            var items = figures.folders.map { EverythingElseItem(group: group, kind: .folder($0), bytes: $0.bytes) }
            if figures.smallerFolderCount > 0 || figures.smallerBytes > 0 {
                items.append(EverythingElseItem(
                    group: group,
                    kind: .smaller(count: figures.smallerFolderCount, biggest: figures.smallerFolders),
                    bytes: figures.smallerBytes
                ))
            }
            return items
        }
    }

    /// Folders too small to label join the group's "smaller folders" tile. The
    /// biggest row always keeps a tile of its own.
    static func rollingUpTinyRows(_ rows: [EverythingElseItem], group: EverythingElseGroup, below minimumWeight: Double) -> [EverythingElseItem] {
        guard rows.count > 1 else { return rows }
        let sorted = rows.sorted { $0.bytes > $1.bytes }
        var kept: [EverythingElseItem] = []
        var smallerCount = 0
        var smallerBytes: Int64 = 0
        var biggest: [EverythingElseFolder] = []
        var hasSmaller = false
        for (index, row) in sorted.enumerated() {
            switch row.kind {
            case .smaller(let count, let folders):
                smallerCount += count
                smallerBytes += row.bytes
                biggest += folders
                hasSmaller = true
            case .folder(let folder) where index > 0 && Double(row.bytes) < minimumWeight:
                smallerCount += 1
                smallerBytes += row.bytes
                biggest.append(folder)
                hasSmaller = true
            case .folder, .system, .locked:
                kept.append(row)
            }
        }
        if hasSmaller, smallerBytes > 0 {
            let listed = Array(biggest.sorted { $0.bytes > $1.bytes }.prefix(EverythingElseBreakdown.listedSmallerFolderCount))
            kept.append(EverythingElseItem(group: group, kind: .smaller(count: smallerCount, biggest: listed), bytes: smallerBytes))
        }
        return kept
    }

    /// Biggest first. Rows that need access go last, since they have no size.
    private static func rowOrder(_ lhs: EverythingElseItem, _ rhs: EverythingElseItem) -> Bool {
        if lhs.isLocked != rhs.isLocked { return !lhs.isLocked }
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        return lhs.id < rhs.id
    }
}
