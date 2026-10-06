import Foundation

/// The local Time Machine snapshots on the startup disk. macOS counts them as System
/// Data and Finder never shows them.
nonisolated struct LocalSnapshots: Equatable, Sendable {
    /// When each snapshot was taken, oldest first.
    let dates: [Date]

    var count: Int { dates.count }
    var oldest: Date? { dates.first }
}

/// Reads and thins local Time Machine snapshots with `tmutil`.
///
/// Neither needs a password or Full Disk Access, and neither asks for any privacy
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

    /// Asks macOS to remove every local Time Machine snapshot it can, the same way it
    /// does by itself when the disk runs low. The amount is far more than any disk
    /// holds, so nothing is kept back to reach it. Returns whether `tmutil` succeeded.
    static func thin() async -> Bool {
        let output = await ProcessRunner.runAsync(
            executablePath: tmutil,
            arguments: ["thinlocalsnapshots", "/", "999999999999999", "4"],
            timeout: 60
        )
        return output?.succeeded ?? false
    }

    /// Keeps only Time Machine snapshots. The list also holds the
    /// `com.apple.os.update-*` snapshots macOS makes for updates, which `tmutil`
    /// cannot remove, so counting them would promise space Purge can't free.
    static func parse(_ output: String) -> LocalSnapshots {
        let dates = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Date? in
                let name = line.trimmingCharacters(in: .whitespaces)
                guard name.hasPrefix(timeMachinePrefix) else { return nil }
                // com.apple.TimeMachine.2026-10-06-112116.local
                let stamp = name.dropFirst(timeMachinePrefix.count).prefix { $0 != "." }
                return dateFormatter.date(from: String(stamp))
            }
            .sorted()
        return LocalSnapshots(dates: dates)
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
