import Foundation

/// Shared folder sizing so scans can call this from background tasks without hopping through `MainActor`.
nonisolated enum FolderSizing {
    nonisolated static let duChunkSize = 64
    /// Process-wide cap on concurrent `du` processes. `CacheScanner.runSizeJobs`
    /// fans out this many Swift tasks, each calling ``directorySizesForChunk``.
    nonisolated static let maxConcurrentDuChunks = 10

    /// Process-wide, deliberately **not** per call.
    ///
    /// A per-call semaphore caps one `directorySizes` invocation at ten `du` processes but
    /// says nothing about how many invocations run at once — N concurrent callers meant up
    /// to 10N subprocesses. `du` is I/O-bound on a single disk, so the useful limit is a
    /// total, and the scanners legitimately call this concurrently — including
    /// `directorySizesForChunk`, which used to skip the limiter and stack on top of it.
    private nonisolated static let duChunkLimiter = DispatchSemaphore(value: maxConcurrentDuChunks)

    /// How often a caller queued on `duChunkLimiter` re-checks for cancellation.
    private nonisolated static let limiterPollInterval: DispatchTimeInterval = .milliseconds(100)

    /// Runs right after a call takes a `du` permit. Only tests bind it: they cancel
    /// the calling task there, the one moment a cancelled call holds a permit it
    /// has to hand back (#189). Task-local, so it reaches only the task that bound it.
    @TaskLocal static var afterTakingPermit: (@Sendable () -> Void)? = nil

    /// A chunk walking a deep tree can legitimately take minutes, so this is loose. It exists
    /// only so a `du` that never returns cannot wedge the scan permanently.
    private static let duChunkTimeout: TimeInterval = 300

    /// Timed acquisition, not `wait()`. The limiter is process-wide, so this can be
    /// queued behind a permit held by an *unrelated* scan whose chunk runs all the
    /// way to `duChunkTimeout`. An indefinite wait would keep a cancelled scan
    /// parked here for that long — on a cooperative-pool thread, which is the
    /// resource the bounded fan-out in `DevScanner.buildProjectGroups` exists to
    /// protect.
    private nonisolated static func acquireDuPermit() -> Bool {
        var acquired = false
        while !acquired && !Task.isCancelled {
            acquired = duChunkLimiter.wait(timeout: .now() + limiterPollInterval) == .success
        }
        return acquired
    }

    nonisolated static func directorySizesForChunk(_ chunk: [URL]) -> [String: Int64] {
        guard !chunk.isEmpty else { return [:] }
        guard acquireDuPermit() else { return [:] }
        defer { duChunkLimiter.signal() }
        afterTakingPermit?()
        // Same window `directorySizes` already covers: cancelled between
        // taking a permit and starting work. Skip `du` and let `defer` give
        // the slot back — otherwise a superseded scan still walks for up to
        // `duChunkTimeout`.
        guard !Task.isCancelled else { return [:] }
        return runDuChunk(chunk)
    }

    /// Raw `du` for a chunk. Callers that already hold ``duChunkLimiter`` must use this
    /// rather than ``directorySizesForChunk``, which would try to take a second permit
    /// and deadlock once the cap is full.
    private nonisolated static func runDuChunk(_ chunk: [URL]) -> [String: Int64] {
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

    /// `onChunkDone` is told how many of the chunks have come back, out of how
    /// many, after each one; it is called on a sizing thread.
    nonisolated static func directorySizes(
        at urls: [URL],
        onChunkDone: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) -> [String: Int64] {
        guard !urls.isEmpty else { return [:] }

        var chunks: [[URL]] = []
        var index = 0
        while index < urls.count {
            chunks.append(Array(urls[index..<min(index + duChunkSize, urls.count)]))
            index += duChunkSize
        }

        var result: [String: Int64] = [:]
        var completedChunks = 0
        let lock = NSLock()
        let group = DispatchGroup()

        for chunk in chunks {
            if Task.isCancelled { break }

            guard acquireDuPermit() else { break }
            afterTakingPermit?()
            // Cancelled between acquiring and dispatching: the permit must go back, or a
            // process-wide slot is lost for the lifetime of the app.
            guard !Task.isCancelled else {
                duChunkLimiter.signal()
                break
            }

            group.enter()
            // A queue of its own, not `DispatchQueue.global`. Callers block a cooperative-pool
            // thread in `group.wait()` below, and the global queues get no new thread while
            // that pool is full. Once every pool thread was waiting here, no `du` ever started:
            // three parallel tests on a 3-core CI runner were enough. A serial queue made here
            // runs on an overcommit thread, which the system always grants.
            DispatchQueue(label: "purge.folder-sizing.du", qos: .utility).async {
                defer {
                    duChunkLimiter.signal()
                    group.leave()
                }
                let partial = runDuChunk(chunk)
                lock.lock()
                for (path, size) in partial {
                    result[path] = size
                }
                completedChunks += 1
                let done = completedChunks
                lock.unlock()
                onChunkDone?(done, chunks.count)
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

    /// Allocated bytes under `url`, and the latest access or change inside it,
    /// summed file by file in-process. Unlike `du`, this needs no subprocess and
    /// stops when the calling task is cancelled.
    ///
    /// `skipsPackages` leaves out nested packages. A virtual machine must pass
    /// false: its disk folders (Parallels' `.hdd`) can register as packages,
    /// and skipping them would leave out most of the bytes.
    nonisolated static func walkedSize(at url: URL, skipsPackages: Bool) -> (bytes: Int64, lastUsed: Date) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .contentAccessDateKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: skipsPackages ? [.skipsPackageDescendants] : []
        ) else { return (0, .distantPast) }

        var bytes: Int64 = 0
        var lastUsed = Date.distantPast
        while let next = enumerator.nextObject() {
            if Task.isCancelled { break }
            guard let fileURL = next as? URL,
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            lastUsed = max(lastUsed, max(
                values.contentAccessDate ?? .distantPast,
                values.contentModificationDate ?? .distantPast
            ))
        }
        return (bytes, lastUsed)
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
