import Foundation
import Testing
@testable import Purge

/// `FileDeleter(home:)` lets tests point the user-selected gates at a temporary
/// home (#171). The cache route must not follow it: the allowlist knows only the
/// real home, and a cache folder somewhere else is not offered.
@Suite("FileDeleter's home reaches only the user-selected gates")
struct FileDeleterHomeTests {
    @MainActor
    @Test func cacheRouteIgnoresAnInjectedHome() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("purgetest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/com.purgetest.app", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([0x00]).write(to: cache.appendingPathComponent("blob"))

        let trash = FakeTrash()
        let report = try await FileDeleter(home: home, trash: trash.trash).deleteItems(
            at: [cache],
            pathToExpectedSizeBytes: [cache.standardizedFileURL.path: 1]
        )

        #expect(report.deletedItems.isEmpty)
        #expect(report.bytesMovedToTrash == 0)
        #expect(trash.trashedPaths.isEmpty)
    }
}
