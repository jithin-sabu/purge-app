import Foundation
import Testing
@testable import Purge

/// Drives the real store and scan queue with scans that report what access they ran
/// with and, when asked, stay open until the test lets them finish. Nothing here
/// walks the disk or asks macOS about access.
@MainActor
@Suite("Scan queue in the store")
struct ScanQueueStoreTests {
    // MARK: Full Disk Access arriving mid-scan

    @Test
    func accessGrantedDuringALimitedQueuedScanRescansWithAccess() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        fake.holdsGeneral = true
        store.startLaunchScans()
        #expect(await eventually { fake.generalAccesses == [.limited] })

        // What `ContentView` does when the Look Deeper sheet sees the grant.
        fake.holdsGeneral = false
        fake.hasAccess = true
        store.refreshPermission()
        store.scanAfterAccessGranted()

        #expect(await eventually { isIdle(store) })
        #expect(fake.generalAccesses == [.limited, .full])
        #expect(fake.developerAccesses.last == .full)
        #expect(!store.cacheResultsNeedAccessRescan)
        #expect(fake.log == ["step largeFiles", "step apps", "step leftovers"])
        fake.cleanUp()
    }

    @Test
    func limitedResultsDoNotCountOnceAccessArrives() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        store.startLaunchScans()
        #expect(await eventually { isIdle(store) })
        #expect(fake.generalAccesses == [.limited])

        // Access landed while the window was closed, so nothing asked for a
        // rescan. Opening the window must not keep the limited results.
        fake.hasAccess = true
        store.startLaunchScans()

        #expect(await eventually { isIdle(store) })
        #expect(fake.generalAccesses == [.limited, .full])
        #expect(!store.cacheResultsNeedAccessRescan)
        fake.cleanUp()
    }

    @Test
    func aLimitedScanStartedOutsideTheQueueIsReplacedNotWaitedOn() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        fake.holdsGeneral = true
        // Onboarding calls `scanAll` itself.
        let outside = Task { await store.scanAll() }
        #expect(await eventually { fake.generalAccesses == [.limited] })

        fake.holdsGeneral = false
        fake.hasAccess = true
        store.refreshPermission()
        store.requestScan(.cachesAndDevTools)

        #expect(await eventually { isIdle(store) })
        #expect(fake.generalAccesses == [.limited, .full])
        // Releases the first scan too, so a failure here ends instead of hanging.
        fake.cleanUp()
        await outside.value
    }

    // MARK: A standalone scan replacing a full one

    @Test
    func aStandaloneScanDoesNotLeaveAFullScanMarkedRunning() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        fake.holdsGeneral = true
        store.requestScan(.cachesAndDevTools)
        #expect(await eventually { store.isScanningAll })

        // What a scheduled clean's rescan does.
        fake.holdsGeneral = false
        await store.scanDeveloper()

        #expect(await eventually { isIdle(store) })
        #expect(!store.isScanningAll)

        // The next Scan runs a scan of its own instead of waiting on the old one.
        store.requestScan(.cachesAndDevTools)
        #expect(await eventually { fake.generalAccesses.count == 2 })
        #expect(await eventually { isIdle(store) })
        fake.cleanUp()
    }

    // MARK: Nothing scans beside the queue

    @Test
    func theMenuBarScanWaitsForARunningStep() async throws {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        fake.holdsFullAccessSteps = true
        store.requestScan(.largeFiles)
        #expect(await eventually { fake.log == ["step largeFiles"] })

        let menuScan = Task { await store.scanThroughQueue(.cachesAndDevTools, forced: true) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.generalAccesses.isEmpty)

        fake.finishHeldSteps()
        await menuScan.value
        #expect(fake.generalAccesses == [.full])
        fake.cleanUp()
    }

    @Test
    func aScanThatIsNotAllowedDoesNotKeepItsCallerWaiting() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        // Large Files needs Full Disk Access, so the request is dropped.
        await store.scanThroughQueue(.largeFiles, forced: true)
        #expect(fake.log.isEmpty)
        fake.cleanUp()
    }

    @Test
    func aScheduledCleanHoldsTheQueueWhileItScans() async throws {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        fake.holdsFullAccessSteps = true
        store.requestScan(.largeFiles)
        #expect(await eventually { fake.log == ["step largeFiles"] })

        let clean = Task {
            await store.withScanQueueHeld {
                fake.log.append("clean starts")
                // Asked for while held: waits for the clean.
                store.requestScan(.apps)
                try? await Task.sleep(for: .milliseconds(200))
                fake.log.append("clean ends")
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.log == ["step largeFiles"])

        fake.holdsFullAccessSteps = false
        fake.finishHeldSteps()
        await clean.value
        #expect(await eventually { isIdle(store) })
        #expect(fake.log == ["step largeFiles", "clean starts", "clean ends", "step apps"])
        fake.cleanUp()
    }

    // MARK: Review follow-ups

    @Test
    func aLongLargeFilesStepKeepsTheQueueWaiting() async throws {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        store.cacheStepPatience = 0.1
        fake.holdsFullAccessSteps = true
        store.requestScan(.largeFiles)
        #expect(await eventually { fake.log == ["step largeFiles"] })
        store.requestScan(.apps)

        // Well past the cache step's patience: Large Files has none.
        try await Task.sleep(for: .milliseconds(400))
        #expect(fake.log == ["step largeFiles"])
        #expect(store.scanQueue.active == .largeFiles)

        fake.holdsFullAccessSteps = false
        fake.finishHeldSteps()
        #expect(await eventually { isIdle(store) })
        #expect(fake.log == ["step largeFiles", "step apps"])
        fake.cleanUp()
    }

    @Test
    func aStalledCacheStepStillLetsTheQueueMoveOn() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        store.cacheStepPatience = 0.1
        fake.holdsGeneral = true
        store.requestScan(.cachesAndDevTools, .largeFiles)
        #expect(await eventually { fake.log == ["step largeFiles"] })
        fake.cleanUp()
    }

    @Test
    func aTabOpenedAtTheGrantWaitsForTheAccessRescan() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        store.startLaunchScans()
        #expect(await eventually { isIdle(store) })

        fake.hasAccess = true
        store.refreshPermission()
        store.scanAfterAccessGranted()
        // What the Large Files tab's task does when access flips while it is open.
        store.requestScanIfNeeded(.largeFiles)

        #expect(await eventually { isIdle(store) })
        #expect(Array(fake.events.prefix(3)) == ["general limited", "general full", "step largeFiles"])
        fake.cleanUp()
    }

    @Test
    func appCachesThatFoundNothingIsDoneWhileDevToolsScans() async {
        let fake = FakeScans()
        fake.hasAccess = true
        ScanRecordStore(defaults: fake.defaults).save(
            ScanRecord(completedAt: .distantPast, bytes: 5_000_000_000, count: 12),
            for: .appCaches
        )
        let store = fake.makeStore()
        fake.holdsDeveloper = true
        store.requestScan(.cachesAndDevTools)
        #expect(await eventually { fake.developerAccesses == [.full] })

        #expect(store.overviewPhase(for: .appCaches) == .ready)
        #expect(!store.isShowingRecordedFigure(for: .appCaches))
        fake.cleanUp()
        #expect(await eventually { isIdle(store) })
    }

    @Test
    func theLeftoversRowOpensLeftoversUntilAScanFindsNone() async {
        let fake = FakeScans()
        fake.hasAccess = true
        ScanRecordStore(defaults: fake.defaults).save(
            ScanRecord(completedAt: .distantPast, bytes: 2_000_000_000, count: 12),
            for: .leftovers
        )
        let store = fake.makeStore()
        // Showing last launch's "12 items".
        #expect(store.isShowingRecordedFigure(for: .leftovers))
        #expect(store.overviewLeftoversSection == .leftovers)

        // Waiting its turn.
        store.scanQueue.enqueue([.leftovers])
        #expect(store.overviewLeftoversSection == .leftovers)
        fake.cleanUp()
    }

    // MARK: Helpers

    private func isIdle(_ store: PurgeStore) -> Bool {
        store.scanQueueTask == nil
            && !store.scanQueue.isRunning
            && !store.isScanningAll
            && !store.isScanningProjects
    }

    private func eventually(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Scans that record what they were asked for. App Caches scans and the Full Disk
/// Access steps can be held open until the test finishes them.
@MainActor
private final class FakeScans {
    var hasAccess = false
    var holdsGeneral = false
    var holdsDeveloper = false
    var holdsFullAccessSteps = false
    private(set) var generalAccesses: [ScanAccess] = []
    private(set) var developerAccesses: [ScanAccess] = []
    /// Full Disk Access steps as they start, plus anything a test adds.
    var log: [String] = []
    /// Every scan in the order it started: App Caches with its access, and the steps.
    private(set) var events: [String] = []

    private var heldGeneral: [AsyncStream<CacheScanEvent>.Continuation] = []
    private var heldDeveloper: [AsyncStream<DeveloperScanEvent>.Continuation] = []
    private var heldSteps: [CheckedContinuation<Void, Never>] = []
    private let suiteName = "purge-tests-\(UUID().uuidString)"

    func makeStore() -> PurgeStore {
        let store = PurgeStore(defaults: defaults, scanSources: sources)
        store.refreshPermission()
        return store
    }

    /// The throwaway defaults the store reads and writes, for seeding saved records.
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    func finishHeldSteps() {
        let steps = heldSteps
        heldSteps = []
        steps.forEach { $0.resume() }
    }

    func cleanUp() {
        heldGeneral.forEach { $0.finish() }
        heldDeveloper.forEach { $0.finish() }
        finishHeldSteps()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private var sources: ScanSources {
        ScanSources(
            fullDiskAccess: { self.hasAccess },
            general: { access in
                self.generalAccesses.append(access)
                self.events.append("general \(access)")
                let (stream, continuation) = AsyncStream<CacheScanEvent>.makeStream()
                if self.holdsGeneral {
                    self.heldGeneral.append(continuation)
                } else {
                    continuation.finish()
                }
                return stream
            },
            developer: { access in
                self.developerAccesses.append(access)
                let (stream, continuation) = AsyncStream<DeveloperScanEvent>.makeStream()
                if self.holdsDeveloper {
                    self.heldDeveloper.append(continuation)
                } else {
                    continuation.finish()
                }
                return stream
            },
            projects: { _ in Self.finishedStream() },
            fullAccessStep: { step, _ in
                self.log.append("step \(step.rawValue)")
                self.events.append("step \(step.rawValue)")
                if self.holdsFullAccessSteps {
                    await withCheckedContinuation { self.heldSteps.append($0) }
                }
            }
        )
    }

    private static func finishedStream() -> AsyncStream<DeveloperScanEvent> {
        let (stream, continuation) = AsyncStream<DeveloperScanEvent>.makeStream()
        continuation.finish()
        return stream
    }
}
