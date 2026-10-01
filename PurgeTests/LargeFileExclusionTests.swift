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
}
