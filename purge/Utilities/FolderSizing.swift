import Foundation

/// Shared folder sizing so scans can call this from background tasks without hopping through `MainActor`.
enum FolderSizing {
    static let duChunkSize = 64
    private static let maxConcurrentDuChunks = 10

    nonisolated static func directorySizesForChunk(_ chunk: [URL]) -> [String: Int64] {
        guard !chunk.isEmpty else { return [:] }

        var result: [String: Int64] = [:]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk"] + chunk.map { $0.standardizedFileURL.path }

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.split(separator: "\n") {
                guard let tab = line.firstIndex(of: "\t") else { continue }
                let kbStr = line[line.startIndex..<tab]
                let path = String(line[line.index(after: tab)...])
                if let kilobytes = Int64(kbStr) {
                    result[path] = kilobytes * 1024
                }
            }
        } catch {
            // Omit paths in this chunk; callers default to 0.
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
        directorySizes(at: [url])[url.standardizedFileURL.path] ?? 0
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
