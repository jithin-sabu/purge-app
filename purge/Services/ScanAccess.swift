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
        contains(path: url.standardizedFileURL.path, home: home)
    }

    static func contains(path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        rootPaths(home: home).contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    /// Whether a limited scan may read `url`. Follows a symlink at `url` itself
    /// by reading the link, never the target, so `~/Developer` pointing into
    /// `~/Documents` is caught without ever opening Documents. Symlinks further
    /// down are not followed here; the directory walks already skip them.
    static func isReadable(
        _ url: URL,
        access: ScanAccess,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        guard access == .limited else { return true }
        var current = url.standardizedFileURL
        // A few hops covers every real setup; a loop longer than this is
        // treated as unreadable rather than chased.
        for _ in 0..<8 {
            guard !contains(current, home: home) else { return false }
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: current.path) else {
                return true
            }
            current = URL(fileURLWithPath: destination, relativeTo: current.deletingLastPathComponent())
                .standardizedFileURL
        }
        return false
    }
}
