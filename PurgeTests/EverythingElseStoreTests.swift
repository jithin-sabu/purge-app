import Foundation
import Testing
@testable import Purge

/// The Everything else walk in the store (#159, #220): it runs on demand as its
/// own scan-queue step, never at launch, the groups fill in as roots finish, and
/// stopping it touches nothing else in the queue. Driven with `FakeScans`, so
/// nothing here walks this Mac.
@MainActor
@Suite("Everything else in the store")
struct EverythingElseStoreTests {
    private let gb: Int64 = 1_000_000_000

    private func root(_ group: EverythingElseGroup, _ path: String) -> EverythingElseMeasureRoot {
        EverythingElseMeasureRoot(group: group, url: URL(fileURLWithPath: path, isDirectory: true), kind: .children, isLockedWithoutAccess: false)
    }

    /// Scan Everything stops a walk that is running: the queue runs one step at
    /// a time, and a cache scan must not wait minutes behind a walk that feeds
    /// no category. The page offers to measure again.
    @Test func scanEverythingStopsARunningWalk() async {
        let fake = FakeScans()
        fake.hasAccess = true
        fake.holdsEverythingElse = true
        let store = fake.makeStore()
        store.showEverythingElsePage()
        #expect(await eventually { store.scanQueue.active == .everythingElse })

        store.scanEverything()
        #expect(await eventually { isIdle(store) })
        #expect(fake.events.contains("general full"))
        #expect(store.everythingElsePhase == .notMeasured)
        fake.cleanUp()
    }

    @Test func theLaunchScanAndScanEverythingLeaveItAlone() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        store.startLaunchScans()
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses.isEmpty)

        store.scanEverything()
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses.isEmpty)
        #expect(store.everythingElseMeasurement == nil)
        #expect(store.everythingElsePhase == .notMeasured)
        fake.cleanUp()
    }

    @Test func openingThePageMeasuresOnceThisSession() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        store.showEverythingElsePage()
        #expect(store.overviewPage == .everythingElse)
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses == [.limited])
        #expect(store.everythingElsePhase == .ready)
        #expect(store.everythingElseMeasurement?.isComplete == true)

        // Coming back to the page reuses this session's measure.
        store.showOverviewSummary()
        store.showEverythingElsePage()
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses == [.limited])

        // Measure again is a fresh walk.
        store.measureEverythingElseAgain()
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses == [.limited, .limited])
        fake.cleanUp()
    }

    @Test func aWalkWithoutAccessIsRedoneOnceAccessLands() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        store.showEverythingElsePage()
        #expect(await eventually { isIdle(store) })
        #expect(store.hasSessionResults(for: .everythingElse))

        fake.hasAccess = true
        store.refreshPermission()
        // The locked groups can be read now, so the old walk is out of date.
        #expect(!store.hasSessionResults(for: .everythingElse))
        store.showEverythingElsePage()
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses == [.limited, .full])
        #expect(store.hasSessionResults(for: .everythingElse))
        fake.cleanUp()
    }

    @Test func groupsFillInAsRootsFinishAndTheFigureLandsAtTheEnd() async {
        let fake = FakeScans()
        fake.hasAccess = true
        fake.holdsEverythingElse = true
        let store = fake.makeStore()
        let support = root(.appData, "/Users/alice/Library/Application Support")
        let caches = root(.protectedCaches, "/Users/alice/Library/Caches")
        fake.everythingElseEvents = [.planned([support, caches]), .macOS(14 * gb)]
        store.showEverythingElsePage()
        #expect(await eventually { store.everythingElseMeasurement?.macOSBytes == 14 * gb })
        #expect(store.everythingElsePhase == .measuring)
        #expect(store.everythingElseMeasurement?.isComplete == false)

        fake.yieldEverythingElse([.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/CoreAIKit", bytes: 66 * gb)
        ], looseFileBytes: 0))])
        #expect(await eventually { store.everythingElseMeasurement?.measuredRoots.count == 1 })
        let partial = store.everythingElseBreakdown(totalBytes: 1000 * gb, freeBytes: 500 * gb, trashBytes: 0)
        #expect(partial?[.appData]?.bytes == 66 * gb)
        #expect(partial?[.appData]?.isFinished == true)
        #expect(partial?[.protectedCaches]?.isFinished == false)
        #expect(partial?.isComplete == false)

        fake.finishHeldEverythingElse()
        #expect(await eventually { isIdle(store) })
        let done = store.everythingElseBreakdown(totalBytes: 1000 * gb, freeBytes: 500 * gb, trashBytes: 2 * gb)
        #expect(done?.isComplete == true)
        #expect(done?[.protectedCaches]?.isFinished == true)
        #expect(done?.everythingElseBytes == 500 * gb)
        #expect(done?.systemDataBytes == 500 * gb - 66 * gb - 14 * gb - 2 * gb)
        #expect(store.everythingElsePhase == .ready)
        #expect(store.hasSessionResults(for: .everythingElse))
        fake.cleanUp()
    }

    @Test func stopEndsTheWalkAndLeavesTheRestOfTheQueue() async {
        let fake = FakeScans()
        fake.hasAccess = true
        fake.holdsEverythingElse = true
        let store = fake.makeStore()
        store.showEverythingElsePage()
        #expect(await eventually { store.scanQueue.active == .everythingElse })
        store.requestScan(.largeFiles)
        #expect(store.scanQueue.isQueued(.largeFiles))

        store.stopEverythingElse()
        #expect(await eventually { isIdle(store) })
        // Large Files still ran after the walk stopped.
        #expect(fake.events.contains("step largeFiles"))
        // Nothing half-measured stays behind.
        #expect(store.everythingElseMeasurement == nil)
        #expect(!store.hasSessionResults(for: .everythingElse))
        #expect(store.everythingElsePhase == .notMeasured)
        fake.cleanUp()
    }

    @Test func stopCancelsAWalkThatIsStillWaiting() async {
        let fake = FakeScans()
        fake.hasAccess = true
        fake.holdsFullAccessSteps = true
        let store = fake.makeStore()
        store.requestScan(.largeFiles)
        #expect(await eventually { fake.log == ["step largeFiles"] })
        store.showEverythingElsePage()
        #expect(store.everythingElsePhase == .waiting)

        store.stopEverythingElse()
        #expect(store.everythingElsePhase == .notMeasured)
        #expect(store.scanQueue.active == .largeFiles)
        fake.finishHeldSteps()
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses.isEmpty)
        fake.cleanUp()
    }

    @Test func stoppingAMeasureAgainBringsBackTheLastFinishedWalk() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        let support = root(.appData, "/Users/alice/Library/Application Support")
        fake.everythingElseEvents = [.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/CoreAIKit", bytes: 66 * gb)
        ], looseFileBytes: 0))]
        store.showEverythingElsePage()
        #expect(await eventually { isIdle(store) && store.everythingElsePhase == .ready })

        fake.everythingElseEvents = []
        fake.holdsEverythingElse = true
        store.measureEverythingElseAgain()
        #expect(await eventually { store.scanQueue.active == .everythingElse })
        store.stopEverythingElse()
        #expect(await eventually { isIdle(store) })
        #expect(store.everythingElsePhase == .ready)
        let breakdown = store.everythingElseBreakdown(totalBytes: 1000 * gb, freeBytes: 500 * gb, trashBytes: 0)
        #expect(breakdown?[.appData]?.bytes == 66 * gb)
        fake.cleanUp()
    }

    @Test func theWalkIsNotACategoryScan() async {
        let fake = FakeScans()
        fake.hasAccess = true
        fake.holdsEverythingElse = true
        let store = fake.makeStore()
        store.showEverythingElsePage()
        #expect(await eventually { store.scanQueue.active == .everythingElse })
        // The queue is busy, but nothing a category or the intent waits on runs.
        #expect(store.scanQueue.isRunning)
        #expect(!store.scanQueue.isRunningCategoryScan)
        store.requestScan(.largeFiles)
        #expect(store.scanQueue.isRunningCategoryScan)
        store.stopScans()
        fake.cleanUp()
    }

    @Test func aHeldQueueStopsTheWalkInsteadOfWaitingForIt() async {
        let fake = FakeScans()
        fake.hasAccess = true
        fake.holdsEverythingElse = true
        let store = fake.makeStore()
        store.showEverythingElsePage()
        #expect(await eventually { store.scanQueue.active == .everythingElse })
        // A scheduled clean holds the queue; the walk would keep it waiting for minutes.
        let ran = await store.withScanQueueHeld { true }
        #expect(ran)
        #expect(store.everythingElsePhase == .notMeasured)
        fake.cleanUp()
    }

    @Test func theWalkWaitsBehindARunningStep() async {
        let fake = FakeScans()
        fake.hasAccess = true
        fake.holdsFullAccessSteps = true
        let store = fake.makeStore()
        store.requestScan(.largeFiles)
        #expect(await eventually { fake.log == ["step largeFiles"] })
        store.showEverythingElsePage()
        #expect(store.everythingElsePhase == .waiting)
        #expect(fake.everythingElseAccesses.isEmpty)
        fake.finishHeldSteps()
        #expect(await eventually { isIdle(store) })
        #expect(fake.events == ["step largeFiles", "everythingElse full"])
        fake.cleanUp()
    }

    @Test func excludingAFolderDropsItHereAndFromEveryTab() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        // Real folders: the exclusion key resolves symlinks, which only works for a
        // path that exists, and a temporary folder is reached through one.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ee-hide-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("Application Support/Hidden Me", isDirectory: true)
        let keep = base.appendingPathComponent("Application Support/Keep", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let support = root(.appData, base.appendingPathComponent("Application Support").path)
        fake.everythingElseEvents = [.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: folder.path, bytes: 5 * gb),
            OverviewSizedItem(path: keep.path, bytes: 3 * gb)
        ], looseFileBytes: 0))]
        store.showEverythingElsePage()
        #expect(await eventually { isIdle(store) })

        // A ticked cache row and a ticked Large Files row inside the folder.
        let cacheRow = CacheItem(
            definitionKey: "hidden-me-cache",
            location: CacheLocation(path: folder.appendingPathComponent("Cache"), sizeBytes: 1024, lastModified: .distantPast, folderName: "Cache"),
            appName: "Hidden Me",
            safetyInfo: SafetyInfo(level: .safe, headline: "Hidden Me", explanation: "", recoverySteps: "", reinstallCommand: nil),
            gitStatus: .clean
        )
        store.cacheItems = [cacheRow]
        store.scanSelection.cacheIDs = [cacheRow.id]
        let file = LargeFile(
            path: folder.appendingPathComponent("big.zip"),
            sizeBytes: 1,
            lastUsed: Date(),
            category: LargeFileCategory.category(forExtension: "zip")
        )
        store.largeFiles = [file]
        store.setLargeFileSelected(id: file.id, isSelected: true)

        let before = store.everythingElseBreakdown(totalBytes: 100 * gb, freeBytes: 10 * gb, trashBytes: 0)
        let hidden = before?[.appData]?.folders.first { $0.name == "Hidden Me" }
        #expect(hidden != nil)
        if let hidden {
            store.hideFromEverythingElse(hidden)
        }
        defer { ExcludedPathsStore.remove(path: folder) }

        #expect(ExcludedPathsStore.isExcluded(folder))
        let after = store.everythingElseBreakdown(totalBytes: 100 * gb, freeBytes: 10 * gb, trashBytes: 0)
        #expect(after?[.appData]?.folders.map(\.name) == ["Keep"])
        #expect(after?[.appData]?.bytes == 3 * gb)
        // The rows and their ticks are gone, so "to clean" can't count them.
        #expect(store.cacheItems.isEmpty)
        #expect(store.scanSelection.cacheIDs.isEmpty)
        #expect(store.largeFiles.isEmpty)
        #expect(store.selectedLargeFiles.isEmpty)
        fake.cleanUp()
    }

    // MARK: Helpers

    private func isIdle(_ store: PurgeStore) -> Bool {
        store.scanQueueTask == nil && !store.scanQueue.isRunning && !store.isScanningAll && !store.isMeasuringEverythingElse
    }

    /// Counts only the time this loop was running. On CI the test host can
    /// stall for tens of seconds at the start of a run, with every suite
    /// waiting on the main actor; a wall-clock deadline expires during the
    /// stall through no fault of the condition. A gap between two turns of
    /// the loop counts for at most a quarter of a second.
    private func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
        var waited: TimeInterval = 0
        var last = Date()
        while !condition() {
            guard waited < timeout else { return false }
            try? await Task.sleep(for: .milliseconds(10))
            let now = Date()
            waited += min(now.timeIntervalSince(last), 0.25)
            last = now
        }
        return true
    }
}
