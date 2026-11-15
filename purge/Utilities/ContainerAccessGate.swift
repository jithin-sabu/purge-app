import Foundation

/// Lets one thread at a time look up a path inside other apps' containers.
///
/// Opening a folder in `~/Library/Containers` or `~/Library/Group Containers`
/// makes macOS check, inside the `open` call, that Purge may read it. When two
/// threads of Purge did that at once, one of them sometimes waited 5 to 6 s
/// (measured 2026-11-12: about one cache scan in eight). One at a time it never
/// did, which is how scans met these folders when every folder was sized by a
/// `du` process of its own. Reads that run side by side take this gate for
/// each such lookup; everything outside the containers stays parallel.
nonisolated enum ContainerAccessGate {
    private static let lock = NSLock()

    private static let containerRoots: [String] = {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
        return ["\(library)/Containers/", "\(library)/Group Containers/"]
    }()

    /// Whether `path` is inside another app's container, spelled as walks
    /// spell it (no trailing slash needed).
    static func isInsideContainers(_ path: String) -> Bool {
        containerRoots.contains { path.hasPrefix($0) }
    }

    /// Runs `body` holding the gate when `path` is inside the containers.
    static func access<T>(_ path: String, _ body: () -> T) -> T {
        guard isInsideContainers(path) else { return body() }
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
