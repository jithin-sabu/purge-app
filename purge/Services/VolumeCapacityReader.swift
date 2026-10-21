import Foundation

/// A single reading of the volume's real state.
nonisolated struct VolumeCapacity: Equatable, Sendable {
    let totalBytes: Int64
    /// Free space for important use: what is empty plus what macOS would purge to
    /// make room. Every gain is measured on this figure.
    let availableBytes: Int64
    /// What is empty right now, the figure System Settings and `df` show. Display
    /// only, never used to measure a gain. `nil` when the volume did not report it.
    var freeNowBytes: Int64? = nil

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
}

/// Free space split the way System Settings counts it. `availableBytes` includes
/// purgeable space (local snapshots, evictable iCloud files, caches macOS manages),
/// so on its own it can read about 200 GB higher than System Settings.
nonisolated struct FreeSpaceSplit: Equatable, Sendable {
    let freeNowBytes: Int64
    let purgeableBytes: Int64

    /// Below this the two figures round to the same thing, so one is shown.
    static let minimumShownPurgeableBytes: Int64 = 1_000_000_000

    /// `nil` when there is nothing worth splitting out or no empty-space reading.
    init?(availableBytes: Int64, freeNowBytes: Int64?) {
        guard let freeNowBytes, freeNowBytes >= 0 else { return nil }
        let purgeable = availableBytes - freeNowBytes
        guard purgeable >= Self.minimumShownPurgeableBytes else { return nil }
        self.freeNowBytes = freeNowBytes
        self.purgeableBytes = purgeable
    }
}

/// Reads actual available bytes for the volume backing a URL.
///
/// Every space claim Purge makes traces back to here. A sum of file sizes says what
/// moved to the trash; only the delta between two of these readings says what the
/// volume gave back. The two are not interchangeable and must never substitute for
/// each other: moving a file to the trash frees nothing at all.
nonisolated enum VolumeCapacityReader {
    /// `nil` when the volume could not be read, which must stay distinct from a
    /// reading of zero.
    static func read(for url: URL = FileManager.default.homeDirectoryForCurrentUser) -> VolumeCapacity? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }

        return VolumeCapacity(
            totalBytes: Int64(total),
            availableBytes: available,
            freeNowBytes: values.volumeAvailableCapacity.map(Int64.init)
        )
    }

    /// Deltas smaller than this are indistinguishable from other processes writing
    /// to the volume while we measured, so they cannot support a reclaim claim.
    /// Spotlight indexing alone moves the number by megabytes between two reads.
    static let noiseFloorBytes: Int64 = 64 * 1024 * 1024

    /// Space gained since `before`, once two readings a second apart agree.
    /// APFS gives space back over a few seconds after something goes, so the
    /// figure is read until it stops moving. It still covers everything else
    /// written meanwhile, so it is only claimed once it has settled and clears
    /// the noise floor; a figure still moving, or no reading, claims nothing.
    static func settledGain(
        since before: Int64?,
        attempts: Int = 10,
        read: @Sendable () -> Int64?
    ) async -> Int64? {
        guard let before else { return nil }
        var previous: Int64?
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let after = read() else { return nil }
            let gained = after - before
            if let previous, abs(gained - previous) < noiseFloorBytes {
                return gained >= noiseFloorBytes ? gained : nil
            }
            previous = gained
        }
        return nil
    }
}
