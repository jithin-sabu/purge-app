import Foundation

/// `nonisolated` is load-bearing, not tidiness. The project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it this type — and the
/// `static run` below — are implicitly main-actor isolated, and the `Task.detached`
/// in `scanStream` immediately hops *back* to the main actor. A probe confirmed
/// `run` executing with `Thread.isMainThread == true`, i.e. the entire
/// home-directory walk was blocking the UI; it measured as a ~1.15s freeze on
/// first switch to the Large Files tab.
nonisolated final class LargeFileScanner {
    /// `roots` and `exclusions` default to the policy's home folders and the saved
    /// exclusion list. `isExcluded` is the final check on each file before it is
    /// listed and defaults to the store; tests pass their own.
    func scanStream(
        minBytes: Int64,
        staleDays: Int,
        roots: [URL]? = nil,
        exclusions: ScanExclusions? = nil,
        isExcluded: (@Sendable (URL) -> Bool)? = nil
    ) -> AsyncStream<LargeFile> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.run(
                    minBytes: minBytes,
                    staleDays: staleDays,
                    roots: roots,
                    exclusions: exclusions,
                    isExcluded: isExcluded ?? { ExcludedPathsStore.isExcluded($0) },
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// How many enumerator steps share one autorelease pool. `nextObject()` and
    /// `resourceValues` allocate Foundation objects per file; draining every step
    /// is slower, and never draining lets a Downloads walk hold megabytes of
    /// transients until the root finishes.
    private static let enumeratorAutoreleaseBatch = 256

    private static func run(
        minBytes: Int64,
        staleDays: Int,
        roots: [URL]?,
        exclusions: ScanExclusions?,
        isExcluded: @Sendable (URL) -> Bool,
        continuation: AsyncStream<LargeFile>.Continuation
    ) async {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let exclusions = exclusions ?? .current()
        let now = Date()
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .contentAccessDateKey, .contentModificationDateKey, .isPackageKey,
            .isUserImmutableKey, .isSystemImmutableKey
        ]

        for root in roots ?? LargeFileScanPolicy.scanRoots(home: home) {
            if Task.isCancelled { break }
            guard fm.fileExists(atPath: root.path) else { continue }
            // Folders the user excluded are never entered, not just hidden from the
            // results, so an excluded archive also stops costing scan time (#46).
            let excluded = exclusions.scoped(to: root)
            if excluded.excludesRoot { continue }
            // How the enumerator spells the root, taken from its first child rather
            // than from `root`: it can differ (`/private/var` for `/var`), and
            // matching is on the path below this prefix. See `ScanExclusions`.
            var walkedRootPrefix: String?

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            enumerateRoot: while true {
                let keepGoing: Bool = autoreleasepool {
                    for _ in 0..<enumeratorAutoreleaseBatch {
                        guard let next = enumerator.nextObject() else { return false }
                        if Task.isCancelled { return false }
                        guard let fileURL = next as? URL else { continue }

                        let values = try? fileURL.resourceValues(forKeys: resourceKeys)

                        var isUserExcluded: Bool {
                            guard !excluded.isEmpty else { return false }
                            if walkedRootPrefix == nil, enumerator.level == 1 {
                                walkedRootPrefix = fileURL.deletingLastPathComponent().path + "/"
                            }
                            let path = fileURL.path
                            guard let prefix = walkedRootPrefix, path.hasPrefix(prefix) else { return false }
                            return excluded.contains(relativePath: path.dropFirst(prefix.count))
                        }

                        if values?.isDirectory == true || values?.isPackage == true {
                            if LargeFileScanPolicy.isExcludedDirectory(fileURL) || isUserExcluded {
                                enumerator.skipDescendants()
                            }
                            continue
                        }

                        guard values?.isRegularFile == true else { continue }
                        if isUserExcluded { continue }

                        let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                        guard size >= minBytes else { continue }

                        let accessed = values?.contentAccessDate ?? .distantPast
                        let modified = values?.contentModificationDate ?? .distantPast
                        let lastUsed = max(accessed, modified)
                        if staleDays > 0 {
                            let days = Calendar.current.dateComponents([.day], from: lastUsed, to: now).day ?? 0
                            guard days >= staleDays else { continue }
                        }

                        // Never list a file the filesystem will refuse to give up — its own
                        // flags or its directory's. Offering it can only end in "couldn't be
                        // cleaned", so it does not belong in the list at all. The check runs
                        // last because it costs syscalls and only a handful of files, already
                        // past the size and staleness filters, get this far.
                        if FileProtection.blocksRemoval(fileURL) { continue }

                        // The skip above is the fast path, not the guarantee. It only
                        // knows the list as it was when this root started, and it
                        // misses a folder whose own entry couldn't be read (no
                        // `isDirectory`, so no `skipDescendants`). This asks the store,
                        // with symlinks resolved, about the few files that got this far.
                        // It runs here, off the main actor, so a list that changes
                        // mid-scan never costs the UI a check per file.
                        if isExcluded(fileURL) { continue }

                        continuation.yield(
                            LargeFile(
                                path: fileURL.standardizedFileURL,
                                sizeBytes: size,
                                lastUsed: lastUsed,
                                category: LargeFileCategory.category(forExtension: fileURL.pathExtension)
                            )
                        )
                    }
                    return true
                }
                if !keepGoing { break enumerateRoot }
            }
        }

        continuation.finish()
    }
}
