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
/// Tests run inside a hosted copy of the app that shares the user's Application
/// Support, so under the test host the default file moves to the run's scratch folder.
nonisolated final class LastScanStore: @unchecked Sendable {
    static let fileName = "last-scan.json"

    private let fileURL: URL
    private let appBuild: String
    private let lock = NSLock()

    init(fileURL: URL = LastScanStore.defaultFileURL(), appBuild: String = LastScanSnapshot.currentAppBuild()) {
        self.fileURL = fileURL
        self.appBuild = appBuild
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
    /// another build or version is removed, so it is never read again.
    func load() -> LastScanSnapshot? {
        lock.withLock {
            guard let snapshot = read() else { return nil }
            guard snapshot.version == LastScanSnapshot.currentVersion, snapshot.appBuild == appBuild else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return snapshot
        }
    }

    /// Replaces `sections` with what `update` holds for them; the others keep what
    /// the file had.
    func save(_ sections: Set<LastScanSection>, from update: LastScanSnapshot) {
        guard !sections.isEmpty else { return }
        lock.withLock {
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
        lock.withLock {
            guard var snapshot = read(), snapshot.appBuild == appBuild else { return }
            let before = snapshot
            snapshot.removeRows { paths.contains($0.path) }
            if snapshot != before { write(snapshot) }
        }
    }

    func remove() {
        lock.withLock { _ = try? FileManager.default.removeItem(at: fileURL) }
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
