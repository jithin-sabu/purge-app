import Foundation

/// Free space on the startup volume. Every space figure the spike records is a
/// delta between two of these readings, never Apple's estimate (purge-app#133).
enum Volume {
    static let root = URL(fileURLWithPath: "/")

    /// Nil when the volume could not be read, which stays distinct from zero.
    static func freeBytes() -> Int64? {
        guard let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return free
    }

    /// Below this a delta is indistinguishable from other processes writing
    /// (Purge uses the same floor).
    static let noiseFloorBytes: Int64 = 64 * 1024 * 1024

    /// Space gained since `before`, once two readings a second apart agree.
    /// APFS gives space back over a few seconds, and `deleted` works in the
    /// background, so the figure is read until it stops moving. Nil when it
    /// never settles or stays under the noise floor.
    static func settledGain(since before: Int64, maxSeconds: Int = 30) -> (gained: Int64?, lastReading: Int64?) {
        var previous: Int64?
        var last: Int64?
        for attempt in 0..<maxSeconds {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            guard let after = freeBytes() else { return (nil, last) }
            last = after
            let gained = after - before
            if let previous, abs(gained - previous) < noiseFloorBytes {
                return (gained >= noiseFloorBytes ? gained : nil, after)
            }
            previous = gained
        }
        return (nil, last)
    }
}
