import Foundation
import Testing
@testable import Purge

/// `CacheScanner.runSizeJobs` fans out to `maxConcurrent = 10` Swift tasks, each calling
/// `FolderSizing.directorySizesForChunk` synchronously. On a 10-core machine that is exactly the
/// width of the cooperative thread pool, so every pool thread ends up inside `du`. Any sizing
/// implementation that needs a *second* thread to finish deadlocks there — the scan sticks at
/// "Scanning…" with zero items and never recovers. These tests run the real production function
/// under that fan-out.
@Suite("Folder sizing under scan fan-out")
struct FolderSizingConcurrencyTests {
    /// Matches `CacheScanner.runSizeJobs`.
    private static let scanConcurrency = 10

    private func makeTree(directories: Int, bytesEach: Int) throws -> (root: URL, paths: [URL]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("purge-sizing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let payload = Data(repeating: 0x41, count: bytesEach)
        var paths: [URL] = []
        for index in 0..<directories {
            let dir = root.appendingPathComponent("dir-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try payload.write(to: dir.appendingPathComponent("payload.bin"))
            paths.append(dir)
        }
        return (root, paths)
    }

    @Test("Every directory is measured when the whole pool is inside du")
    func measuresAllChunksUnderFanOut() async throws {
        let perChunk = FolderSizing.duChunkSize
        let chunkCount = Self.scanConcurrency * 2
        let (root, paths) = try makeTree(directories: perChunk * chunkCount, bytesEach: 8 * 1024)
        defer { try? FileManager.default.removeItem(at: root) }

        var chunks: [[URL]] = []
        var index = 0
        while index < paths.count {
            chunks.append(Array(paths[index..<min(index + perChunk, paths.count)]))
            index += perChunk
        }

        let merged = await withTaskGroup(
            of: [String: Int64].self,
            returning: [String: Int64].self
        ) { group in
            for chunk in chunks {
                group.addTask { FolderSizing.directorySizesForChunk(chunk) }
            }
            return await group.reduce(into: [:]) { $0.merge($1) { current, _ in current } }
        }

        #expect(merged.count == paths.count, "measured \(merged.count) of \(paths.count) directories")
        for path in paths {
            let key = path.standardizedFileURL.path
            #expect(merged[key] ?? 0 > 0, "no size for \(key)")
        }
    }

    /// `du` prints one "Permission denied" line per unreadable directory. That output lands on
    /// stderr, so a runner that leaves stderr undrained wedges the child on a full pipe once the
    /// tree is broad enough — the same deadlock as stdout, just quieter.
    @Test("Directories that cannot be read do not stall the chunk")
    func toleratesUnreadableDirectories() async throws {
        let (root, paths) = try makeTree(directories: 40, bytesEach: 4 * 1024)
        defer {
            for path in paths { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path) }
            try? FileManager.default.removeItem(at: root)
        }

        // Make half the tree unreadable so du has plenty to complain about.
        for path in paths.enumerated() where path.offset.isMultiple(of: 2) {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.element.path)
        }

        let sizes = FolderSizing.directorySizesForChunk(paths)

        // The readable half must still come back; du's exit status is non-zero either way.
        let readable = paths.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
        for path in readable {
            #expect(sizes[path.standardizedFileURL.path] ?? 0 > 0, "lost \(path.lastPathComponent)")
        }
    }
}
