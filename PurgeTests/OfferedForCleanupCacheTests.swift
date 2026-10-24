import Foundation
import Testing
@testable import Purge

/// The verdict cache behind `isOfferedForCleanup` used to keep every path it ever
/// saw. It now starts over when full (#190), and a verdict read after that is the
/// same one.
@Suite("Offered-for-cleanup cache")
struct OfferedForCleanupCacheTests {
    @Test func cacheStaysWithinItsLimit() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cached = home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true)
        let before = DeletionSafetyPolicy.isOfferedForCleanup(cached)

        let base = URL(fileURLWithPath: "/private/tmp/purge-offered-cache-limit-test", isDirectory: true)
        for i in 0..<(DeletionSafetyPolicy.offeredForCleanupCacheLimit + 500) {
            _ = DeletionSafetyPolicy.isOfferedForCleanup(base.appendingPathComponent("item-\(i)"))
        }

        #expect(DeletionSafetyPolicy.offeredForCleanupCacheCount <= DeletionSafetyPolicy.offeredForCleanupCacheLimit)
        #expect(DeletionSafetyPolicy.isOfferedForCleanup(cached) == before)
    }
}
