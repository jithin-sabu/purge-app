import Foundation

/// Folders a test makes in the real home folder. The deletion gate only lets agent
/// worktrees through there, so some tests can't use a temporary home.
///
/// `remove()` takes away only what this made: each folder or link from `make` and
/// `link` in full, then every parent folder a fixture had to create, deepest first
/// and only while empty. A folder that was already there, or that a tool put
/// something in meanwhile, stays.
///
/// Tests run in parallel and make their folders under the same parents, such as
/// `~/.cursor/worktrees`. So the parents fixtures made are counted across every
/// fixture in the process: one that is still in use is kept, and the last fixture
/// to finish removes it.
///
/// Call `remove()` in a `defer` placed before the first `make`, so the parents of
/// a `make` that throws halfway are removed too.
final class RealHomeFolders {
    let home: URL
    /// Made with a name no one else uses, so they are removed in full.
    private var owned: [URL] = []
    /// Parents this fixture uses that some fixture made, in the order it reached them.
    private var parents: [URL] = []

    /// Guards every fixture's folder changes, so one can't remove a parent while
    /// another is making a folder in it.
    private static let lock = NSLock()
    /// How many fixtures use each parent a fixture made, by path.
    nonisolated(unsafe) private static var parentUsers: [String: Int] = [:]

    /// Another `home` is only for this type's own tests.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Makes the folder at `relativePath` under the home folder, and any missing
    /// parents. Its last component must be unique to the test: if the folder is
    /// already there this throws, because it isn't this test's to remove.
    @discardableResult
    func make(_ relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/").map(String.init)
        precondition(!components.isEmpty && !components.contains(".."), "Stay inside the home folder: \(relativePath)")
        return try Self.lock.withLock {
            var url = home
            for (index, name) in components.enumerated() {
                url.appendPathComponent(name, isDirectory: true)
                let isLast = index == components.count - 1
                if mkdir(url.path, 0o755) == 0 {
                    if isLast {
                        owned.append(url)
                    } else {
                        Self.parentUsers[url.path] = 1
                        parents.append(url)
                    }
                    continue
                }
                let error = errno
                guard !isLast && error == EEXIST else {
                    throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
                }
                // A parent another fixture made is shared until both are done. One
                // that was already there belongs to someone else and stays.
                if let users = Self.parentUsers[url.path] {
                    Self.parentUsers[url.path] = users + 1
                    parents.append(url)
                }
            }
            return url
        }
    }

    /// Makes a symbolic link at `relativePath` under the home folder. Its parent
    /// must come from an earlier `make`, so it can't be removed in the meantime.
    @discardableResult
    func link(_ relativePath: String, to destination: URL) throws -> URL {
        let url = home.appendingPathComponent(relativePath, isDirectory: true)
        try Self.lock.withLock {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
            owned.append(url)
        }
        return url
    }

    func remove() {
        Self.lock.withLock {
            owned.reversed().forEach { try? FileManager.default.removeItem(at: $0) }
            owned = []
            // A folder is reached after its parent, so the reverse order removes
            // children first. `rmdir` fails on a folder that isn't empty, which
            // leaves it alone.
            for parent in parents.reversed() {
                let users = (Self.parentUsers[parent.path] ?? 1) - 1
                if users > 0 {
                    Self.parentUsers[parent.path] = users
                    continue
                }
                Self.parentUsers[parent.path] = nil
                _ = rmdir(parent.path)
            }
            parents = []
        }
    }
}
