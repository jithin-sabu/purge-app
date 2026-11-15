import Foundation
import Testing
@testable import Purge

/// Purge can't know what a modified app keeps in its cache folder. A user kept
/// their own files inside Spotify's cache, and a Safe clean took them (#3). The
/// fix is a per-path opt-out: once a folder is excluded, its row and everything
/// inside it stay out of every clean, Safe or not.
@MainActor
@Suite("An excluded cache folder is never cleaned")
struct ExcludedCacheFolderTests {
    @Test
    func excludedCacheRowLeavesTheOneClickClean() {
        // A path that is never created. The exclusion is saved in the test run's
        // scratch folder, not the user's own list.
        let folder = URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
            .appendingPathComponent("Library/Caches/com.example.modded-\(UUID().uuidString)", isDirectory: true)
        defer { ExcludedPathsStore.remove(path: folder) }
        var item = CacheItem(
            definitionKey: folder.lastPathComponent,
            location: CacheLocation(
                path: folder,
                sizeBytes: 1_000_000,
                lastModified: .distantPast,
                folderName: folder.lastPathComponent
            ),
            appName: "Modded Client",
            safetyInfo: SafetyInfo(level: .safe, headline: "Modded Client", explanation: "", recoverySteps: "", reinstallCommand: nil)
        )
        // As the background git check leaves a folder outside any repository.
        item.gitStatus = .clean
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        store.cacheItems = [item]
        #expect(store.manualSafeCleanupCandidates().map(\.path.path) == [folder.path])

        store.excludeFromScans(item)

        #expect(store.cacheItems.isEmpty)
        #expect(store.manualSafeCleanupCandidates().isEmpty)
        #expect(ExcludedPathsStore.isExcluded(folder.appendingPathComponent("Users/added-track.ogg")))
    }
}
