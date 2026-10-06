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

    @Test func impossibleDatesAreSkipped() {
        let output = """
            com.apple.TimeMachine.2026-02-30-120000.local
            com.apple.TimeMachine.2026-13-01-120000.local
            com.apple.TimeMachine.2026-10-06-250000.local
            com.apple.TimeMachine.2026-10-06-1200.local
            """
        #expect(LocalSnapshotReader.parse(output).count == 0)
    }

    /// The stamp is read in the time zone passed in, not one fixed when the app started.
    @Test func stampsAreReadInTheGivenTimeZone() {
        let utc = LocalSnapshotReader.date(fromStamp: "2026-10-06-120000", timeZone: TimeZone(identifier: "UTC")!)
        let kolkata = LocalSnapshotReader.date(fromStamp: "2026-10-06-120000", timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        #expect(utc!.timeIntervalSince(kolkata!) == 5.5 * 3600)
    }

    @Test func surroundingSpaceIsIgnored() {
        #expect(LocalSnapshotReader.parse("  com.apple.TimeMachine.2026-10-06-112116.local  \n").count == 1)
    }
}

@Suite("Remove never takes what Time Machine may still need")
struct LocalSnapshotRemovableTests {
    @Test func theNewestIsKept() {
        let snapshots = list(["2026-10-05-090000.local", "2026-10-06-080000.local", "2026-10-06-110000.local"])
        #expect(snapshots.removable.map(\.stamp) == ["2026-10-05-090000", "2026-10-06-080000"])
    }

    /// An old newest snapshot is also what a Mac that was asleep or off looks like, so
    /// age never makes it removable.
    @Test func anOldNewestIsStillKept() {
        let snapshots = list(["2026-08-01-090000.local", "2026-09-01-090000.local"])
        #expect(snapshots.removable.map(\.stamp) == ["2026-08-01-090000"])
        #expect(snapshots.newestIsOld(now: date(2026, 10, 6, 12, 0, 0)))
    }

    @Test func aSingleSnapshotIsNeverRemovable() {
        #expect(list(["2026-08-01-090000.backup"]).removable.isEmpty)
    }

    /// Time Machine keeps the last backup's snapshot until the next backup, and may
    /// compare against it, even when newer hourly ones exist.
    @Test func theLastBackupSnapshotIsKept() {
        let snapshots = list([
            "2026-10-01-090000.backup", "2026-10-03-090000.backup",
            "2026-10-05-090000.local", "2026-10-06-110000.local"
        ])
        #expect(snapshots.removable.map(\.stamp) == ["2026-10-01-090000", "2026-10-05-090000"])
    }

    /// Deleting by stamp removes every snapshot with it, so one sharing the newest's
    /// stamp can't be removed without taking the newest too.
    @Test func aSnapshotSharingTheNewestStampIsKept() {
        let snapshots = list(["2026-10-05-090000.local", "2026-10-06-110000.backup", "2026-10-06-110000.local"])
        #expect(snapshots.removable.map(\.stamp) == ["2026-10-05-090000"])
    }

    @Test func listsAreAlwaysOldestFirst() {
        let snapshots = list(["2026-10-06-110000.local", "2026-10-01-090000.local"])
        #expect(snapshots.all.first?.stamp == "2026-10-01-090000")
    }

    @Test func noSnapshotsNothingToRemove() {
        #expect(LocalSnapshots(all: []).removable.isEmpty)
    }

    private func list(_ suffixes: [String]) -> LocalSnapshots {
        LocalSnapshotReader.parse(suffixes.map { "com.apple.TimeMachine.\($0)" }.joined(separator: "\n"))
    }
}

@Suite("Removing snapshots is judged by what is left")
struct SnapshotRemovalOutcomeTests {
    private let a = snapshot("2026-10-01-090000")
    private let b = snapshot("2026-10-02-090000")
    private let c = snapshot("2026-10-06-090000")

    @Test func targetsGoneReportsTheFreedSpace() {
        let outcome = SnapshotRemovalOutcome.judge(targeted: [a, b], after: LocalSnapshots(all: [c]), freedBytes: 5_000_000_000)
        #expect(outcome == .removed(count: 2, freedBytes: 5_000_000_000))
    }

    @Test func noSettledGainClaimsNoAmount() {
        let outcome = SnapshotRemovalOutcome.judge(targeted: [a], after: LocalSnapshots(all: [c]), freedBytes: nil)
        #expect(outcome == .removed(count: 1, freedBytes: nil))
    }

    @Test func someStillListedSaysHowMany() {
        let outcome = SnapshotRemovalOutcome.judge(targeted: [a, b], after: LocalSnapshots(all: [b, c]), freedBytes: nil)
        #expect(outcome == .someLeft(removed: 1, left: 1))
    }

    @Test func nothingRemovedIsNoneRemoved() {
        let outcome = SnapshotRemovalOutcome.judge(targeted: [a, b], after: LocalSnapshots(all: [a, b, c]), freedBytes: nil)
        #expect(outcome == .noneRemoved)
    }

    /// A failed reading afterwards says nothing about what went, so it isn't reported
    /// as a failure to remove.
    @Test func anUnreadableListIsUnverified() {
        let outcome = SnapshotRemovalOutcome.judge(targeted: [a], after: nil, freedBytes: 5_000_000_000)
        #expect(outcome == .unverified)
    }

    /// macOS took a new snapshot while the old ones went: the targets still count as
    /// removed, and the new one doesn't count against them.
    @Test func aNewSnapshotMidwayDoesNotCount() {
        let fresh = snapshot("2026-10-06-100000")
        let outcome = SnapshotRemovalOutcome.judge(targeted: [a, b], after: LocalSnapshots(all: [c, fresh]), freedBytes: nil)
        #expect(outcome == .removed(count: 2, freedBytes: nil))
    }
}

private func snapshot(_ stamp: String) -> LocalSnapshot {
    LocalSnapshotReader.parse("com.apple.TimeMachine.\(stamp).local").all[0]
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
    Calendar.current.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}
