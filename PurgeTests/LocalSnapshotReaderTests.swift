import Foundation
import Testing
@testable import Purge

@Suite("Only Time Machine snapshots are counted")
struct LocalSnapshotReaderTests {
    /// `tmutil listlocalsnapshots /` on a Mac with no Time Machine snapshots: only the
    /// update snapshots macOS manages.
    private let updateSnapshotsOnly = """
        Snapshots for volume group containing disk /:
        com.apple.os.update-5203530F8BB20B9DABC5CE76A0FFE87CCC885EE69B8A5488C24B458A7555E3AB
        com.apple.os.update-812A4CBD06167AC3F7093454298849D8371BD030C10902FF624EB9871B6117416A494C9C37F4F7351377AE3D81F3EA01
        com.apple.os.update-MSUPrepareUpdate

        """

    /// The same Mac after `tmutil localsnapshot`, twice.
    private let mixed = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-10-06-112200.local
        com.apple.TimeMachine.2026-10-01-090503.local
        com.apple.os.update-5203530F8BB20B9DABC5CE76A0FFE87CCC885EE69B8A5488C24B458A7555E3AB
        com.apple.os.update-MSUPrepareUpdate

        """

    @Test func updateSnapshotsAreNotCounted() {
        #expect(LocalSnapshotReader.parse(updateSnapshotsOnly).count == 0)
    }

    @Test func timeMachineSnapshotsAreCountedOldestFirst() {
        let snapshots = LocalSnapshotReader.parse(mixed)
        #expect(snapshots.all.map(\.stamp) == ["2026-10-01-090503", "2026-10-06-112200"])
        #expect(snapshots.oldest == date(2026, 10, 1, 9, 5, 3))
        #expect(snapshots.newest == date(2026, 10, 6, 11, 22, 0))
    }

    /// The snapshot kept from the last backup ends in `.backup`; a stuck 140 GB one was
    /// reported with that name.
    @Test func backupSnapshotsCountToo() {
        let output = """
            com.apple.TimeMachine.2025-11-11-041945.backup
            com.apple.TimeMachine.2025-11-12-100000.local
            """
        #expect(LocalSnapshotReader.parse(output).all.map(\.stamp) == ["2025-11-11-041945", "2025-11-12-100000"])
    }

    @Test func emptyOutputHasNoSnapshots() {
        let snapshots = LocalSnapshotReader.parse("")
        #expect(snapshots.count == 0)
        #expect(snapshots.oldest == nil)
    }

    @Test func unreadableNamesAreSkipped() {
        let output = """
            com.apple.TimeMachine.not-a-date.local
            com.apple.TimeMachine.2026-10-06-112116.local
            garbage line
            """
        #expect(LocalSnapshotReader.parse(output).count == 1)
    }

    @Test func surroundingSpaceIsIgnored() {
        #expect(LocalSnapshotReader.parse("  com.apple.TimeMachine.2026-10-06-112116.local  \n").count == 1)
    }
}

@Suite("Remove keeps the newest snapshot unless they are stuck")
struct LocalSnapshotRemovableTests {
    private let now = date(2026, 10, 6, 12, 0, 0)

    @Test func recentSetKeepsTheNewest() {
        let snapshots = snapshotsAt(hoursAgo: [30, 5, 1])
        #expect(snapshots.removable(now: now).map(\.date) == [hoursAgo(30), hoursAgo(5)])
    }

    @Test func oneRecentSnapshotHasNothingToRemove() {
        #expect(snapshotsAt(hoursAgo: [2]).removable(now: now).isEmpty)
    }

    /// Time Machine replaces snapshots hourly, so a newest one over a day old is stuck
    /// and holds space nothing will free.
    @Test func stuckSetRemovesEveryOne() {
        #expect(snapshotsAt(hoursAgo: [24 * 30, 25]).removable(now: now).count == 2)
    }

    @Test func oneStuckSnapshotIsRemoved() {
        #expect(snapshotsAt(hoursAgo: [24 * 30]).removable(now: now).count == 1)
    }

    @Test func noSnapshotsNothingToRemove() {
        #expect(LocalSnapshots(all: []).removable(now: now).isEmpty)
    }

    private func hoursAgo(_ hours: Double) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    private func snapshotsAt(hoursAgo hours: [Double]) -> LocalSnapshots {
        LocalSnapshots(all: hours.map { LocalSnapshot(stamp: "\($0)", date: hoursAgo($0)) })
    }
}

@Suite("Removing snapshots is judged by what is left")
struct SnapshotRemovalOutcomeTests {
    private let a = LocalSnapshot(stamp: "a", date: date(2026, 10, 1, 9, 0, 0))
    private let b = LocalSnapshot(stamp: "b", date: date(2026, 10, 2, 9, 0, 0))
    private let c = LocalSnapshot(stamp: "c", date: date(2026, 10, 6, 9, 0, 0))

    @Test func targetsGoneReportsTheFreedSpace() {
        let outcome = SnapshotRemovalOutcome.judge(
            targeted: [a, b], after: LocalSnapshots(all: [c]), keptNewest: true, freedBytes: 5_000_000_000
        )
        #expect(outcome == .removed(count: 2, freedBytes: 5_000_000_000, keptNewest: true))
    }

    @Test func noMeasurableGainClaimsNoAmount() {
        let outcome = SnapshotRemovalOutcome.judge(
            targeted: [a], after: LocalSnapshots(all: []), keptNewest: false, freedBytes: nil
        )
        #expect(outcome == .removed(count: 1, freedBytes: nil, keptNewest: false))
    }

    @Test func someStillListedSaysHowMany() {
        let outcome = SnapshotRemovalOutcome.judge(
            targeted: [a, b], after: LocalSnapshots(all: [b, c]), keptNewest: true, freedBytes: nil
        )
        #expect(outcome == .someLeft(removed: 1, left: 1))
    }

    @Test func nothingRemovedIsNoneRemoved() {
        let outcome = SnapshotRemovalOutcome.judge(
            targeted: [a, b], after: LocalSnapshots(all: [a, b, c]), keptNewest: true, freedBytes: nil
        )
        #expect(outcome == .noneRemoved)
    }

    @Test func anUnreadableListClaimsNothing() {
        let outcome = SnapshotRemovalOutcome.judge(
            targeted: [a], after: nil, keptNewest: false, freedBytes: 5_000_000_000
        )
        #expect(outcome == .noneRemoved)
    }

    /// macOS took a new snapshot while the old ones went: the targets still count as
    /// removed, and the new one doesn't count against them.
    @Test func aNewSnapshotMidwayDoesNotCount() {
        let fresh = LocalSnapshot(stamp: "d", date: date(2026, 10, 6, 10, 0, 0))
        let outcome = SnapshotRemovalOutcome.judge(
            targeted: [a, b], after: LocalSnapshots(all: [c, fresh]), keptNewest: true, freedBytes: nil
        )
        #expect(outcome == .removed(count: 2, freedBytes: nil, keptNewest: true))
    }
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
    Calendar.current.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}
