import Combine
import Foundation

/// What Remove did.
nonisolated enum SnapshotRemovalOutcome: Equatable, Sendable {
    /// Every snapshot it meant to remove went. `freedBytes` is nil unless the volume's
    /// free space settled above the noise floor, so no amount is claimed otherwise.
    case removed(count: Int, freedBytes: Int64?)
    case someLeft(removed: Int, left: Int)
    case noneRemoved
    /// The list couldn't be read afterwards, so Purge can't say what went.
    case unverified

    /// Judged by which of the targeted snapshots are still listed, not by `tmutil`'s
    /// exit status: only the list says what is still on the disk.
    static func judge(
        targeted: [LocalSnapshot],
        after: LocalSnapshots?,
        freedBytes: Int64?
    ) -> SnapshotRemovalOutcome {
        guard let after else { return .unverified }
        let remaining = Set(after.all.map(\.name))
        let left = targeted.filter { remaining.contains($0.name) }.count
        let removed = targeted.count - left
        if removed == 0 { return .noneRemoved }
        if left > 0 { return .someLeft(removed: removed, left: left) }
        return .removed(count: removed, freedBytes: freedBytes)
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
    /// The last removal and the snapshots listed after it, so the row stops showing it
    /// once the list changes.
    @Published private(set) var lastRemoval: (outcome: SnapshotRemovalOutcome, listed: [String])?

    /// Every reading takes a number; only the latest one started may land, so a slow
    /// reading never replaces a newer one.
    private var latestPass = 0

    /// The last removal's outcome while the list is still the one it saw.
    var currentRemovalOutcome: SnapshotRemovalOutcome? {
        guard let lastRemoval, lastRemoval.listed == (snapshots?.all.map(\.name) ?? []) else { return nil }
        return lastRemoval.outcome
    }

    func refresh() async {
        _ = await readLatest()
    }

    /// Reads the list and applies it if no newer reading started meanwhile. Returns the
    /// reading either way, for a caller that needs this exact one.
    private func readLatest() async -> LocalSnapshots? {
        latestPass += 1
        let pass = latestPass
        let reading = await LocalSnapshotReader.read()
        hasTriedReading = true
        // A failed reading keeps the last good one.
        if pass == latestPass, let reading {
            snapshots = reading
        }
        return reading
    }

    /// Deletes the snapshots the confirmation showed. The list is read again first and
    /// anything it now says to keep is spared, so a snapshot that became the newest
    /// while the dialog was open, or one that has already gone, is left alone.
    func remove(_ planned: [LocalSnapshot]) async {
        guard !isRemoving, !planned.isEmpty else { return }
        isRemoving = true
        defer { isRemoving = false }

        guard let fresh = await readLatest() else {
            lastRemoval = (.unverified, snapshots?.all.map(\.name) ?? [])
            return
        }
        let present = Set(fresh.all.map(\.name))
        let kept = fresh.keptStamps
        let targeted = planned.filter { present.contains($0.name) && !kept.contains($0.stamp) }
        guard !targeted.isEmpty else { return }

        let capacityBefore = VolumeCapacityReader.read()
        var stamps: [String] = []
        for snapshot in targeted where !stamps.contains(snapshot.stamp) {
            stamps.append(snapshot.stamp)
        }
        await LocalSnapshotReader.delete(stamps: stamps)
        let freed = await Self.freedBytes(since: capacityBefore)

        let reading = await readLatest()
        let outcome = SnapshotRemovalOutcome.judge(targeted: targeted, after: reading, freedBytes: freed)
        lastRemoval = (outcome, snapshots?.all.map(\.name) ?? [])
    }

    /// APFS gives the space back over a few seconds after a snapshot goes, so the
    /// volume is read until two readings a second apart agree. The figure still covers
    /// everything else written meanwhile, so it is only claimed once it has settled and
    /// clears the noise floor; a figure still moving is not claimed at all.
    private static func freedBytes(since before: VolumeCapacity?) async -> Int64? {
        guard let before else { return nil }
        let noise = VolumeCapacityReader.noiseFloorBytes
        var previous: Int64?
        for attempt in 0..<10 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let after = VolumeCapacityReader.read() else { return nil }
            let gained = after.availableBytes - before.availableBytes
            if let previous, abs(gained - previous) < noise {
                return gained >= noise ? gained : nil
            }
            previous = gained
        }
        return nil
    }
}
