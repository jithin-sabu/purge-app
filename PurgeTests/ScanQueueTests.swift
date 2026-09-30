import Foundation
import Testing
@testable import Purge

@Suite("The scan queue runs one step at a time")
struct ScanQueueStateTests {

    @Test func enqueueKeepsOrderAndSkipsDuplicates() {
        var queue = ScanQueueState()
        queue.enqueue([.cachesAndDevTools, .largeFiles, .apps])
        queue.enqueue([.largeFiles, .leftovers])
        #expect(queue.pending == [.cachesAndDevTools, .largeFiles, .apps, .leftovers])
    }

    @Test func startNextMovesTheFirstStepToActive() {
        var queue = ScanQueueState()
        queue.enqueue([.cachesAndDevTools, .largeFiles])
        #expect(queue.startNext() == .cachesAndDevTools)
        #expect(queue.active == .cachesAndDevTools)
        #expect(queue.pending == [.largeFiles])
        #expect(queue.isRunning)
    }

    @Test func enqueueSkipsTheRunningStep() {
        var queue = ScanQueueState()
        queue.enqueue([.largeFiles])
        _ = queue.startNext()
        queue.enqueue([.largeFiles, .apps])
        #expect(queue.pending == [.apps])
    }

    @Test func prioritizeMovesAWaitingStepToTheFront() {
        var queue = ScanQueueState()
        queue.enqueue([.cachesAndDevTools, .largeFiles, .apps, .leftovers])
        _ = queue.startNext()
        queue.prioritize([.apps, .leftovers])
        #expect(queue.pending == [.apps, .leftovers, .largeFiles])
    }

    @Test func prioritizeLeavesTheRunningStepAlone() {
        var queue = ScanQueueState()
        queue.enqueue([.largeFiles, .apps])
        _ = queue.startNext()
        queue.prioritize([.largeFiles])
        #expect(queue.active == .largeFiles)
        #expect(queue.pending == [.apps])
    }

    @Test func requeueingRunsTheRunningStepAgainNext() {
        var queue = ScanQueueState()
        queue.enqueue([.largeFiles, .apps])
        _ = queue.startNext()
        queue.prioritize([.largeFiles], requeueingActive: true)
        #expect(queue.active == .largeFiles)
        #expect(queue.pending == [.largeFiles, .apps])
    }

    @Test func prioritizeAddsAStepThatWasNotWaiting() {
        var queue = ScanQueueState()
        queue.enqueue([.apps])
        queue.prioritize([.largeFiles])
        #expect(queue.pending == [.largeFiles, .apps])
        #expect(queue.isQueued(.largeFiles))
    }

    @Test func startNextOnAnEmptyQueueClearsActive() {
        var queue = ScanQueueState()
        queue.enqueue([.apps])
        _ = queue.startNext()
        #expect(queue.startNext() == nil)
        #expect(queue.active == nil)
        #expect(!queue.isRunning)
    }

    @Test func clearPendingKeepsTheRunningStep() {
        var queue = ScanQueueState()
        queue.enqueue([.largeFiles, .apps, .leftovers])
        _ = queue.startNext()
        queue.clearPending()
        #expect(queue.active == .largeFiles)
        #expect(queue.pending.isEmpty)
    }

    @Test func largeFilesAndAppScansNeedFullDiskAccess() {
        #expect(!ScanStep.cachesAndDevTools.needsFullDiskAccess)
        #expect(ScanStep.largeFiles.needsFullDiskAccess)
        #expect(ScanStep.apps.needsFullDiskAccess)
        #expect(ScanStep.leftovers.needsFullDiskAccess)
    }

    @Test func everyCategoryMapsBackToTheStepThatScansIt() {
        for category in OverviewCategory.allCases {
            #expect(category.step.categories.contains(category))
        }
    }
}

@Suite("The launch scan queues whatever this session has not scanned")
struct LaunchScanPlanTests {
    @Test func aFirstLaunchScansEverythingInOrder() {
        let steps = LaunchScanPlan.steps(hasFullDiskAccess: true, loadedThisSession: [])
        #expect(steps == [.cachesAndDevTools, .largeFiles, .apps, .leftovers])
    }

    @Test func withoutFullDiskAccessOnlyCachesAndDevToolsScan() {
        let steps = LaunchScanPlan.steps(hasFullDiskAccess: false, loadedThisSession: [])
        #expect(steps == [.cachesAndDevTools])
    }

    @Test func existingCacheResultsAreNotRescanned() {
        let steps = LaunchScanPlan.steps(hasFullDiskAccess: false, loadedThisSession: [.cachesAndDevTools])
        #expect(steps.isEmpty)
    }

    @Test func resultsFromThisSessionAreNotRescanned() {
        let steps = LaunchScanPlan.steps(
            hasFullDiskAccess: true,
            loadedThisSession: [.cachesAndDevTools, .largeFiles, .apps]
        )
        #expect(steps == [.leftovers])
    }
}

@Suite("Scan records survive a relaunch")
struct ScanRecordStoreTests {

    private func makeDefaults() -> UserDefaults {
        let name = "io.getpurge.tests.scanrecords.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aSavedRecordReadsBack() {
        let store = ScanRecordStore(defaults: makeDefaults())
        let record = ScanRecord(completedAt: Date(timeIntervalSince1970: 1_800_000_000), bytes: 38_600_000_000, count: 14)
        store.save(record, for: .largeFiles)
        #expect(store.record(for: .largeFiles) == record)
        #expect(store.record(for: .apps) == nil)
    }

    @Test func allRecordsReturnsOnlyWhatWasSaved() {
        let store = ScanRecordStore(defaults: makeDefaults())
        let record = ScanRecord(completedAt: Date(), bytes: 5, count: 2)
        store.save(record, for: .leftovers)
        let all = store.allRecords()
        #expect(all.count == 1)
        #expect(all[.leftovers] == record)
    }

    @Test func aRecordSavedBeforeSafeBytesStillReads() {
        let defaults = makeDefaults()
        let old = #"{"completedAt":800000000,"bytes":4000000000,"count":58}"#
        defaults.set(Data(old.utf8), forKey: ScanRecordStore.key(for: .appCaches))
        let record = ScanRecordStore(defaults: defaults).record(for: .appCaches)
        #expect(record?.count == 58)
        #expect(record?.safeBytes == nil)
    }

    @Test func safeBytesReadBack() {
        let store = ScanRecordStore(defaults: makeDefaults())
        let record = ScanRecord(completedAt: Date(timeIntervalSince1970: 1_800_000_000), bytes: 4, count: 2, safeBytes: 3)
        store.save(record, for: .devTools)
        #expect(store.record(for: .devTools)?.safeBytes == 3)
    }

    @Test func aCorruptValueReadsAsNoRecord() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: ScanRecordStore.key(for: .apps))
        #expect(ScanRecordStore(defaults: defaults).record(for: .apps) == nil)
    }
}
