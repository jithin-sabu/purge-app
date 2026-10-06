import Combine
import Foundation

/// What asking macOS to remove the snapshots did.
nonisolated enum SnapshotThinOutcome: Equatable, Sendable {
    /// All of them went. `freedBytes` is nil when the volume did not move by more than
    /// the noise floor, so no amount can be claimed.
    case removedAll(count: Int, freedBytes: Int64?)
    case someLeft(removed: Int, left: Int)
    /// None went, or `tmutil` could not be read afterwards.
    case noneRemoved

    /// Judged by the snapshots left afterwards, not by `tmutil`'s exit status: only the
    /// list says what is still on the disk.
    static func judge(before: Int, after: Int?, freedBytes: Int64?) -> SnapshotThinOutcome {
        guard let after else { return .noneRemoved }
        let removed = max(0, before - after)
        if removed == 0 { return .noneRemoved }
        if after > 0 { return .someLeft(removed: removed, left: after) }
        return .removedAll(count: removed, freedBytes: freedBytes)
    }
}

/// The local Time Machine snapshots the Overview shows, read again whenever the page
/// appears or Purge comes back to the front: macOS takes and drops them on its own.
@MainActor
final class LocalSnapshotStore: ObservableObject {
    /// Nil until the first reading lands, or when `tmutil` never answered.
    @Published private(set) var snapshots: LocalSnapshots?
    @Published private(set) var isThinning = false
    /// The last removal and how many snapshots it left, so the row can stop showing
    /// it once macOS takes a new one.
    @Published private(set) var lastThin: (outcome: SnapshotThinOutcome, countAfter: Int)?

    /// Guards against a slow reading overwriting a newer one.
    private var latestPass = 0

    /// The last removal's outcome while the count is still what it left.
    var currentThinOutcome: SnapshotThinOutcome? {
        guard let lastThin, lastThin.countAfter == (snapshots?.count ?? 0) else { return nil }
        return lastThin.outcome
    }

    func refresh() async {
        latestPass += 1
        let pass = latestPass
        let reading = await LocalSnapshotReader.read()
        guard pass == latestPass else { return }
        // A failed reading keeps the last good one rather than hiding the row.
        if let reading {
            snapshots = reading
        }
    }

    /// Asks macOS to remove every snapshot it can, then says what went and how much
    /// space came back.
    func thin() async {
        guard !isThinning else { return }
        isThinning = true
        defer { isThinning = false }

        let before = snapshots?.count ?? 0
        let capacityBefore = VolumeCapacityReader.read()
        await LocalSnapshotReader.thin()

        latestPass += 1
        let reading = await LocalSnapshotReader.read()
        if let reading {
            snapshots = reading
        }
        let freed = await Self.freedBytes(since: capacityBefore)
        let outcome = SnapshotThinOutcome.judge(before: before, after: reading?.count, freedBytes: freed)
        lastThin = (outcome, snapshots?.count ?? 0)
    }

    /// APFS gives the space back a moment after a snapshot goes, so the volume is read
    /// a few times. Only a gain above the noise floor counts as freed.
    private static func freedBytes(since before: VolumeCapacity?) async -> Int64? {
        guard let before else { return nil }
        for attempt in 0..<5 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let after = VolumeCapacityReader.read() else { return nil }
            let gained = after.availableBytes - before.availableBytes
            if gained >= VolumeCapacityReader.noiseFloorBytes {
                return gained
            }
        }
        return nil
    }
}
