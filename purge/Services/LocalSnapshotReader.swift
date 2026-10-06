import Foundation

/// One local Time Machine snapshot.
nonisolated struct LocalSnapshot: Equatable, Sendable {
    let name: String
    /// The `yyyy-MM-dd-HHmmss` part of the name, which `tmutil` deletes by. Two
    /// snapshots can share one, and deleting it removes both.
    let stamp: String
    let date: Date

    /// The snapshot Time Machine keeps from its last backup to a backup disk, until the
    /// next one. The hourly ones end in `.local`.
    var isFromLastBackup: Bool { name.hasSuffix(".backup") }
}

/// The local Time Machine snapshots on the startup disk. macOS counts them as System
/// Data and Finder never shows them.
nonisolated struct LocalSnapshots: Equatable, Sendable {
    /// Oldest first.
    let all: [LocalSnapshot]

    init(all: [LocalSnapshot]) {
        self.all = all.sorted { $0.date != $1.date ? $0.date < $1.date : $0.name < $1.name }
    }

    var count: Int { all.count }
    var oldest: Date? { all.first?.date }
    var newest: Date? { all.last?.date }

    /// Stamps Remove never deletes: the newest snapshot's, and the newest one kept from
    /// a backup. Time Machine works out the next backup from its own record of changes,
    /// and if that is damaged it compares against the snapshot from the last backup, so
    /// without these the next backup can be far larger. Neither age nor anything else
    /// in the list proves Time Machine is done with them: an old newest snapshot is also
    /// what a Mac that was asleep or off looks like.
    var keptStamps: Set<String> {
        var kept = Set<String>()
        if let newest = all.last { kept.insert(newest.stamp) }
        if let lastBackup = all.last(where: \.isFromLastBackup) { kept.insert(lastBackup.stamp) }
        return kept
    }

    /// What Remove deletes: everything not kept.
    var removable: [LocalSnapshot] {
        let kept = keptStamps
        return all.filter { !kept.contains($0.stamp) }
    }

    /// Time Machine takes one an hour and drops each after a day, so a newest one older
    /// than that may be stuck. Only used to point at Disk Utility, never to delete.
    func newestIsOld(now: Date) -> Bool {
        guard let newest else { return false }
        return now.timeIntervalSince(newest) > 24 * 60 * 60
    }
}

/// Reads and deletes local Time Machine snapshots with `tmutil`.
///
/// None of this needs a password or Full Disk Access, and none of it asks for a privacy
/// permission (measured for #105). Neither `tmutil` nor `diskutil` reports a
/// snapshot's size, so Purge can say how many there are but not how much they hold.
nonisolated enum LocalSnapshotReader {
    private static let tmutil = "/usr/bin/tmutil"
    private static let timeMachinePrefix = "com.apple.TimeMachine."

    /// Nil when `tmutil` could not be run or failed, which must stay distinct from
    /// a reading of no snapshots.
    static func read() async -> LocalSnapshots? {
        guard let output = await ProcessRunner.runAsync(
            executablePath: tmutil,
            arguments: ["listlocalsnapshots", "/"],
            timeout: 10
        ), output.succeeded else { return nil }
        return parse(output.stdoutText)
    }

    /// Deletes each stamp with `tmutil deletelocalsnapshots <stamp>`. Never the
    /// volume-wide form, which would also take the snapshots Purge keeps, and not
    /// `thinlocalsnapshots`, which lets Time Machine pick what goes. A stamp that fails
    /// stays listed, and the follow-up reading reports it.
    static func delete(stamps: [String]) async {
        for stamp in stamps {
            _ = await ProcessRunner.runAsync(
                executablePath: tmutil,
                arguments: ["deletelocalsnapshots", stamp],
                timeout: 60
            )
        }
    }

    /// Keeps only Time Machine snapshots. The list also holds the
    /// `com.apple.os.update-*` snapshots macOS makes for updates, which `tmutil`
    /// cannot remove, so counting them would promise space Purge can't free.
    /// A Time Machine name whose stamp can't be read is left out: it is neither shown
    /// nor deleted.
    static func parse(_ output: String, timeZone: TimeZone = .current) -> LocalSnapshots {
        let snapshots = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> LocalSnapshot? in
                let name = line.trimmingCharacters(in: .whitespaces)
                guard name.hasPrefix(timeMachinePrefix) else { return nil }
                // com.apple.TimeMachine.2026-10-06-112116.local
                let stamp = String(name.dropFirst(timeMachinePrefix.count).prefix { $0 != "." })
                guard let date = date(fromStamp: stamp, timeZone: timeZone) else { return nil }
                return LocalSnapshot(name: name, stamp: stamp, date: date)
            }
        return LocalSnapshots(all: snapshots)
    }

    /// Reads `yyyy-MM-dd-HHmmss` in the given time zone. By hand rather than with a
    /// shared `DateFormatter`, so the time zone is the one in force at each reading.
    static func date(fromStamp stamp: String, timeZone: TimeZone) -> Date? {
        let parts = stamp.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2, parts[3].count == 6,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let time = Int(parts[3])
        else { return nil }
        let hour = time / 10_000, minute = time / 100 % 100, second = time % 100
        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 60
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        // Rejects days a month doesn't have, which Calendar would roll over.
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day
        else { return nil }
        return date
    }
}
