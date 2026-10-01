import Foundation

/// The exclusion list as one directory walk sees it, built once per scan root.
///
/// `ExcludedPathsStore.isExcluded` locks the store, copies every key and resolves
/// symlinks on each call. That is fine for a few dozen scan rows but not for every
/// directory a home-folder walk visits. This type does that work once per root and
/// leaves the walk with one set lookup per directory or file.
///
/// Matching is on paths relative to the root, because the walk and the store do not
/// spell the same folder the same way. Store keys go through
/// `resolvingSymlinksInPath`, which turns `/private/var/…` into `/var/…`, while
/// `FileManager`'s enumerator hands back `/private/var/…` for that same root. A
/// symlinked `~/Documents` splits the same way. Relative to the root, both agree.
///
/// The walk only needs exact matches: it visits parents before children and skips
/// an excluded directory's descendants, so an ancestor match never comes up.
nonisolated struct ScanExclusions: Sendable {
    /// Store keys: standardized, symlink-resolved absolute paths.
    let keys: Set<String>

    static func current() -> ScanExclusions {
        ScanExclusions(keys: ExcludedPathsStore.allExcludedPaths())
    }

    func scoped(to root: URL) -> Scoped {
        scoped(resolvedRootPath: root.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    /// `resolvedRootPath` must be resolved the same way the store resolves its keys.
    func scoped(resolvedRootPath: String) -> Scoped {
        let resolvedPrefix = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"
        var excludesRoot = false
        var relativePaths: Set<String> = []
        for key in keys {
            if key == resolvedRootPath || resolvedPrefix.hasPrefix(key.hasSuffix("/") ? key : key + "/") {
                excludesRoot = true
            } else if key.hasPrefix(resolvedPrefix) {
                relativePaths.insert(String(key.dropFirst(resolvedPrefix.count)))
            }
        }
        return Scoped(excludesRoot: excludesRoot, relativePaths: relativePaths)
    }

    struct Scoped: Sendable {
        /// The root itself, or a folder above it, is excluded: skip the whole walk.
        let excludesRoot: Bool
        /// Excluded paths inside the root, relative to it (`Archive/2019`).
        let relativePaths: Set<String>

        var isEmpty: Bool { relativePaths.isEmpty }

        func contains(relativePath: Substring) -> Bool {
            relativePaths.contains(String(relativePath))
        }
    }
}
