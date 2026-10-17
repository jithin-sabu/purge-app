import Foundation

/// Reads and writes the owner ledger (`LeftoverOwnerLedger`, #224) as one JSON
/// file beside the cleanup ledger:
/// `~/Library/Application Support/io.getpurge.app/leftover-owners.json`.
///
/// The file is small, one entry per app with a human-named folder, so every
/// write replaces it whole and atomically. A file that cannot be read counts as
/// empty: the only effect is that fewer leftovers can be attributed, which is
/// the safe side.
///
/// Tests run inside a hosted copy of the app that shares the user's Application
/// Support, and must never teach the real ledger about made-up apps, so the
/// default file moves to the test run's scratch folder under the test host.
nonisolated final class LeftoverOwnerLedgerStore: @unchecked Sendable {
    static let shared = LeftoverOwnerLedgerStore(fileURL: defaultFileURL())

    static let fileName = "leftover-owners.json"

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
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

    /// The ledger as written, with nothing dropped.
    func load() -> LeftoverOwnerLedger {
        lock.withLock { read() }
    }

    /// The ledger with every folder that is gone dropped, which is what the
    /// Leftovers scan judges with. The pruned ledger is written back.
    func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> LeftoverOwnerLedger {
        lock.withLock {
            var ledger = read()
            let before = ledger
            ledger.prune { Self.folderExists($0, home: home) }
            if ledger != before { write(ledger) }
            return ledger
        }
    }

    /// Adds the folders the installed-apps scan matched to one app by name.
    /// Paths outside `home` are not recorded.
    func record(
        bundleID: String,
        displayName: String,
        folders: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        seenAt: Date = Date()
    ) {
        let relative = folders.compactMap { LeftoverOwnerLedger.relativePath($0, home: home) }
        guard !relative.isEmpty else { return }
        lock.withLock {
            var ledger = read()
            ledger.record(bundleID: bundleID, displayName: displayName, folders: relative, seenAt: seenAt)
            ledger.prune { Self.folderExists($0, home: home) }
            write(ledger)
        }
    }

    private static func folderExists(_ relativePath: String, home: URL) -> Bool {
        guard let url = LeftoverOwnerLedger.url(forRelativePath: relativePath, home: home) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func read() -> LeftoverOwnerLedger {
        guard let data = try? Data(contentsOf: fileURL) else { return LeftoverOwnerLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let ledger = try? decoder.decode(LeftoverOwnerLedger.self, from: data),
              ledger.version == LeftoverOwnerLedger.currentVersion else {
            return LeftoverOwnerLedger()
        }
        return ledger
    }

    private func write(_ ledger: LeftoverOwnerLedger) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(ledger) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
