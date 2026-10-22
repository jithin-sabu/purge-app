import Foundation
import Testing
@testable import Purge

/// Stop can cut a Large Files scan short (#180). Only a walk that ran to its end
/// counts as finished: a stopped one leaves no record of its partial total, the
/// Overview does not treat the area as scanned, and opening the tab scans again.
@MainActor
@Suite("A stopped Large Files scan does not count as finished")
struct LargeFileScanStopTests {

    @Test
    func aFirstScanStoppedMidStreamWritesNoRecord() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.holdsLargeFiles = true
        fake.largeFileEvents = [.file(file("/Users/someone/Movies/wedding.mov", bytes: 4_000_000_000))]
        let store = fake.makeStore()

        let scan = Task { await store.scanLargeFiles() }
        #expect(await eventually { fake.largeFileScanCount == 1 })
        #expect(store.isScanningLargeFiles)
        scan.cancel()
        await scan.value

        #expect(!store.isScanningLargeFiles)
        #expect(!store.hasSessionResults(for: .largeFiles))
        #expect(!store.isSettled(.largeFiles))
        #expect(store.scanRecords[.largeFiles] == nil)
        #expect(ScanRecordStore(defaults: fake.defaults).record(for: .largeFiles) == nil)
    }

    /// The flag a finished scan sets used to stay set for every later scan, so a
    /// rescan that Stop cut short still read as finished, with a smaller total.
    @Test
    func aStoppedRescanKeepsTheLastFullRecordAndScansAgain() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        fake.largeFileEvents = [.file(file("/Users/someone/Movies/wedding.mov", bytes: 4_000_000_000))]
        let store = fake.makeStore()

        await store.scanLargeFiles()
        #expect(store.hasSessionResults(for: .largeFiles))
        #expect(store.isSettled(.largeFiles))
        let finished = store.scanRecords[.largeFiles]
        #expect(finished?.bytes == 4_000_000_000)
        #expect(finished?.count == 1)

        fake.holdsLargeFiles = true
        fake.largeFileEvents = [.file(file("/Users/someone/Movies/clip.mov", bytes: 1_000_000))]
        let rescan = Task { await store.scanLargeFiles() }
        #expect(await eventually { fake.largeFileScanCount == 2 })
        rescan.cancel()
        await rescan.value

        #expect(!store.isScanningLargeFiles)
        #expect(!store.hasSessionResults(for: .largeFiles))
        #expect(!store.isSettled(.largeFiles))
        #expect(store.scanRecords[.largeFiles] == finished)
        #expect(ScanRecordStore(defaults: fake.defaults).record(for: .largeFiles) == finished)

        // Opening the tab does not trust the stopped scan: it scans again, and
        // only that full scan replaces the record.
        fake.holdsLargeFiles = false
        await store.scanLargeFilesIfNeeded()
        #expect(fake.largeFileScanCount == 3)
        #expect(store.hasSessionResults(for: .largeFiles))
        #expect(store.isSettled(.largeFiles))
        #expect(store.scanRecords[.largeFiles]?.bytes == 1_000_000)
    }

    private func file(_ path: String, bytes: Int64) -> LargeFile {
        LargeFile(path: URL(fileURLWithPath: path), sizeBytes: bytes, lastUsed: Date(), category: .video)
    }

    /// Waits for the store to settle. The deadline only stops a hang; it counts
    /// only the time this loop was running, as `ScanQueueStoreTests` does.
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
