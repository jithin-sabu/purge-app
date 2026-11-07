import Foundation

/// Shared folder sizing so scans can call this from background tasks without hopping through `MainActor`.
nonisolated enum FolderSizing {
    nonisolated static let duChunkSize = 64
    /// Process-wide cap on concurrent `du` processes. `CacheScanner.runSizeJobs`
    /// fans out this many Swift tasks, each calling ``directorySizesForChunk``.
    ///
    /// Four, not more. Scans now hand every `du` a few folders, so the cap is
    /// what is really in use. Measured on a 10-core M4: four ran every scan as
    /// fast as ten, and the Everything else walk took 23 s against 41 s with
    /// ten, which evicted each other's folder data from memory. Fewer `du`
    /// processes also keep the rest of the Mac responsive while a scan runs.
    nonisolated static let maxConcurrentDuChunks = 4

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

    /// How a call's folders are shared out between `du` processes.
    nonisolated enum Split: Sendable {
        /// Up to `duChunkSize` folders per `du`. One `du` counts a hard-linked
        /// file once across all its folders, under the first folder that holds
        /// it. The Trash total keeps this.
        case fewest
        /// A few folders per `du`, one each for a list of `duChunkSize` or fewer,
        /// so up to `maxConcurrentDuChunks` walk side by side. A scan of fewer than
        /// `duChunkSize` folders used to walk them all in one `du`, one after
        /// another, on one core.
        ///
        /// Each folder's size is then its own: a file hard-linked into two folders
        /// sized by different `du` runs counts in both. Scan sizes are what a
        /// clean reports as freed and what Cleanup History records, so cleaning
        /// two such folders together counts the shared bytes twice. No safety
        /// level or gate reads these sizes.
        case spread
    }

    /// With `.spread`, each process slot gets about this many chunks, so one
    /// big folder holds up only its own short chunk, not a long one.
    private nonisolated static let spreadChunksPerSlot = 3

    /// `items` in order, cut into the chunks `split` gives each `du` process.
    nonisolated static func chunks<T>(of items: [T], split: Split) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let size: Int
        switch split {
        case .fewest:
            size = duChunkSize
        case .spread:
            // Up to `duChunkSize` folders, one `du` each: the next free slot takes
            // the next folder, so one big folder holds up nothing else.
            guard items.count > duChunkSize else { return items.map { [$0] } }
            let target = maxConcurrentDuChunks * spreadChunksPerSlot
            size = max(1, min(duChunkSize, (items.count + target - 1) / target))
        }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
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
    /// `staysOnVolume` passes `-x`, so `du` does not walk into another file
    /// system mounted inside a folder.
    private nonisolated static func runDuChunk(_ chunk: [URL], staysOnVolume: Bool = false) -> [String: Int64] {
        // `du` writes one "Permission denied" line per unreadable directory, so stderr can run
        // to megabytes on a broad scan. ProcessRunner drains it concurrently; leaving it
        // undrained would block `du` on a full pipe and hang the read below.
        guard let output = ProcessRunner.run(
            executablePath: "/usr/bin/du",
            arguments: (staysOnVolume ? ["-skx"] : ["-sk"]) + chunk.map { $0.standardizedFileURL.path },
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
    /// many, after each one, and `onChunkSizes` gets each chunk's sizes as it
    /// lands; both are called on a sizing thread. Scans pass `.spread`; see `Split`.
    /// `staysOnVolume` leaves out file systems mounted inside the folders, such
    /// as the FSKit view of a paired iPhone in `~/Library/Developer/CoreDevice`.
    nonisolated static func directorySizes(
        at urls: [URL],
        split: Split = .fewest,
        staysOnVolume: Bool = false,
        onChunkSizes: (@Sendable ([String: Int64]) -> Void)? = nil,
        onChunkDone: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) -> [String: Int64] {
        guard !urls.isEmpty else { return [:] }

        let chunks = Self.chunks(of: urls, split: split)
        // A scan's `du` runs at the priority of the scan that asked, so a scan
        // someone is waiting on isn't held back by a busy Mac. Everything else
        // (the Trash total, a deletion's report) stays in the background.
        let qos: DispatchQoS
        switch split {
        case .spread: qos = .unspecified
        case .fewest: qos = .utility
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
            DispatchQueue(label: "purge.folder-sizing.du", qos: qos).async {
                defer {
                    duChunkLimiter.signal()
                    group.leave()
                }
                let partial = runDuChunk(chunk, staysOnVolume: staysOnVolume)
                lock.lock()
                for (path, size) in partial {
                    result[path] = size
                }
                completedChunks += 1
                let done = completedChunks
                lock.unlock()
                onChunkSizes?(partial)
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
    nonisolated static func directoryByteSizeIfMeasurable(at url: URL, staysOnVolume: Bool = false) -> Int64? {
        directorySizes(at: [url], staysOnVolume: staysOnVolume)[url.standardizedFileURL.path]
    }

    /// Allocated bytes under `url`, and the latest access or change inside it,
    /// summed file by file in-process. Unlike `du`, this needs no subprocess and
    /// stops when the calling task is cancelled.
    ///
    /// `skipsPackages` leaves out nested packages. A virtual machine must pass
    /// false: its disk folders (Parallels' `.hdd`) can register as packages,
    /// and skipping them would leave out most of the bytes.
    ///
    /// `isCancelled` is asked between files. Work running outside a task, such as
    /// on `ConcurrentMap`'s threads, passes its own, since `Task.isCancelled` is
    /// always false there.
    nonisolated static func walkedSize(
        at url: URL,
        skipsPackages: Bool,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> (bytes: Int64, lastUsed: Date) {
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
            if isCancelled() { break }
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
