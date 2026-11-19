import Foundation

/// Where one path sits relative to another. The deletion gates used to write these
/// checks inline, and one copy compared without the `/` boundary, so a sibling
/// folder whose name starts the same way counted as inside (#185).
nonisolated enum PathContainment {
    /// `path` is `root` or anything under it. Plain string comparison, so both
    /// must be spelled the same way (standardized, no trailing `/`).
    static func isSameOrInside(_ path: String, _ root: String) -> Bool {
        path == root || isInside(path, root)
    }

    /// `path` is under `root`, never `root` itself. `/Users/a/Library2` is not
    /// inside `/Users/a/Library`.
    static func isInside(_ path: String, _ root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// True when any folder from `home` down to `url` is a link, and when `url`
    /// is not under `home` at all. Each step is `lstat`ed, never followed.
    static func containsSymlinkComponent(_ url: URL, home: String) -> Bool {
        let path = url.standardizedFileURL.path
        guard isSameOrInside(path, home) else { return true }
        var current = URL(fileURLWithPath: home, isDirectory: true)
        for part in path.dropFirst(home.count).split(separator: "/") {
            current.appendPathComponent(String(part))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return true
            }
        }
        return false
    }

    /// True when `folder`, or a folder above it up to `home`, is a link or can't
    /// be read, and when `folder` is not under `home` at all. `home` itself is
    /// never read. A step that isn't there ends the walk: nothing below it
    /// exists, so nothing below it is a link.
    ///
    /// The same walk as `containsSymlinkComponent`, on plain paths with
    /// `lstat`, for callers that ask for every row of a scan (#422): 1 µs for
    /// two steps, against 12 µs through `URL`.
    static func reachesThroughLink(_ folder: String, home: String) -> Bool {
        guard folder != home else { return false }
        guard isInside(folder, home) else { return true }
        // Counted in characters, as `isInside` compares them.
        var slash = folder.index(folder.startIndex, offsetBy: home.hasSuffix("/") ? home.count - 1 : home.count)
        while true {
            let stepEnd = folder[folder.index(after: slash)...].firstIndex(of: "/") ?? folder.endIndex
            var info = stat()
            if lstat(String(folder[..<stepEnd]), &info) != 0 {
                return !(errno == ENOENT || errno == ENOTDIR)
            }
            if (info.st_mode & S_IFMT) == S_IFLNK { return true }
            guard stepEnd < folder.endIndex else { return false }
            slash = stepEnd
        }
    }

    /// `url` resolves to somewhere under `root`, and `root` itself is reached
    /// through no link, so a link inside the root cannot point the delete
    /// elsewhere. `includingRoot` also accepts `url` resolving to `root` itself.
    static func staysInside(root: String, url: URL, home: String, includingRoot: Bool = false) -> Bool {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard !containsSymlinkComponent(rootURL, home: home) else { return false }
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedRoot == root else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return includingRoot ? isSameOrInside(resolved, resolvedRoot) : isInside(resolved, resolvedRoot)
    }
}
