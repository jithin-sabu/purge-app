import Foundation

/// Folders a test makes in the real home folder. The deletion gate only lets agent
/// worktrees through there, so some tests can't use a temporary home.
///
/// `remove()` takes away only what this made: each folder or link from `make` and
/// `link` in full, then every parent folder it had to create, deepest first and
/// only while empty. A folder that was already there, or that a tool or another
/// test put something in meanwhile, stays.
///
/// Call `remove()` in a `defer` placed before the first `make`, so the parents of
/// a `make` that throws halfway are removed too.
final class RealHomeFolders {
    let home: URL
    /// Made with a name no one else uses, so they are removed in full.
    private var owned: [URL] = []
    /// Made on the way to an owned folder, in the order they were made.
    private var parents: [URL] = []

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
        var url = home
        for (index, name) in components.enumerated() {
            url.appendPathComponent(name, isDirectory: true)
            let isLast = index == components.count - 1
            if mkdir(url.path, 0o755) == 0 {
                if isLast { owned.append(url) } else { parents.append(url) }
                continue
            }
            let error = errno
            // A parent that is already there belongs to someone else and stays.
            if !isLast && error == EEXIST { continue }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return url
    }

    /// Makes a symbolic link at `relativePath` under the home folder, whose parent
    /// must already exist.
    @discardableResult
    func link(_ relativePath: String, to destination: URL) throws -> URL {
        let url = home.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        owned.append(url)
        return url
    }

    func remove() {
        owned.reversed().forEach { try? FileManager.default.removeItem(at: $0) }
        owned = []
        // A folder is made after its parent, so the reverse order removes children
        // first. `rmdir` fails on a folder that isn't empty, which leaves it alone.
        parents.reversed().forEach { _ = rmdir($0.path) }
        parents = []
    }
}
