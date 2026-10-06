import Foundation

/// One local Time Machine snapshot: its name's stamp, which `tmutil` deletes by, and
/// when it was taken.
nonisolated struct LocalSnapshot: Equatable, Sendable {
    let stamp: String
    let date: Date
}

/// The local Time Machine snapshots on the startup disk. macOS counts them as System
/// Data and Finder never shows them.
nonisolated struct LocalSnapshots: Equatable, Sendable {
    /// Oldest first.
    let all: [LocalSnapshot]

    var count: Int { all.count }
    var oldest: Date? { all.first?.date }
    var newest: Date? { all.last?.date }

    /// Time Machine takes a snapshot every hour and drops each after a day, so a newest
    /// snapshot older than that means it has stopped replacing them.
    static let staleAge: TimeInterval = 24 * 60 * 60

    /// What Remove deletes. Normally every snapshot but the newest: Time Machine can
    /// compare against it to work out the next backup if its usual record of changes
    /// is damaged, and it is also the smallest. When even the newest is over a day
    /// old, Time Machine is no longer replacing them, and keeping it would leave the
    /// space held, so all of them go.
    func removable(now: Date) -> [LocalSnapshot] {
        guard let newest = all.last else { return [] }
        if now.timeIntervalSince(newest.date) > Self.staleAge {
            return all
        }
        return Array(all.dropLast())
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

    /// Deletes each snapshot by its stamp. Not `thinlocalsnapshots`: it lets Time
    /// Machine pick what goes, so it can't be told to keep the newest, and macOS's own
    /// purging of snapshots has been shown to miss space that is there.
    ///
    /// Deleting by stamp has been seen to fail with "Stale NFS file handle" on a stuck
    /// snapshot that deleting by volume then removed. So when every snapshot is meant
    /// to go and some are left, the volume-wide delete finishes the job. It never runs
    /// when the newest is being kept, since it would take that one too.
    static func delete(_ snapshots: [LocalSnapshot], includesNewest: Bool) async {
        var failed = false
        for snapshot in snapshots {
            let output = await ProcessRunner.runAsync(
                executablePath: tmutil,
                arguments: ["deletelocalsnapshots", snapshot.stamp],
                timeout: 60
            )
            if output?.succeeded != true {
                failed = true
            }
        }
        if failed, includesNewest {
            _ = await ProcessRunner.runAsync(
                executablePath: tmutil,
                arguments: ["deletelocalsnapshots", "/"],
                timeout: 120
            )
        }
    }

    /// Keeps only Time Machine snapshots. The list also holds the
    /// `com.apple.os.update-*` snapshots macOS makes for updates, which `tmutil`
    /// cannot remove, so counting them would promise space Purge can't free.
    /// Time Machine names end in `.local` for the hourly ones and `.backup` for the
    /// one kept from the last backup; both count.
    static func parse(_ output: String) -> LocalSnapshots {
        let snapshots = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> LocalSnapshot? in
                let name = line.trimmingCharacters(in: .whitespaces)
                guard name.hasPrefix(timeMachinePrefix) else { return nil }
                // com.apple.TimeMachine.2026-10-06-112116.local
                let stamp = String(name.dropFirst(timeMachinePrefix.count).prefix { $0 != "." })
                guard let date = dateFormatter.date(from: stamp) else { return nil }
                return LocalSnapshot(stamp: stamp, date: date)
            }
            .sorted { $0.date < $1.date }
        return LocalSnapshots(all: snapshots)
    }

    /// The stamp in a snapshot's name, in this Mac's time zone.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
