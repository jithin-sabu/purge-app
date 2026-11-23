import Foundation

/// One folder opened on the Everything else map (#437): the folders directly
/// inside it, each sized, and the files beside them. Read only, like the rest
/// of the page. It says where the space is, and nothing in it can be removed
/// from here.
nonisolated struct EverythingElseFolderContents: Equatable, Sendable {
    let path: String
    /// Each folder directly inside, with everything under it as counted. A
    /// folder the walk could not read has no entry rather than a zero.
    let folders: [OverviewSizedItem]
    /// The folders inside that can be opened in turn.
    let openablePaths: Set<String>
    /// Files directly inside, and links, counted as the few bytes a link is.
    let looseFileBytes: Int64
    /// Folders inside that a limited scan may not read, so they have no figure.
    let lockedFolderCount: Int

    /// Everything inside as counted.
    var totalBytes: Int64 {
        folders.reduce(looseFileBytes) { $0 + $1.bytes }
    }

    init(path: String, folders: [OverviewSizedItem], openablePaths: Set<String>, looseFileBytes: Int64, lockedFolderCount: Int = 0) {
        self.path = OverviewSizedItem.normalized(path)
        self.folders = folders
        self.openablePaths = openablePaths
        self.looseFileBytes = max(0, looseFileBytes)
        self.lockedFolderCount = max(0, lockedFolderCount)
    }

    /// The contents with every folder the user excluded taken out.
    func droppingFolders(where isHidden: (String) -> Bool) -> EverythingElseFolderContents {
        let kept = folders.filter { !isHidden($0.path) }
        guard kept.count != folders.count else { return self }
        return EverythingElseFolderContents(
            path: path,
            folders: kept,
            openablePaths: openablePaths.filter { !isHidden($0) },
            looseFileBytes: looseFileBytes,
            lockedFolderCount: lockedFolderCount
        )
    }
}

/// What the map shows for an opened folder: a tile per folder inside it and one
/// for the loose files, each after the parts a category or an earlier group
/// already counted are out. So the tiles add up to the tile that was opened,
/// and a project's `node_modules`, which Dev Tools lists, is not counted twice.
nonisolated struct EverythingElseFolderLevel: Equatable, Sendable {
    /// The folder that was opened, with its figure from the level above.
    let folder: EverythingElseFolder
    /// Biggest first. Folders, then the loose files as a `.smaller` row with no
    /// count, which the map calls "Loose files".
    let items: [EverythingElseItem]
    let openablePaths: Set<String>
    let lockedFolderCount: Int

    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    /// `claims` holds what was counted before the opened folder's top-level
    /// tile: see `EverythingElseMeasurement.claims(before:claimedFirst:)`.
    init(folder: EverythingElseFolder, contents: EverythingElseFolderContents, claims: ClaimedPaths) {
        var claims = claims
        var items: [EverythingElseItem] = []
        // Children before the folder itself, biggest first, the way the
        // breakdown claims, so a nested claim comes out of its parent once.
        for child in contents.folders.sorted(by: { $0.bytes > $1.bytes }) {
            let added = claims.claim(child)
            guard added > 0 else { continue }
            let row = EverythingElseFolder(path: child.path, bytes: added, measuredBytes: child.bytes, group: folder.group)
            items.append(EverythingElseItem(group: folder.group, kind: .folder(row), bytes: added))
        }
        let loose = claims.claim(OverviewSizedItem(path: contents.path, bytes: contents.totalBytes))
        if loose > 0 {
            items.append(EverythingElseItem(group: folder.group, kind: .smaller(count: 0, biggest: []), bytes: loose))
        }
        self.folder = folder
        self.items = items.sorted { lhs, rhs in
            lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.id < rhs.id
        }
        self.openablePaths = contents.openablePaths
        self.lockedFolderCount = contents.lockedFolderCount
    }
}

/// Which folders on the map can be opened (#437).
nonisolated enum EverythingElseFolderOpening {
    /// Media library bundles keep their insides to the app that owns them, so
    /// they are never opened, whichever group they turn up in.
    static let mediaLibraryExtensions: Set<String> = ["photoslibrary", "imovielibrary", "tvlibrary", "musiclibrary", "theater"]

    /// Whether the folder at `url`, a tile in `group`, can be opened to show the
    /// folders inside it. Never for the groups measured as one block (media
    /// libraries, Mail and Messages, other users), never for a media library,
    /// and with a limited scan only where the walk itself may read.
    static func canOpen(_ url: URL, group: EverythingElseGroup, access: ScanAccess, home: URL) -> Bool {
        guard group.opensFolders else { return false }
        if isMediaLibrary(url) { return false }
        switch access {
        case .full:
            return true
        case .limited:
            return EverythingElseRootPlan.isReadableByLimitedWalk(url, home: home)
        }
    }

    static func isMediaLibrary(_ url: URL) -> Bool {
        LargeFileScanPolicy.excludedFolderNames.contains(url.lastPathComponent)
            || mediaLibraryExtensions.contains(url.pathExtension.lowercased())
    }
}

extension EverythingElseMeasurement {
    /// Everything the breakdown counted before it reached the folder at `path`:
    /// the five categories' items, then each group's folders in claim order, up
    /// to that folder. Claimed into a level inside the folder, these take out
    /// what a category or an earlier group already has, so the level adds up
    /// to the folder's own tile. Folders above `path` are left out, or they
    /// would cover the whole level.
    func claims(before path: String, claimedFirst: [OverviewSizedItem]) -> ClaimedPaths {
        let target = OverviewSizedItem.normalized(path)
        func isAncestorOrSelf(_ candidate: String) -> Bool {
            candidate == target || target.hasPrefix(candidate == "/" ? "/" : candidate + "/")
        }
        var claims = ClaimedPaths()
        for item in claimedFirst {
            _ = claims.claim(item)
        }
        for group in EverythingElseGroup.measured {
            for measured in measuredRoots where measured.root.group == group {
                for folder in measured.folders.sorted(by: { $0.bytes > $1.bytes }) {
                    let folderPath = OverviewSizedItem.normalized(folder.path)
                    if folderPath == target { return claims }
                    if isAncestorOrSelf(folderPath) { continue }
                    _ = claims.claim(folder)
                }
                let rootPath = measured.root.path
                if measured.root.kind == .whole {
                    if rootPath == target { return claims }
                    if isAncestorOrSelf(rootPath) { continue }
                    _ = claims.claim(OverviewSizedItem(path: rootPath, bytes: measured.totalBytes))
                } else if measured.looseFileBytes > 0, !isAncestorOrSelf(rootPath) {
                    _ = claims.claim(OverviewSizedItem(path: rootPath, bytes: measured.totalBytes))
                }
            }
        }
        return claims
    }
}
