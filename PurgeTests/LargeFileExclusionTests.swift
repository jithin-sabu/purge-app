import Foundation
import Testing
@testable import Purge

@Suite("Large Files skips excluded folders and files (#46)")
struct LargeFileExclusionTests {
    // MARK: - ScanExclusions

    @Test
    func keyInsideRootBecomesRelativeToIt() {
        let scoped = ScanExclusions(keys: ["/var/home/Documents/Archive", "/var/home/Documents/a/b.mov"])
            .scoped(resolvedRootPath: "/var/home/Documents")
        #expect(!scoped.excludesRoot)
        #expect(scoped.relativePaths == ["Archive", "a/b.mov"])
    }

    @Test
    func rootOrAncestorExclusionSkipsTheWholeRoot() {
        #expect(ScanExclusions(keys: ["/Users/me/Movies"]).scoped(resolvedRootPath: "/Users/me/Movies").excludesRoot)
        #expect(ScanExclusions(keys: ["/Users/me"]).scoped(resolvedRootPath: "/Users/me/Movies").excludesRoot)
    }

    /// `/Users/me/Movie` is not a parent of `/Users/me/Movies`, and a sibling folder
    /// must not leak into this root's set.
    @Test
    func prefixSiblingsDoNotMatch() {
        let scoped = ScanExclusions(keys: ["/Users/me/Movie", "/Users/me/Music/Archive"])
            .scoped(resolvedRootPath: "/Users/me/Movies")
        #expect(!scoped.excludesRoot)
        #expect(scoped.isEmpty)
    }

    @Test
    func coversMatchesThePathAndAnythingBelowIt() {
        let exclusions = ScanExclusions(keys: ["/Users/me/Movies/Archive"])
        #expect(exclusions.covers(path: "/Users/me/Movies/Archive"))
        #expect(exclusions.covers(path: "/Users/me/Movies/Archive/2019/film.mov"))
        #expect(!exclusions.covers(path: "/Users/me/Movies/Archived/film.mov"))
        #expect(!exclusions.covers(path: "/Users/me/Movies"))
        #expect(!ScanExclusions(keys: []).covers(path: "/Users/me/Movies/Archive"))
    }

    // MARK: - Scanner walk

    /// A throwaway root under the temporary directory. That directory sits behind
    /// the `/var` → `/private/var` symlink: the enumerator yields `/private/var/…`
    /// while store keys say `/var/…`, the same split a symlinked `~/Documents` would
    /// cause. The first version of the matcher compared absolute paths and failed
    /// exactly here.
    private func makeRoot(files: [String]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("purge-exclude-\(UUID().uuidString)", isDirectory: true)
        for relative in files {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x01, count: 4096).write(to: url)
        }
        return root
    }

    private func scan(root: URL, excluding relatives: [String]) async -> Set<String> {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys = Set(relatives.map { resolvedRoot.appendingPathComponent($0).path })
        let stream = LargeFileScanner().scanStream(
            minBytes: 1,
            staleDays: 0,
            roots: [root],
            exclusions: ScanExclusions(keys: keys)
        )
        return await collect(stream, under: root)
    }

    private func collect(_ stream: AsyncStream<LargeFile>, under root: URL) async -> Set<String> {
        var found: Set<String> = []
        let rootName = root.lastPathComponent + "/"
        for await file in stream {
            let path = file.path.path
            guard let range = path.range(of: rootName) else { continue }
            found.insert(String(path[range.upperBound...]))
        }
        return found
    }

    @Test
    func excludedFolderAndFileAreNeverListed() async throws {
        let root = try makeRoot(files: [
            "keep.bin",
            "skip.bin",
            "Archive/old.bin",
            "Archive/Deep/older.bin",
            "Archived/neighbour.bin",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let found = await scan(root: root, excluding: ["Archive", "skip.bin"])

        #expect(found == ["keep.bin", "Archived/neighbour.bin"])
    }

    @Test
    func excludingTheRootListsNothing() async throws {
        let root = try makeRoot(files: ["a.bin", "Sub/b.bin"])
        defer { try? FileManager.default.removeItem(at: root) }

        let found = await scan(root: root, excluding: [""])

        #expect(found.isEmpty)
    }

    @Test
    func noExclusionsListsEverything() async throws {
        let root = try makeRoot(files: ["a.bin", "Sub/b.bin"])
        defer { try? FileManager.default.removeItem(at: root) }

        let found = await scan(root: root, excluding: [])

        #expect(found == ["a.bin", "Sub/b.bin"])
    }

    /// The walk's skip only knows the list it started with, and misses a folder
    /// whose own entry can't be read. The final check before a file is listed is
    /// what catches both, so it alone must keep an excluded folder's files out.
    @Test
    func finalCheckDropsFilesTheWalkDidNotSkip() async throws {
        let root = try makeRoot(files: ["keep.bin", "Archive/old.bin", "Archive/Deep/older.bin"])
        defer { try? FileManager.default.removeItem(at: root) }

        let stream = LargeFileScanner().scanStream(
            minBytes: 1,
            staleDays: 0,
            roots: [root],
            exclusions: ScanExclusions(keys: []),
            isExcluded: { $0.pathComponents.contains("Archive") }
        )

        #expect(await collect(stream, under: root) == ["keep.bin"])
    }
}
