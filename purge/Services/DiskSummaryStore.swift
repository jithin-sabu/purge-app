import Combine
import Foundation
import SwiftUI

@MainActor
final class DiskSummaryStore: ObservableObject {
    @Published private(set) var totalDiskBytes: Int64 = 0
    @Published private(set) var usedDiskBytes: Int64 = 0
    @Published private(set) var freeDiskBytes: Int64 = 0
    /// How much free space the volume gained while the app was in the background. `nil`
    /// unless a real increase was observed.
    ///
    /// This is volume state, never an achievement, and never Purge's doing. The user
    /// emptied the trash in Finder; Purge only observed the result.
    @Published private(set) var freeSpaceIncreaseBytes: Int64?

    /// The read taken when the app went to the background, still running or done.
    private var backgroundBaseline: Task<Int64?, Never>?
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

    /// Records free space as the app goes away, so a return can report what changed.
    /// The read runs off the main thread; the return waits for it. If the read fails
    /// there is no trustworthy baseline, so none is recorded.
    func markBackgrounded() {
        freeSpaceIncreaseBytes = nil
        backgroundBaseline = Task {
            let (read, capacity) = await readOffMain()
            if let capacity { publish(capacity, from: read) }
            return capacity?.availableBytes
        }
    }

    /// Re-reads the volume and reports any gain since the app went away. Small movements
    /// are ignored: other processes write while we are not looking, so only a change that
    /// clears measurement noise means anything. The gain is published only when both the
    /// background baseline and this foreground read succeeded — otherwise the delta would
    /// compare a real figure against a stale or missing one.
    func refreshAfterForegroundReturn() async {
        let baseline = backgroundBaseline
        backgroundBaseline = nil
        let before = await baseline?.value

        let (read, capacity) = await readOffMain()
        guard let capacity else {
            freeSpaceIncreaseBytes = nil
            return
        }
        publish(capacity, from: read)
        guard let before else {
            freeSpaceIncreaseBytes = nil
            return
        }
        let delta = capacity.availableBytes - before
        freeSpaceIncreaseBytes = delta >= VolumeCapacityReader.noiseFloorBytes ? delta : nil
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
