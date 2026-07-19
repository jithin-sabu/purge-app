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

    /// Whether the last read succeeded. A failed read leaves the published figures at
    /// their previous values, which must not be mistaken for a fresh baseline.
    @discardableResult
    func refresh() -> Bool {
        guard let capacity = VolumeCapacityReader.read() else { return false }
        totalDiskBytes = capacity.totalBytes
        freeDiskBytes = capacity.availableBytes
        usedDiskBytes = capacity.usedBytes
        return true
    }

    /// Re-reads rather than trusting the cached figure: the volume may have moved since
    /// the last refresh, and a stale baseline would silently swallow the difference. If the
    /// read fails there is no trustworthy baseline, so none is recorded.
    func markBackgrounded() {
        freeBytesWhenBackgrounded = refresh() ? freeDiskBytes : nil
        freeSpaceIncreaseBytes = nil
    }

    /// Re-reads the volume and reports any gain since the app went away. Small movements
    /// are ignored: other processes write while we are not looking, so only a change that
    /// clears measurement noise means anything. The gain is published only when both the
    /// background baseline and this foreground read succeeded — otherwise the delta would
    /// compare a real figure against a stale or missing one.
    func refreshAfterForegroundReturn() {
        let before = freeBytesWhenBackgrounded
        freeBytesWhenBackgrounded = nil

        guard refresh(), let before else {
            freeSpaceIncreaseBytes = nil
            return
        }
        let delta = freeDiskBytes - before
        freeSpaceIncreaseBytes = delta >= VolumeCapacityReader.noiseFloorBytes ? delta : nil
    }
}
