import Foundation
import Testing
@testable import Purge

/// The Everything else walk in the store (#220): it runs on demand as its own
/// scan-queue step, never at launch, and the groups fill in as roots finish.
/// Driven with `FakeScans`, so nothing here walks this Mac.
@MainActor
@Suite("Everything else in the store")
struct EverythingElseStoreTests {
    private let gb: Int64 = 1_000_000_000

    private func root(_ group: EverythingElseGroup, _ path: String) -> EverythingElseMeasureRoot {
        EverythingElseMeasureRoot(group: group, url: URL(fileURLWithPath: path, isDirectory: true), kind: .children, isLockedWithoutAccess: false)
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

    @Test func openingTheRowMeasuresOnceThisSession() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        store.openEverythingElse()
        #expect(store.isEverythingElseExpanded)
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses == [.limited])
        #expect(store.everythingElsePhase == .ready)
        #expect(store.everythingElseMeasurement?.isComplete == true)

        // Opening it again, or opening the page, reuses this session's measure.
        store.openEverythingElse()
        store.showEverythingElsePage()
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses == [.limited])
        #expect(store.overviewPage == .everythingElse)

        // Measure again is a fresh walk, with the access Purge has now.
        fake.hasAccess = true
        store.measureEverythingElseAgain()
        #expect(await eventually { isIdle(store) })
        #expect(fake.everythingElseAccesses == [.limited, .full])
        fake.cleanUp()
    }

    @Test func groupsFillInAsRootsFinishAndTheFigureLandsAtTheEnd() async {
        let fake = FakeScans()
        fake.hasAccess = true
        fake.holdsEverythingElse = true
        let store = fake.makeStore()
        let support = root(.appData, "/Users/alice/Library/Application Support")
        let caches = root(.uncleanableCaches, "/Users/alice/Library/Caches")
        fake.everythingElseEvents = [.planned([support, caches]), .macOS(14 * gb)]
        store.openEverythingElse()
        #expect(await eventually { store.everythingElseMeasurement?.macOSBytes == 14 * gb })
        #expect(store.everythingElsePhase == .measuring)
        #expect(store.everythingElseMeasurement?.isComplete == false)

        fake.yieldEverythingElse([.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/CoreAIKit", bytes: 66 * gb)
        ], looseFileBytes: 0))])
        #expect(await eventually { store.everythingElseMeasurement?.measuredRoots.count == 1 })
        let partial = store.everythingElseBreakdown(totalBytes: 1000 * gb, freeBytes: 500 * gb)
        #expect(partial?[.appData]?.bytes == 66 * gb)
        #expect(partial?[.appData]?.isFinished == true)
        #expect(partial?[.uncleanableCaches]?.isFinished == false)
        #expect(partial?.isComplete == false)

        fake.finishHeldEverythingElse()
        #expect(await eventually { isIdle(store) })
        let done = store.everythingElseBreakdown(totalBytes: 1000 * gb, freeBytes: 500 * gb)
        #expect(done?.isComplete == true)
        #expect(done?[.uncleanableCaches]?.isFinished == true)
        #expect(done?.everythingElseBytes == 500 * gb)
        #expect(done?.notMeasuredBytes == 500 * gb - 66 * gb - 14 * gb)
        #expect(store.everythingElsePhase == .ready)
        #expect(store.hasSessionResults(for: .everythingElse))
        fake.cleanUp()
    }

    @Test func stopEndsTheWalkAndLeavesItUnfinished() async {
        let fake = FakeScans()
        fake.holdsEverythingElse = true
        let store = fake.makeStore()
        store.openEverythingElse()
        #expect(await eventually { store.scanQueue.active == .everythingElse })
        store.stopScans()
        #expect(await eventually { isIdle(store) })
        // Stopped before or during the walk: either way nothing counts as measured.
        #expect(store.everythingElseMeasurement?.isComplete != true)
        #expect(!store.hasSessionResults(for: .everythingElse))
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
        store.openEverythingElse()
        #expect(store.everythingElsePhase == .waiting)
        #expect(fake.everythingElseAccesses.isEmpty)
        fake.finishHeldSteps()
        #expect(await eventually { isIdle(store) })
        #expect(fake.events == ["step largeFiles", "everythingElse full"])
        fake.cleanUp()
    }

    @Test func hidingAFolderAddsItToExcludedPathsAndDropsItFromTheGroup() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        // Real folders: the exclusion key resolves symlinks, which only works for a
        // path that exists, and a temporary folder is reached through one.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ee-hide-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("Application Support/Hidden Me", isDirectory: true)
        let keep = base.appendingPathComponent("Application Support/Keep", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let support = root(.appData, base.appendingPathComponent("Application Support").path)
        fake.everythingElseEvents = [.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: folder.path, bytes: 5 * gb),
            OverviewSizedItem(path: keep.path, bytes: 3 * gb)
        ], looseFileBytes: 0))]
        store.openEverythingElse()
        #expect(await eventually { isIdle(store) })
        let before = store.everythingElseBreakdown(totalBytes: 100 * gb, freeBytes: 10 * gb)
        let hidden = before?[.appData]?.folders.first { $0.name == "Hidden Me" }
        #expect(hidden != nil)

        if let hidden {
            store.hideFromEverythingElse(hidden)
        }
        defer { ExcludedPathsStore.remove(path: folder) }
        #expect(ExcludedPathsStore.isExcluded(folder))
        #expect(!store.excludedPaths.isEmpty)
        let after = store.everythingElseBreakdown(totalBytes: 100 * gb, freeBytes: 10 * gb)
        #expect(after?[.appData]?.folders.map(\.name) == ["Keep"])
        #expect(after?[.appData]?.bytes == 3 * gb)
        fake.cleanUp()
    }

    // MARK: Helpers

    private func isIdle(_ store: PurgeStore) -> Bool {
        store.scanQueueTask == nil && !store.scanQueue.isRunning && !store.isScanningAll && !store.isMeasuringEverythingElse
    }

    private func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
