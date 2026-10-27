import Combine
import Foundation
import SwiftUI

@MainActor
final class DiskSummaryStore: ObservableObject {
    @Published private(set) var totalDiskBytes: Int64 = 0
    @Published private(set) var usedDiskBytes: Int64 = 0
    @Published private(set) var freeDiskBytes: Int64 = 0

    /// The read taken when the app went to the background, still running or done.
    private var backgroundRead: Task<Void, Never>?
    /// The volume read in flight, if any. Triggers that arrive while it runs share
    /// one more read after it rather than each starting their own.
    private var readTask: Task<Void, Never>?
    private var readAgain = false
    /// Reads numbered in the order they started, and the number of the newest one
    /// published. The foreground return and the background baseline read outside the
    /// `refresh` chain, so an older read can land after a newer one; it is dropped
    /// rather than published over the newer figure.
    private var readsStarted = 0
    private var newestPublishedRead = 0
    private var pendingAnimation: Animation?
    /// Reads the volume. Tests hand in a fake.
    private let read: @Sendable () -> VolumeCapacity?

    /// Reads the volume once, on the main thread, so the first frame has real
    /// figures. Every later read happens off it.
    init(read: @escaping @Sendable () -> VolumeCapacity? = { VolumeCapacityReader.read() }) {
        self.read = read
        if let capacity = read() {
            apply(capacity)
        }
    }

    /// Re-reads the volume off the main thread and publishes the figures.
    ///
    /// One read takes about 5 ms, and a clean used to trigger three or four in a row
    /// on the main thread (#190). Calls that arrive while a read runs share one more
    /// read after it, so the last figure is never older than the last call. A failed
    /// read leaves the published figures at their previous values.
    func refresh(animation: Animation? = nil) {
        if let animation { pendingAnimation = animation }
        guard readTask == nil else {
            readAgain = true
            return
        }
        readTask = Task {
            repeat {
                readAgain = false
                let (read, capacity) = await readOffMain()
                if let capacity {
                    let animation = pendingAnimation
                    pendingAnimation = nil
                    withAnimation(animation) { publish(capacity, from: read) }
                }
            } while readAgain
            readTask = nil
        }
    }

    /// Reads the volume as the app goes away. The read runs off the main thread; the
    /// return waits for it.
    func markBackgrounded() {
        backgroundRead = Task {
            let (read, capacity) = await readOffMain()
            if let capacity { publish(capacity, from: read) }
        }
    }

    /// Re-reads the volume once the app is back, after the background read is done.
    func refreshAfterForegroundReturn() async {
        if let pending = backgroundRead {
            backgroundRead = nil
            await pending.value
        }

        let (read, capacity) = await readOffMain()
        guard let capacity else { return }
        publish(capacity, from: read)
    }

    private func apply(_ capacity: VolumeCapacity) {
        totalDiskBytes = capacity.totalBytes
        freeDiskBytes = capacity.availableBytes
        usedDiskBytes = capacity.usedBytes
    }

    /// Publishes a read unless a read that started after it already has.
    private func publish(_ capacity: VolumeCapacity, from read: Int) {
        guard read > newestPublishedRead else { return }
        newestPublishedRead = read
        apply(capacity)
    }

    /// Reads the volume off the main thread and returns the read's start number
    /// with the result.
    private func readOffMain() async -> (read: Int, capacity: VolumeCapacity?) {
        readsStarted += 1
        let number = readsStarted
        let read = read
        let capacity = await Task.detached(priority: .utility) { read() }.value
        return (number, capacity)
    }
}
