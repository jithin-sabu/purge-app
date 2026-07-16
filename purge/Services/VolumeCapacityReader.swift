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
}
