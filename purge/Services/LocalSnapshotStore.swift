import Combine
import Foundation

/// What Remove did.
nonisolated enum SnapshotRemovalOutcome: Equatable, Sendable {
    /// Every snapshot it meant to remove went. `freedBytes` is nil when the volume did
    /// not move by more than the noise floor, so no amount can be claimed.
    case removed(count: Int, freedBytes: Int64?, keptNewest: Bool)
    case someLeft(removed: Int, left: Int)
    /// None went, or `tmutil` could not be read afterwards.
    case noneRemoved

    /// Judged by which of the targeted snapshots are still listed, not by `tmutil`'s
    /// exit status: only the list says what is still on the disk.
    static func judge(
        targeted: [LocalSnapshot],
        after: LocalSnapshots?,
        keptNewest: Bool,
        freedBytes: Int64?
    ) -> SnapshotRemovalOutcome {
        guard let after else { return .noneRemoved }
        let remaining = Set(after.all.map(\.stamp))
        let left = targeted.filter { remaining.contains($0.stamp) }.count
        let removed = targeted.count - left
        if removed == 0 { return .noneRemoved }
        if left > 0 { return .someLeft(removed: removed, left: left) }
        return .removed(count: removed, freedBytes: freedBytes, keptNewest: keptNewest)
    }
}

/// The local Time Machine snapshots the Overview shows, read again whenever the page
/// appears or Purge comes back to the front: macOS takes and drops them on its own.
/// Shared, so what Remove did is still there after visiting another tab.
@MainActor
final class LocalSnapshotStore: ObservableObject {
    static let shared = LocalSnapshotStore()

    /// Nil until the first reading lands, or when `tmutil` never answered.
    @Published private(set) var snapshots: LocalSnapshots?
    /// Whether a reading has been tried, so "checking" and "couldn't check" differ.
    @Published private(set) var hasTriedReading = false
    @Published private(set) var isRemoving = false
    /// The last removal and the snapshots it left, so the row can stop showing it once
    /// macOS takes a new one or drops another.
    @Published private(set) var lastRemoval: (outcome: SnapshotRemovalOutcome, left: [String])?

    /// Guards against a slow reading overwriting a newer one.
    private var latestPass = 0

    /// The last removal's outcome while the snapshots are still the ones it left.
    var currentRemovalOutcome: SnapshotRemovalOutcome? {
        guard let lastRemoval, lastRemoval.left == (snapshots?.all.map(\.stamp) ?? []) else { return nil }
        return lastRemoval.outcome
    }

    func refresh() async {
        latestPass += 1
        let pass = latestPass
        let reading = await LocalSnapshotReader.read()
        guard pass == latestPass else { return }
        hasTriedReading = true
        // A failed reading keeps the last good one.
        if let reading {
            snapshots = reading
        }
    }

    /// Deletes the removable snapshots, then says what went and how much space came
    /// back.
    func remove(now: Date = .now) async {
        guard !isRemoving, let current = snapshots else { return }
        let targeted = current.removable(now: now)
        guard !targeted.isEmpty else { return }
        isRemoving = true
        defer { isRemoving = false }

        let keptNewest = targeted.count < current.count
        let capacityBefore = VolumeCapacityReader.read()
        await LocalSnapshotReader.delete(targeted, includesNewest: !keptNewest)

        latestPass += 1
        let reading = await LocalSnapshotReader.read()
        if let reading {
            snapshots = reading
        }
        let freed = await Self.freedBytes(since: capacityBefore)
        let outcome = SnapshotRemovalOutcome.judge(
            targeted: targeted,
            after: reading,
            keptNewest: keptNewest,
            freedBytes: freed
        )
        lastRemoval = (outcome, snapshots?.all.map(\.stamp) ?? [])
    }

    /// APFS gives the space back over a few seconds after a snapshot goes, so the
    /// volume is read until the figure stops moving. Only a gain above the noise floor
    /// counts as freed.
    private static func freedBytes(since before: VolumeCapacity?) async -> Int64? {
        guard let before else { return nil }
        let noise = VolumeCapacityReader.noiseFloorBytes
        var previous: Int64?
        for attempt in 0..<10 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let after = VolumeCapacityReader.read() else { break }
            let gained = after.availableBytes - before.availableBytes
            if let previous, gained >= noise, abs(gained - previous) < noise {
                return gained
            }
            previous = gained
        }
        guard let previous, previous >= noise else { return nil }
        return previous
    }
}
