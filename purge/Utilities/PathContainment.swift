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

    private static let slash = UInt8(ascii: "/")

    /// Where the `/` that follows `root` sits in `path`, or nil when `path` is
    /// `root` itself or not under it.
    ///
    /// Separators are found as bytes, never as characters. Swift joins a `/` and
    /// a combining mark after it into one character, so a search by character
    /// walks past the `/` in front of a name that starts with such a mark, and
    /// a folder on the way is never looked at (#422 review).
    static func separatorIndex(after root: String, in path: String) -> String.Index? {
        var rootBytes = root.utf8[...]
        if rootBytes.last == slash { rootBytes = rootBytes.dropLast() }
        let bytes = path.utf8
        if bytes.starts(with: rootBytes) {
            guard bytes.count > rootBytes.count else { return nil }
            let index = bytes.index(bytes.startIndex, offsetBy: rootBytes.count)
            return bytes[index] == slash ? index : nil
        }
        // The same root spelled with another form of an accented letter is the
        // same text with other bytes. Plain ASCII has only one spelling.
        guard !rootBytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        let rootText = String(Substring(rootBytes))
        var search = bytes.startIndex
        while let index = bytes[search...].firstIndex(of: slash) {
            if String(path[..<index]) == rootText { return index }
            search = bytes.index(after: index)
        }
        return nil
    }

    /// The folder `path` sits in: everything before its last `/` byte.
    static func parentFolder(of path: String) -> String {
        String(path[..<(path.utf8.lastIndex(of: slash) ?? path.endIndex)])
    }

    /// True when `folder`, or a folder above it up to `home`, is a link or can't
    /// be read, and when `folder` is not under `home` at all. `home` itself is
    /// never read. A step that isn't there ends the walk: nothing below it
    /// exists, so nothing below it is a link.
    ///
    /// The same walk as `containsSymlinkComponent`, on plain paths with
    /// `lstat`, for callers that ask for every row of a scan (#422): 1 µs for
    /// two steps, against 12 µs through `URL`. Each step ends at a `/` byte.
    static func reachesThroughLink(_ folder: String, home: String) -> Bool {
        guard folder != home else { return false }
        guard var separator = separatorIndex(after: home, in: folder) else { return true }
        let bytes = folder.utf8
        while true {
            let stepEnd = bytes[bytes.index(after: separator)...].firstIndex(of: slash) ?? bytes.endIndex
            var info = stat()
            // `errno` is read inside the call, before the path's C string is
            // freed, so nothing can change it first.
            let failure: Int32? = String(folder[..<stepEnd]).withCString { lstat($0, &info) == 0 ? nil : errno }
            if let failure { return !(failure == ENOENT || failure == ENOTDIR) }
            if (info.st_mode & S_IFMT) == S_IFLNK { return true }
            guard stepEnd < bytes.endIndex else { return false }
            separator = stepEnd
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
