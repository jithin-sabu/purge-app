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

    /// `path` gives the new row the folder of an earlier one, as a rescan that
    /// finds the same folder at another level would.
    private static func row(_ level: SafetyLevel, path existing: CacheItem? = nil) -> CacheItem {
        let folder = existing?.path.lastPathComponent ?? "com.purge.test.unattended-\(UUID().uuidString)"
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

    // MARK: The first scheduled clean (#331)

    @Test func theFirstScheduledCleansListMovesNothing() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        let safe = Self.row(.safe)
        store.cacheItems = [safe, Self.row(.medium), Self.row(.unknown)]
        let preferences = ScheduledCleaningPreferenceStore(userDefaults: suite.defaults)
        preferences.isEnabled = true

        let result = await store.prepareScheduledCleanPreview(preferences: preferences)

        #expect(result == .presented)
        #expect(trash.trashedPaths.isEmpty)
        #expect(!store.isDeleting)
        let preview = try #require(store.scheduledCleanPreview)
        // Exactly what the clean would move: the Safe row, nothing else.
        #expect(preview.paths == [Self.path(safe)])
        #expect(!CleanupHistoryStore.shared.archive.entries.contains { entry in
            entry.deletedItems.contains { $0.path == Self.path(safe) }
        })
        store.scheduledCleanPreview = nil
    }

    @Test func aListThatIsOffShowsNothing() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        store.cacheItems = [Self.row(.safe)]
        let preferences = ScheduledCleaningPreferenceStore(userDefaults: suite.defaults)

        let result = await store.prepareScheduledCleanPreview(preferences: preferences)

        #expect(result == .skipped)
        #expect(store.scheduledCleanPreview == nil)
        #expect(scans.developerAccesses.isEmpty)
    }

    @Test func anEmptyListIsNotShown() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        store.cacheItems = [Self.row(.medium)]
        let preferences = ScheduledCleaningPreferenceStore(userDefaults: suite.defaults)
        preferences.isEnabled = true

        let result = await store.prepareScheduledCleanPreview(preferences: preferences)

        #expect(result == .nothingEligible)
        #expect(store.scheduledCleanPreview == nil)
    }

    /// The safety fact of #331: an approved list moves only rows the user saw
    /// that are still Safe. A Safe row that appeared after the list, and a shown
    /// row that is Check First now, both stay.
    @Test func anApprovedListMovesOnlyShownRowsThatAreStillSafe() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        let shown = Self.row(.safe)
        let demoted = Self.row(.safe)
        store.cacheItems = [shown, demoted]
        let preferences = ScheduledCleaningPreferenceStore(userDefaults: suite.defaults)
        preferences.isEnabled = true
        _ = await store.prepareScheduledCleanPreview(preferences: preferences)
        let preview = try #require(store.scheduledCleanPreview)
        #expect(preview.paths == [Self.path(shown), Self.path(demoted)])
        store.scheduledCleanPreview = nil

        // While the list was open: one shown row turned Check First, and a new
        // Safe row arrived.
        let arrived = Self.row(.safe)
        store.cacheItems = [shown, Self.row(.medium, path: demoted), arrived]
        let summary = await store.performApprovedScheduledClean(paths: preview.paths)

        #expect(trash.trashedPaths == [Self.path(shown)])
        #expect(summary.deletedCount == 1)
        #expect(!summary.skippedForAnotherClean)
        let entry = try #require(CleanupHistoryStore.shared.archive.entries.first { entry in
            entry.deletedItems.contains { $0.path == Self.path(shown) }
        })
        #expect(entry.trigger == .scheduled)
    }

    /// Clean in the list is the user's own click: an open review does not stop
    /// it, but a clean already running does.
    @Test func anApprovedListWaitsOnlyForARunningClean() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = makeStore(scans, trash: trash)
        let safe = Self.row(.safe)
        store.cacheItems = [safe]

        store.isDeleting = true
        let skipped = await store.performApprovedScheduledClean(paths: [Self.path(safe)])
        #expect(skipped.skippedForAnotherClean)
        #expect(trash.trashedPaths.isEmpty)
        store.isDeleting = false

        _ = store.beginInteractiveSafeCleanup(candidates: store.manualSafeCleanupCandidates(), reduceMotion: true)
        let moved = await store.performApprovedScheduledClean(paths: [Self.path(safe)])
        store.cancelInteractiveSafeCleanup()
        #expect(moved.deletedCount == 1)
        #expect(trash.trashedPaths == [Self.path(safe)])
    }
}
