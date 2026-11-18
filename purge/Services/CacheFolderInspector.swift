import Foundation

/// Read-only sizes for direct children of the developer cache directory.
nonisolated enum CacheFolderInspector {
    struct Folder: Identifiable, Equatable, Sendable {
        var id: URL { url }
        let url: URL
        /// A failed measurement is different from an empty folder.
        let bytes: Int64?
    }

    enum Result: Equatable, Sendable {
        case folders([Folder])
        case unavailable
    }

    static func inspect(
        at root: URL,
        knownPaths: [URL],
        isExcluded: (URL) -> Bool = ExcludedPathsStore.isExcluded
    ) -> Result {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? root.resourceValues(forKeys: keys),
              values.isDirectory == true, values.isSymbolicLink != true,
              !isExcluded(root),
              let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)),
              !Task.isCancelled else { return .unavailable }

        // Foundation listings can spell /var as /private/var. Compare the
        // paths as text so inspecting this folder never opens a known path.
        func comparisonPath(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
        }

        let known = knownPaths.map(comparisonPath)
        let folders = children.filter { url in
            guard !Task.isCancelled, let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  !isExcluded(url) else { return false }
            let path = comparisonPath(url)
            return !known.contains { PathContainment.isSameOrInside(path, $0) || PathContainment.isSameOrInside($0, path) }
        }

        let sizes = FolderSizing.walkedSizes(at: folders, staysOnVolume: true)
        return .folders(folders.map { Folder(url: $0, bytes: sizes[$0.standardizedFileURL.path]) }
            .sorted {
                if $0.bytes != $1.bytes { return ($0.bytes ?? -1) > ($1.bytes ?? -1) }
                return $0.url.path < $1.url.path
            })
    }
}
