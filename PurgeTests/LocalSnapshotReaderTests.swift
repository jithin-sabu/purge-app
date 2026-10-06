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

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    @Test func updateSnapshotsAreNotCounted() {
        #expect(LocalSnapshotReader.parse(updateSnapshotsOnly).count == 0)
    }

    @Test func timeMachineSnapshotsAreCountedOldestFirst() {
        let snapshots = LocalSnapshotReader.parse(mixed)
        #expect(snapshots.count == 2)
        #expect(snapshots.oldest == date(2026, 10, 1, 9, 5, 3))
        #expect(snapshots.dates.last == date(2026, 10, 6, 11, 22, 0))
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
