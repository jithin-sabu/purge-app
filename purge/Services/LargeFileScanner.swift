import Foundation

/// `nonisolated` is load-bearing, not tidiness. The project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it this type — and the
/// `static run` below — are implicitly main-actor isolated, and the `Task.detached`
/// in `scanStream` immediately hops *back* to the main actor. A probe confirmed
/// `run` executing with `Thread.isMainThread == true`, i.e. the entire
/// home-directory walk was blocking the UI; it measured as a ~1.15s freeze on
/// first switch to the Large Files tab.
nonisolated final class LargeFileScanner {
    func scanStream(minBytes: Int64, staleDays: Int) -> AsyncStream<LargeFile> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.run(minBytes: minBytes, staleDays: staleDays, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        minBytes: Int64,
        staleDays: Int,
        continuation: AsyncStream<LargeFile>.Continuation
    ) async {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let now = Date()
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .contentAccessDateKey, .contentModificationDateKey, .isPackageKey,
            .isUserImmutableKey, .isSystemImmutableKey
        ]

        for root in LargeFileScanPolicy.scanRoots(home: home) {
            if Task.isCancelled { break }
            guard fm.fileExists(atPath: root.path) else { continue }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let next = enumerator.nextObject() {
                if Task.isCancelled { break }
                guard let fileURL = next as? URL else { continue }

                let values = try? fileURL.resourceValues(forKeys: resourceKeys)

                if values?.isDirectory == true || values?.isPackage == true {
                    if LargeFileScanPolicy.isExcludedDirectory(fileURL) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                guard values?.isRegularFile == true else { continue }

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

                continuation.yield(
                    LargeFile(
                        path: fileURL.standardizedFileURL,
                        sizeBytes: size,
                        lastUsed: lastUsed,
                        category: LargeFileCategory.category(forExtension: fileURL.pathExtension)
                    )
                )
            }
        }

        continuation.finish()
    }
}
