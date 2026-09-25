import Foundation

/// Files the background watcher and Purge share (issue #65).
///
/// The watcher runs when Purge does not. It records each app that left, and
/// Purge reads that record when it is opened. Purge writes the ignore list
/// before it moves a bundle itself, so the watcher does not open a second review.
nonisolated enum RemovedAppHandoff {
    struct Record: Codable, Equatable {
        var path: String
        var bundleID: String
        var name: String
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

    static func enqueue(_ record: Record) {
        let folder = root.appendingPathComponent("pending-removals", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".json")
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Pending records, oldest first. Each file is removed as it is read.
    static func drain() -> [Record] {
        let folder = root.appendingPathComponent("pending-removals", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let ordered = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        return ordered.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data)
            else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            try? FileManager.default.removeItem(at: file)
            return record
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
