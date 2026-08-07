import Foundation

nonisolated final class LargeFileScanner {
    /// Records which thread the walk actually ran on, for the regression test.
    ///
    /// This needs a runtime probe rather than a compile-time guarantee: the
    /// project builds in Swift 5 language mode, where isolation is not
    /// enforced, so dropping `nonisolated` from this class silently moves the
    /// whole filesystem walk back onto the main thread and nothing fails to
    /// compile. Written once per scan, read only by tests.
    nonisolated(unsafe) static var ranOnMainThread: Bool?

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
            .contentAccessDateKey, .contentModificationDateKey, .isPackageKey
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
                if ranOnMainThread == nil { ranOnMainThread = pthread_main_np() != 0 }
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
