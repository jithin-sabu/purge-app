import Foundation

/// A single reading of the volume's real state.
nonisolated struct VolumeCapacity: Equatable, Sendable {
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
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
            .volumeAvailableCapacityForImportantUsageKey
        ]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }

        return VolumeCapacity(totalBytes: Int64(total), availableBytes: available)
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
        interval: Duration = .seconds(1),
        read: @Sendable () -> Int64?
    ) async -> Int64? {
        guard let before else { return nil }
        var previous: Int64?
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(for: interval)
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
