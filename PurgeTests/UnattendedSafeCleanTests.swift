import Foundation
import Testing
@testable import Purge

/// The cleans that move things without a confirmation: the Overview's Clean Safe
/// Items, the menu bar's Clean, and the scheduled clean. Each moves Safe rows only,
/// and nothing a later check refuses. Nothing tested them end to end (#189).
///
/// Every row is a folder under `~/Library/Caches` that is never made, and the store
/// cleans through a fake Trash that moves nothing (#171). Its defaults are
/// throwaway, and its History lives in the test run's scratch folder.
@MainActor
@Suite("Cleans that run without asking")
struct UnattendedSafeCleanTests {
    private let suite = ThrowawayDefaults()

    private static func row(_ level: SafetyLevel) -> CacheItem {
        let folder = "com.purge.test.unattended-\(UUID().uuidString)"
        return CacheItem(
            definitionKey: folder,
            location: CacheLocation(
                path: URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
                    .appendingPathComponent("Library/Caches/\(folder)", isDirectory: true),
                sizeBytes: 1_000_000,
                lastModified: .distantPast,
                folderName: folder
            ),
            appName: folder,
            safetyInfo: SafetyInfo(level: level, headline: folder, explanation: "", recoverySteps: "", reinstallCommand: nil),
            gitStatus: .clean
        )
    }

    private static func path(_ row: CacheItem) -> String {
        row.path.standardizedFileURL.path
    }

    private func makeStore(_ scans: FakeScans, trash: FakeTrash) -> PurgeStore {
        scans.hasAccess = true
        return scans.makeStore(fileDeleter: FileDeleter(trash: trash.trash))
    }

    // MARK: Clean Safe Items

    @Test func cleanSafeItemsMovesSafeRowsOnly() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        let safe = Self.row(.safe)
        store.cacheItems = [safe, Self.row(.medium), Self.row(.unknown)]

        let clean = try #require(store.cleanSafeItemsFromOverview(reduceMotion: true))
        let summary = await clean.value

        #expect(trash.trashedPaths == [Self.path(safe)])
        #expect(summary.deletedCount == 1)
        #expect(summary.movedToTrashCount == 1)
        #expect(summary.bytesMovedToTrash == 1_000_000)
        #expect(!summary.failed)
        #expect(!store.isDeleting)
    }

    /// The list a clean is handed can be older than the user's choices. A folder
    /// excluded since it was made stays where it is.
    @Test func aFolderExcludedSinceTheListWasMadeStays() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        let excluded = Self.row(.safe)
        let moved = Self.row(.safe)
        store.cacheItems = [excluded, moved]
        let candidates = store.manualSafeCleanupCandidates()
        try #require(candidates.count == 2)

        // Saved in the test run's scratch folder, not the user's own list.
        ExcludedPathsStore.write(path: excluded.path, displayName: "Excluded")
        defer { ExcludedPathsStore.remove(path: excluded.path) }
        let summary = await store.performManualSafeCleanNow(pinnedCandidates: candidates)

        #expect(trash.trashedPaths == [Self.path(moved)])
        #expect(summary.deletedCount == 1)
    }

    // MARK: The menu bar's Clean

    /// With no list handed to it, the clean scans Dev Tools again and reads each
    /// row's git status afresh. A row that changed since the scan stays.
    @Test func theMenuBarCleanRereadsEachRowBeforeItMoves() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        let clean = Self.row(.safe)
        let changed = Self.row(.safe)
        store.cacheItems = [clean, changed]
        scans.gitAnswers[Self.path(changed)] = .dirty

        let summary = await store.performManualSafeCleanNow()

        #expect(scans.developerAccesses.count == 1)
        #expect(trash.trashedPaths == [Self.path(clean)])
        #expect(summary.deletedCount == 1)
        #expect(!summary.failed)
    }

    // MARK: The scheduled clean

    @Test func aScheduledCleanThatIsOffMovesNothing() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        store.cacheItems = [Self.row(.safe)]
        let preferences = ScheduledCleaningPreferenceStore(userDefaults: suite.defaults)

        let summary = await store.performScheduledClean(preferences: preferences)

        #expect(!preferences.isEnabled)
        #expect(trash.trashedPaths.isEmpty)
        #expect(summary.deletedCount == 0)
        // It did not even scan.
        #expect(scans.developerAccesses.isEmpty)
    }

    @Test func aScheduledCleanMovesSafeRowsOnlyAndIsRecordedAsScheduled() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        let safe = Self.row(.safe)
        store.cacheItems = [safe, Self.row(.medium)]
        let preferences = ScheduledCleaningPreferenceStore(userDefaults: suite.defaults)
        preferences.isEnabled = true

        let summary = await store.performScheduledClean(preferences: preferences)

        #expect(trash.trashedPaths == [Self.path(safe)])
        #expect(summary.deletedCount == 1)
        #expect(summary.bytesMovedToTrash == 1_000_000)
        #expect(!summary.failed)
        #expect(!summary.skippedForAnotherClean)
        let entry = try #require(CleanupHistoryStore.shared.archive.entries.first { entry in
            entry.deletedItems.contains { $0.path == Self.path(safe) }
        })
        #expect(entry.trigger == .scheduled)
    }
}
