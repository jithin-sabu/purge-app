import Foundation

/// Shared folder sizing so scans can call this from background tasks without hopping through `MainActor`.
enum FolderSizing {
    nonisolated static let duChunkSize = 64
    private static let maxConcurrentDuChunks = 10

    /// Process-wide, deliberately **not** per call.
    ///
    /// A per-call semaphore caps one `directorySizes` invocation at ten `du` processes but
    /// says nothing about how many invocations run at once — N concurrent callers meant up
    /// to 10N subprocesses. `du` is I/O-bound on a single disk, so the useful limit is a
    /// total, and the scanners legitimately call this concurrently.
    private nonisolated static let duChunkLimiter = DispatchSemaphore(value: maxConcurrentDuChunks)

    /// How often a caller queued on `duChunkLimiter` re-checks for cancellation.
    private nonisolated static let limiterPollInterval: DispatchTimeInterval = .milliseconds(100)

    /// A chunk walking a deep tree can legitimately take minutes, so this is loose. It exists
    /// only so a `du` that never returns cannot wedge the scan permanently.
    private static let duChunkTimeout: TimeInterval = 300

    nonisolated static func directorySizesForChunk(_ chunk: [URL]) -> [String: Int64] {
        guard !chunk.isEmpty else { return [:] }

        // `du` writes one "Permission denied" line per unreadable directory, so stderr can run
        // to megabytes on a broad scan. ProcessRunner drains it concurrently; leaving it
        // undrained would block `du` on a full pipe and hang the read below.
        guard let output = ProcessRunner.run(
            executablePath: "/usr/bin/du",
            arguments: ["-sk"] + chunk.map { $0.standardizedFileURL.path },
            timeout: duChunkTimeout
        ) else {
            // Omit paths in this chunk; callers default to 0.
            return [:]
        }

        // Partial output from a timed-out or non-zero run is still worth keeping: `du` prints
        // each total as it finishes, and a denied subpath makes it exit non-zero regardless.
        var result: [String: Int64] = [:]
        for line in output.stdoutText.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let kbStr = line[line.startIndex..<tab]
            let path = String(line[line.index(after: tab)...])
            if let kilobytes = Int64(kbStr) {
                result[path] = kilobytes * 1024
            }
        }

        return result
    }

    nonisolated static func directorySizes(at urls: [URL]) -> [String: Int64] {
        guard !urls.isEmpty else { return [:] }

        var chunks: [[URL]] = []
        var index = 0
        while index < urls.count {
            chunks.append(Array(urls[index..<min(index + duChunkSize, urls.count)]))
            index += duChunkSize
        }

        var result: [String: Int64] = [:]
        let lock = NSLock()
        let group = DispatchGroup()

        for chunk in chunks {
            if Task.isCancelled { break }

            // Timed acquisition, not `wait()`. The limiter is process-wide, so this can be
            // queued behind a permit held by an *unrelated* scan whose chunk runs all the
            // way to `duChunkTimeout`. An indefinite wait would keep a cancelled scan
            // parked here for that long — on a cooperative-pool thread, which is the
            // resource the bounded fan-out in `DevScanner.buildProjectGroups` exists to
            // protect.
            var acquired = false
            while !acquired && !Task.isCancelled {
                acquired = duChunkLimiter.wait(timeout: .now() + limiterPollInterval) == .success
            }
            guard acquired else { break }
            // Cancelled between acquiring and dispatching: the permit must go back, or a
            // process-wide slot is lost for the lifetime of the app.
            guard !Task.isCancelled else {
                duChunkLimiter.signal()
                break
            }

            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    duChunkLimiter.signal()
                    group.leave()
                }
                let partial = directorySizesForChunk(chunk)
                lock.lock()
                for (path, size) in partial {
                    result[path] = size
                }
                lock.unlock()
            }
        }

        group.wait()
        return result
    }

    nonisolated static func directoryByteSize(at url: URL) -> Int64 {
        directoryByteSizeIfMeasurable(at: url) ?? 0
    }

    /// `nil` when `du` produced no reading for `url` at all — it was denied, interrupted, or
    /// never ran. That is a different fact from `0`, which `du` prints only for a directory
    /// it read and found empty, and callers that must tell "empty" from "could not look"
    /// (the trash total, where 0 is a claim about the user's files) need the distinction.
    nonisolated static func directoryByteSizeIfMeasurable(at url: URL) -> Int64? {
        directorySizes(at: [url])[url.standardizedFileURL.path]
    }

    nonisolated static func singleFileSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return Int64(size)
    }

    nonisolated static func contentModificationDate(at url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
