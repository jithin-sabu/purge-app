import Foundation

/// Shared folder sizing so scans can call this from background tasks without hopping through `MainActor`.
enum FolderSizing {
    static let duChunkSize = 64
    private static let maxConcurrentDuChunks = 10

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
        let semaphore = DispatchSemaphore(value: maxConcurrentDuChunks)
        let group = DispatchGroup()

        for chunk in chunks {
            if Task.isCancelled { break }
            semaphore.wait()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    semaphore.signal()
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
