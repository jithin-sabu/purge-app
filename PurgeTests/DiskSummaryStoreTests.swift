import Foundation
import Testing
@testable import Purge

/// A volume the test controls: each read returns the free space as it was when the
/// read started, records whether it ran on the main thread, and can be made slow.
/// `startedReadCount` and `readCount` let a test wait for a read to start or land
/// instead of sleeping and hoping.
private final class FakeVolume: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int64
    private var started = 0
    private var reads = 0
    private var mainThreadReads = 0
    private var delay: TimeInterval

    init(free: Int64, delay: TimeInterval = 0) {
        self.free = free
        self.delay = delay
    }

    func setFree(_ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        free = bytes
    }

    /// How long each read started from now on takes.
    func setDelay(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        delay = seconds
    }

    var startedReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    var readCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    var mainThreadReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return mainThreadReads
    }

    func read() -> VolumeCapacity? {
        lock.lock()
        started += 1
        let bytes = free
        let delay = delay
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if Thread.isMainThread { mainThreadReads += 1 }
        return VolumeCapacity(totalBytes: 1_000_000_000_000, availableBytes: bytes)
    }
}

/// Reads the volume off the main thread and shares reads between triggers (#190).
@Suite("Disk summary reads")
@MainActor
struct DiskSummaryStoreTests {
    private static let gigabyte: Int64 = 1_000_000_000

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func refreshReadsOffTheMainThread() async {
        let volume = FakeVolume(free: 100 * Self.gigabyte)
        let store = DiskSummaryStore(read: { volume.read() })
        #expect(store.freeDiskBytes == 100 * Self.gigabyte)

        volume.setFree(90 * Self.gigabyte)
        store.refresh()
        await waitUntil { store.freeDiskBytes == 90 * Self.gigabyte }

        #expect(store.freeDiskBytes == 90 * Self.gigabyte)
        #expect(volume.readCount == 2)
        // Only the first read, in `init`, is on the main thread.
        #expect(volume.mainThreadReadCount == 1)
    }

    @Test func refreshDoesNotWaitForTheRead() {
        let volume = FakeVolume(free: 100 * Self.gigabyte, delay: 0.2)
        let store = DiskSummaryStore(read: { volume.read() })
        volume.setFree(80 * Self.gigabyte)

        let start = Date()
        store.refresh()
        #expect(Date().timeIntervalSince(start) < 0.1)
        #expect(store.freeDiskBytes == 100 * Self.gigabyte)
    }

    /// A clean fires several triggers within a few milliseconds. They share one more
    /// read after the one in flight, and the figure that lands is the newest.
    @Test func triggersDuringAReadShareOneMoreRead() async {
        let volume = FakeVolume(free: 100 * Self.gigabyte, delay: 0.1)
        let store = DiskSummaryStore(read: { volume.read() })

        store.refresh()
        // Once the read has started, change the volume under it.
        await waitUntil { volume.startedReadCount == 2 }
        volume.setFree(70 * Self.gigabyte)
        for _ in 0..<5 { store.refresh() }
        await waitUntil { volume.readCount == 3 && store.freeDiskBytes == 70 * Self.gigabyte }
        try? await Task.sleep(for: .milliseconds(300))

        #expect(volume.readCount == 3)
        #expect(store.freeDiskBytes == 70 * Self.gigabyte)
    }

    /// Calls made before the read has started are all covered by it.
    @Test func triggersBeforeTheReadStartsShareIt() async {
        let volume = FakeVolume(free: 100 * Self.gigabyte, delay: 0.1)
        let store = DiskSummaryStore(read: { volume.read() })

        volume.setFree(70 * Self.gigabyte)
        for _ in 0..<5 { store.refresh() }
        await waitUntil { store.freeDiskBytes == 70 * Self.gigabyte }
        try? await Task.sleep(for: .milliseconds(300))

        #expect(volume.readCount == 2)
        #expect(store.freeDiskBytes == 70 * Self.gigabyte)
    }

    @Test func foregroundReturnReportsSpaceFreedWhileAway() async {
        let volume = FakeVolume(free: 100 * Self.gigabyte)
        let store = DiskSummaryStore(read: { volume.read() })

        store.markBackgrounded()
        // Once the baseline has been read, the user empties the Trash in Finder.
        await waitUntil { volume.readCount == 2 }
        volume.setFree(103 * Self.gigabyte)
        await store.refreshAfterForegroundReturn()

        #expect(store.freeDiskBytes == 103 * Self.gigabyte)
        #expect(store.freeSpaceIncreaseBytes == 3 * Self.gigabyte)
    }

    /// The Trash total changes as the app returns, which starts a `refresh` read at
    /// the same moment as the foreground read. Whichever lands last may not publish
    /// an older figure over a newer one.
    @Test func anOlderReadNeverPublishesOverANewerOne() async {
        let volume = FakeVolume(free: 100 * Self.gigabyte)
        let store = DiskSummaryStore(read: { volume.read() })
        store.markBackgrounded()
        await waitUntil { volume.readCount == 2 }

        // A slow refresh read starts first and sees 100 GB.
        volume.setDelay(0.2)
        store.refresh()
        await waitUntil { volume.startedReadCount == 3 }

        // The foreground read starts after it, sees 103 GB, and lands first.
        volume.setDelay(0)
        volume.setFree(103 * Self.gigabyte)
        await store.refreshAfterForegroundReturn()
        #expect(store.freeDiskBytes == 103 * Self.gigabyte)
        #expect(store.freeSpaceIncreaseBytes == 3 * Self.gigabyte)

        // The slow read lands and is dropped.
        await waitUntil { volume.readCount == 4 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(volume.readCount == 4)
        #expect(store.freeDiskBytes == 103 * Self.gigabyte)
        #expect(store.freeSpaceIncreaseBytes == 3 * Self.gigabyte)
    }

    /// The return waits for a baseline read that is still running, so a quick
    /// switch away and back cannot compare against a missing figure.
    @Test func foregroundReturnWaitsForTheBaseline() async {
        let volume = FakeVolume(free: 100 * Self.gigabyte, delay: 0.1)
        let store = DiskSummaryStore(read: { volume.read() })

        store.markBackgrounded()
        await store.refreshAfterForegroundReturn()

        #expect(store.freeDiskBytes == 100 * Self.gigabyte)
        #expect(store.freeSpaceIncreaseBytes == nil)
        #expect(volume.readCount == 3)
    }

    @Test func smallMovementsAreNotReported() async {
        let volume = FakeVolume(free: 100 * Self.gigabyte)
        let store = DiskSummaryStore(read: { volume.read() })

        store.markBackgrounded()
        await waitUntil { volume.readCount == 2 }
        volume.setFree(100 * Self.gigabyte + VolumeCapacityReader.noiseFloorBytes - 1)
        await store.refreshAfterForegroundReturn()

        #expect(store.freeSpaceIncreaseBytes == nil)
    }
}
