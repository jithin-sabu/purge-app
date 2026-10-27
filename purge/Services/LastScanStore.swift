import Foundation

/// Reads and writes the last scan's rows (`LastScanSnapshot`, #283) as one JSON
/// file beside the other ledgers:
/// `~/Library/Application Support/io.getpurge.app/last-scan.json`.
///
/// The file is a throwaway copy. Every finished scan replaces its sections, and a
/// file another build or version wrote is removed unread, so an update never shows
/// rows judged by older rules. A file that cannot be read counts as empty: the only
/// effect is that a reopen waits for its scans, as it did before this file existed.
///
/// Saves and forgets run on one serial queue, in the order they are called, so a
/// snapshot taken before a clean can never land after the clean's forget and put
/// the cleaned row back. `flush()` waits for everything queued, which quitting does.
///
/// Tests run inside a hosted copy of the app that shares the user's Application
/// Support, so under the test host the default file moves to the run's scratch folder.
nonisolated final class LastScanStore: @unchecked Sendable {
    static let fileName = "last-scan.json"

    private let fileURL: URL
    private let appBuild: String
    private let home: URL
    private let queue = DispatchQueue(label: "io.getpurge.last-scan", qos: .utility)

    init(
        fileURL: URL = LastScanStore.defaultFileURL(),
        appBuild: String = LastScanSnapshot.currentAppBuild(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileURL = fileURL
        self.appBuild = appBuild
        self.home = home
    }

    static func defaultFileURL() -> URL {
        if TestHost.isActive() {
            return TestHost.supportDirectory().appendingPathComponent(fileName)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("io.getpurge.app", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(fileName)
    }

    /// The saved rows, or nil when there are none this build can show. A file from
    /// another build or version is removed, so it is never read again. Waits for
    /// anything already queued.
    func load() -> LastScanSnapshot? {
        queue.sync { () -> LastScanSnapshot? in
            guard let snapshot = read() else { return nil }
            guard snapshot.version == LastScanSnapshot.currentVersion, snapshot.appBuild == appBuild else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return snapshot
        }
    }

    /// Replaces `sections` with what `update` holds for them; the others keep what
    /// the file had. Rows with a path in a protected folder, by name or through a
    /// link, are left out here, off the main thread, since following links reads
    /// the disk.
    func save(_ sections: Set<LastScanSection>, from update: LastScanSnapshot) {
        guard !sections.isEmpty else { return }
        let home = home
        queue.async { [self] in
            var update = update
            update.removeRows { !LastScanSnapshot.isWritable($0, home: home) }
            var snapshot = current()
            for section in sections {
                snapshot.copy(section, from: update)
            }
            write(snapshot)
        }
    }

    /// Drops every saved row at one of `paths` (as `URL.path` spells them), from
    /// every section. A clean calls it so a row it removed never comes back at the
    /// next launch, even from a section this session has not scanned again.
    func forget(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        queue.async { [self] in
            guard var snapshot = read(), snapshot.appBuild == appBuild else { return }
            let before = snapshot
            snapshot.removeRows { paths.contains($0.path) }
            if snapshot != before { write(snapshot) }
        }
    }

    func remove() {
        queue.async { [self] in _ = try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Returns once every save and forget queued so far has reached the disk.
    func flush() {
        queue.sync {}
    }

    /// What a save builds on: the file when this build wrote it, else a fresh one.
    private func current() -> LastScanSnapshot {
        if let snapshot = read(), snapshot.version == LastScanSnapshot.currentVersion, snapshot.appBuild == appBuild {
            return snapshot
        }
        return LastScanSnapshot(appBuild: appBuild)
    }

    private func read() -> LastScanSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(LastScanSnapshot.self, from: data)
    }

    private func write(_ snapshot: LastScanSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
