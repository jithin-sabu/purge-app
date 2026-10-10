import Foundation

/// A single reading of the volume's real state.
nonisolated struct VolumeCapacity: Equatable, Sendable {
    let totalBytes: Int64
    /// What System Settings calls available: empty space plus what macOS can clear on
    /// its own when it needs room (iCloud copies, caches, local snapshots).
    let availableBytes: Int64
    /// Space with nothing in it at all, which is what Disk Utility calls free. `nil` when
    /// the volume didn't report it.
    var emptyBytes: Int64? = nil

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    /// The part of the available space macOS would have to clear first, which Disk
    /// Utility calls purgeable. Approximate: the two figures come from separate
    /// estimates, so this is their gap, never below zero.
    var purgeableBytes: Int64 {
        guard let emptyBytes else { return 0 }
        return max(0, availableBytes - emptyBytes)
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
            emptyBytes: values.volumeAvailableCapacity.map { Int64($0) }
        )
    }

    /// Deltas smaller than this are indistinguishable from other processes writing
    /// to the volume while we measured, so they cannot support a reclaim claim.
    /// Spotlight indexing alone moves the number by megabytes between two reads.
    static let noiseFloorBytes: Int64 = 64 * 1024 * 1024
}
