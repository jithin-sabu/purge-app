import Foundation
import Testing
@testable import Purge

@Suite("Read-only cache folder inspector")
struct CacheFolderInspectorTests {
    @Test func listsOnlyUnknownDirectFolders() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let cache = home.appendingPathComponent(".cache", isDirectory: true)
        for name in ["unknown/nested", "known/data", "excluded", "unknown-private/secrets", "empty"] {
            try fm.createDirectory(at: cache.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data(repeating: 0x41, count: 8192).write(to: cache.appendingPathComponent("unknown/nested/data"))
        try Data(repeating: 0x42, count: 8192).write(to: cache.appendingPathComponent("unknown-private/secrets/data"))
        try Data().write(to: cache.appendingPathComponent("file"))
        try fm.createSymbolicLink(at: cache.appendingPathComponent("link"), withDestinationURL: cache.appendingPathComponent("unknown"))
        let result = CacheFolderInspector.inspect(
            at: cache,
            knownPaths: [cache.appendingPathComponent("known/data")],
            exclusions: ScanExclusions(keys: Set(["excluded", "unknown-private/secrets"].map {
                cache.appendingPathComponent($0).resolvingSymlinksInPath().path
            }))
        )
        guard case .folders(let folders) = result else { Issue.record("Expected folders"); return }
        #expect(folders.map(\.url.lastPathComponent) == ["unknown", "empty"])
        #expect((folders.first?.bytes ?? 0) > 0)
        #expect(folders.last?.bytes == 0)
    }

    @Test func doesNotFollowALinkAtTheCacheRoot() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let destination = home.appendingPathComponent("destination")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = home.appendingPathComponent(".cache")
        try fm.createSymbolicLink(at: link, withDestinationURL: destination)
        #expect(CacheFolderInspector.inspect(at: link, knownPaths: [], exclusions: ScanExclusions(keys: [])) == .unavailable)
    }
}
