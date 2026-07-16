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

    private var freeBytesWhenBackgrounded: Int64?

    init() {
        refresh()
    }

    func refresh() {
        guard let capacity = VolumeCapacityReader.read() else { return }
        totalDiskBytes = capacity.totalBytes
        freeDiskBytes = capacity.availableBytes
        usedDiskBytes = capacity.usedBytes
    }

    /// Re-reads rather than trusting the cached figure: the volume may have moved since
    /// the last refresh, and a stale baseline would silently swallow the difference.
    func markBackgrounded() {
        refresh()
        freeBytesWhenBackgrounded = freeDiskBytes
        freeSpaceIncreaseBytes = nil
    }

    /// Re-reads the volume and reports any gain since the app went away. Small movements
    /// are ignored: other processes write while we are not looking, so only a change that
    /// clears measurement noise means anything.
    func refreshAfterForegroundReturn() {
        let before = freeBytesWhenBackgrounded
        freeBytesWhenBackgrounded = nil
        refresh()

        guard let before else {
            freeSpaceIncreaseBytes = nil
            return
        }
        let delta = freeDiskBytes - before
        freeSpaceIncreaseBytes = delta >= VolumeCapacityReader.noiseFloorBytes ? delta : nil
    }
}
