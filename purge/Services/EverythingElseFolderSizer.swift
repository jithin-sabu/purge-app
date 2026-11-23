import Foundation

/// Sizes the folders directly inside one folder the user opened on the
/// Everything else map (#437). It makes the same reads the walk makes: one
/// listing, then `FolderSizing` for each folder inside, on this disk only.
/// Nothing is changed, moved or opened for writing.
nonisolated enum EverythingElseFolderSizer {
    /// The folders inside `url` with their sizes, and the files beside them.
    /// Nil when the folder can't be listed or the task was cancelled.
    /// `group` is the opened tile's group, which decides what can be opened
    /// further. `progress` hears how far through the folders the sizing is, 0...1.
    static func contents(
        of url: URL,
        group: EverythingElseGroup,
        access: ScanAccess,
        home: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) -> EverythingElseFolderContents? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .volumeIdentifierKey
        ]
        // Hidden entries count here: a project's `.git` is often the biggest
        // folder in it, and the tile above already counted it.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return nil }
        let volume = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject

        var folders: [URL] = []
        var openable: Set<String> = []
        var looseFileBytes: Int64 = 0
        var lockedFolderCount = 0
        for entry in entries {
            if Task.isCancelled { return nil }
            guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
            // A link is counted as the few bytes it is, never followed.
            if values.isSymbolicLink == true {
                looseFileBytes += Int64(values.fileSize ?? 0)
                continue
            }
            guard values.isDirectory == true else {
                looseFileBytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                continue
            }
            // Another file system mounted here holds nothing on this disk.
            if let volume, let entryVolume = values.volumeIdentifier as? NSObject, !entryVolume.isEqual(volume) { continue }
            // A limited scan stays out of the protected roots and the media and
            // contacts folders, so no privacy prompt ever comes from here.
            if access == .limited, !EverythingElseRootPlan.isReadableByLimitedWalk(entry, home: home) {
                lockedFolderCount += 1
                continue
            }
            folders.append(entry)
            if EverythingElseFolderOpening.canOpen(entry, group: group, access: access, home: home) {
                openable.insert(OverviewSizedItem.normalized(entry.standardizedFileURL.path))
            }
        }
        if Task.isCancelled { return nil }

        let sizes = FolderSizing.directorySizes(at: folders, split: .spread, staysOnVolume: true, onChunkDone: { done, total in
            progress(Double(done) / Double(max(1, total)))
        })
        if Task.isCancelled { return nil }
        var items: [OverviewSizedItem] = []
        items.reserveCapacity(folders.count)
        for folder in folders {
            // A folder that could not be read gets no tile rather than a zero
            // that would read as empty.
            guard let bytes = sizes[folder.standardizedFileURL.path] else { continue }
            items.append(OverviewSizedItem(path: folder.standardizedFileURL.path, bytes: bytes))
        }
        return EverythingElseFolderContents(
            path: url.standardizedFileURL.path,
            folders: items,
            openablePaths: openable,
            looseFileBytes: looseFileBytes,
            lockedFolderCount: lockedFolderCount
        )
    }
}
