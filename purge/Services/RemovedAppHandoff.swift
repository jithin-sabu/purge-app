import Foundation

/// Files the background watcher and Purge share (issue #65).
///
/// The watcher runs when Purge does not. It records each app that left, and
/// Purge reads that record when it is opened. Purge writes the ignore list
/// before it moves a bundle itself, so the watcher does not open a second review.
///
/// Anything running as the user can write here, so Purge treats a record as a
/// hint to check, never as proof: see `RemovedAppWatchPolicy.isValidRecord` and
/// the presence checks in `RemovedAppMonitor`.
nonisolated enum RemovedAppHandoff {
    struct Record: Codable, Equatable {
        var path: String
        var bundleID: String
        var name: String
        /// The bundle's file number before it left, used to find its copy in the
        /// Trash. Optional so records from earlier builds still decode.
        var fileNumber: UInt64?
        var removedAt: Date?
    }

    private struct Ignored: Codable {
        var path: String
        var until: Date
    }

    /// Tests point this at a temporary directory. The app and the watcher use the default.
    static var root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Purge", isDirectory: true)

    static let launchURL = URL(string: "purge://removed-apps")!
    static let agentPlistName = "io.getpurge.watch.plist"
    static let ignoreGrace: TimeInterval = 120

    private static var pendingFolder: URL {
        root.appendingPathComponent("pending-removals", isDirectory: true)
    }

    static func enqueue(_ record: Record) {
        try? FileManager.default.createDirectory(at: pendingFolder, withIntermediateDirectories: true)
        let file = pendingFolder.appendingPathComponent(UUID().uuidString + ".json")
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Pending records, oldest first. Leaves the files in place so a review that
    /// cannot be shown yet (onboarding, no Full Disk Access) can be read again.
    /// Unreadable records and ones older than `RemovedAppWatchPolicy.recordLifetime`
    /// are deleted as they are found.
    static func pending(now: Date = Date()) -> [Record] {
        loadPending(now: now).map(\.record)
    }

    /// Removes every pending record for `path`. Called once a removal has been
    /// shown, or once it has been decided not to be a removal.
    static func discard(path: String) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        for entry in loadPending(now: Date())
        where URL(fileURLWithPath: entry.record.path).standardizedFileURL.path == key {
            try? FileManager.default.removeItem(at: entry.file)
        }
    }

    /// Removes every pending record. Called when the feature is turned off, so
    /// turning it back on later does not replay old removals.
    static func clearPending() {
        try? FileManager.default.removeItem(at: pendingFolder)
    }

    private static func loadPending(now: Date) -> [(file: URL, record: Record)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: pendingFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        return dated
            .sorted { $0.1 < $1.1 }
            .compactMap { file, modified in
                guard let data = try? Data(contentsOf: file),
                      let record = try? JSONDecoder().decode(Record.self, from: data),
                      now.timeIntervalSince(record.removedAt ?? modified) < RemovedAppWatchPolicy.recordLifetime
                else {
                    try? FileManager.default.removeItem(at: file)
                    return nil
                }
                return (file, record)
            }
    }

    static func ignore(paths: [String]) {
        var current = loadIgnored().filter { $0.until > Date() }
        let until = Date().addingTimeInterval(ignoreGrace)
        for path in paths {
            current.removeAll { $0.path == path }
            current.append(Ignored(path: path, until: until))
        }
        save(current)
    }

    static func isIgnored(path: String) -> Bool {
        loadIgnored().contains { $0.path == path && $0.until > Date() }
    }

    private static var ignoreFile: URL {
        root.appendingPathComponent("ignored-removals.json")
    }

    private static func loadIgnored() -> [Ignored] {
        guard let data = try? Data(contentsOf: ignoreFile),
              let decoded = try? JSONDecoder().decode([Ignored].self, from: data)
        else { return [] }
        return decoded
    }

    private static func save(_ ignored: [Ignored]) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(ignored) else { return }
        try? data.write(to: ignoreFile, options: .atomic)
    }
}
