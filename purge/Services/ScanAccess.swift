import Foundation

/// How much of the disk a scan may read.
///
/// Without Full Disk Access, macOS guards some folders with a prompt: touching
/// Desktop, Documents or Downloads asks "Purge would like to access files in
/// your … folder", and opening another app's container asks about "data from
/// other apps". Others, like Safari and Mail, are refused outright. A limited
/// scan stays out of all of them, so a new install can show real results
/// before it asks for anything, and never triggers a prompt on the way.
nonisolated enum ScanAccess: Sendable, Equatable {
    case limited
    case full

    /// Probes the disk, so call it once per scan, not per path.
    static func current() -> ScanAccess {
        PermissionChecker().hasFullDiskAccess() ? .full : .limited
    }
}

/// The folders a limited scan must not touch.
///
/// Also the definition of "places that were locked" when Purge reports what
/// granting access found: anything under these roots was out of reach before.
nonisolated enum ProtectedLocations {
    /// Home-relative roots. The first three prompt per folder, the containers
    /// and iCloud roots prompt or hang on file providers, and the rest are
    /// refused silently but still count as locked.
    static let homeRelativeRoots: [String] = [
        "Desktop",
        "Documents",
        "Downloads",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Mobile Documents",
        "Library/CloudStorage",
        "Library/Safari",
        "Library/Mail",
        "Library/Messages"
    ]

    static func rootPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let homePath = home.standardizedFileURL.path
        return homeRelativeRoots.map { "\(homePath)/\($0)" }
    }

    /// True when `url` is one of the roots or sits inside one. A pure path
    /// check: it never touches the disk, so it is safe to call before deciding
    /// whether touching the disk is allowed.
    static func contains(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        // Folded by hand: `standardizedFileURL` checks the disk, and through a
        // symlink that check would land in the folder this is meant to avoid.
        contains(path: "/" + lexicalComponents(of: url.path, relativeTo: []).joined(separator: "/"), home: home)
    }

    static func contains(path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        rootPaths(home: home).contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    /// A few hops covers every real setup; a chain longer than this is treated
    /// as unreadable rather than chased.
    static let maxSymlinkHops = 8

    /// Whether a limited scan may read `url`.
    ///
    /// Walks the path one component at a time and reads any symlink on the way
    /// with `destinationOfSymbolicLink`, which reads the link and never the
    /// target. So `~/Developer` pointing into `~/Documents` is caught, and so is
    /// `~/Projects/client/node_modules` when only `client` is the link. Each
    /// component is checked against the roots before its link is read, so the
    /// check never reaches inside a protected folder.
    ///
    /// Everything here is string work plus `readlink`. `fileExists`, resource
    /// values, `standardizedFileURL` and `resolvingSymlinksInPath` all follow
    /// the link to its target, which is the access that prompts.
    static func isReadable(
        _ url: URL,
        access: ScanAccess,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        guard access == .limited else { return true }
        return readablePath(of: url, home: home, fileManager: fileManager) != nil
    }

    /// The real path behind `url` with every symlink on the way resolved, or nil
    /// when a hop lands in a protected root or the chain is too long. Same rules
    /// and same disk access as `isReadable`: only `readlink`, and never inside a
    /// root.
    static func readablePath(
        of url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String? {
        let roots = resolvedRootPaths(home: home, fileManager: fileManager)
        return resolvingLinks(in: url.path, fileManager: fileManager) { isPath($0, inAnyOf: roots) }
    }

    /// `rootPaths` plus the same roots under home's resolved path. Resolved paths
    /// are compared against these: a home under `/var` is really under
    /// `/private/var`. Home itself is never protected, so resolving it is safe.
    static func resolvedRootPaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String] {
        let roots = rootPaths(home: home)
        guard let realHome = resolvingLinks(in: home.path, fileManager: fileManager, stopAt: { _ in false }) else {
            return roots
        }
        let resolved = homeRelativeRoots.map { "\(realHome)/\($0)" }
        return resolved == roots ? roots : roots + resolved
    }

    /// Pure string check of `path` against roots from `resolvedRootPaths`.
    static func isPath(_ path: String, inAnyOf roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Resolves every symlink in `path` with `readlink` alone, one component at a
    /// time. Returns nil as soon as a partial path matches `stopAt`, before its
    /// link is read, or when the chain runs past `maxSymlinkHops`.
    private static func resolvingLinks(
        in path: String,
        fileManager: FileManager,
        stopAt: (String) -> Bool
    ) -> String? {
        var remaining = lexicalComponents(of: path, relativeTo: [])
        var resolved: [String] = []
        var hops = 0
        while !remaining.isEmpty {
            let next = resolved + [remaining.removeFirst()]
            let nextPath = "/" + next.joined(separator: "/")
            if stopAt(nextPath) { return nil }
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: nextPath) else {
                resolved = next
                continue
            }
            hops += 1
            guard hops <= maxSymlinkHops else { return nil }
            // A relative link resolves against the folder that holds it. The
            // rest of the original path then continues from the target.
            let base = destination.hasPrefix("/") ? [] : resolved
            remaining = lexicalComponents(of: destination, relativeTo: base) + remaining
            resolved = []
        }
        let resolvedPath = "/" + resolved.joined(separator: "/")
        return stopAt(resolvedPath) ? nil : resolvedPath
    }

    /// Splits `path` into components with `.` and `..` folded away, without
    /// touching the disk. `base` is the folder a relative path starts from.
    private static func lexicalComponents(of path: String, relativeTo base: [String]) -> [String] {
        var components = path.hasPrefix("/") ? [] : base
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(part))
            }
        }
        return components
    }
}
