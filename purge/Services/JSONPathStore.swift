import Foundation

/// Entries keyed by path, kept as one JSON file in Purge's Application Support
/// folder and cached after the first read. The exclusion list and the safety
/// overrides each keep one (#185).
nonisolated final class JSONPathStore<Entry: Codable & Sendable>: @unchecked Sendable {
    private let fileName: String
    /// Re-keys what was read from disk. Stores whose keys never change spelling
    /// pass entries through as they are.
    private let migrate: @Sendable ([String: Entry]) -> [String: Entry]
    private let lock = NSLock()
    private var loadedEntries: [String: Entry]?

    init(
        fileName: String,
        migrate: @escaping @Sendable ([String: Entry]) -> [String: Entry] = { $0 }
    ) {
        self.fileName = fileName
        self.migrate = migrate
    }

    var fileURL: URL {
        AppSupportFolder.url().appendingPathComponent(fileName, isDirectory: false)
    }

    /// Reads the entries under the lock.
    func read<Result>(_ body: ([String: Entry]) -> Result) -> Result {
        lock.withLock { body(loadLocked()) }
    }

    /// Changes the entries and writes the file. `body` returns false when it
    /// changed nothing, and nothing is written. Returns false when the file could
    /// not be written: the change still holds until Purge quits, but it was not
    /// saved, and the caller says so.
    @discardableResult
    func update(_ body: (inout [String: Entry]) -> Bool) -> Bool {
        lock.withLock {
            var entries = loadLocked()
            guard body(&entries) else { return true }
            loadedEntries = entries
            return write(entries)
        }
    }

    /// Modification date of the file, if it exists on disk.
    var lastUpdated: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private func loadLocked() -> [String: Entry] {
        if let loadedEntries { return loadedEntries }
        let disk = readFromDisk()
        loadedEntries = disk
        return disk
    }

    private func readFromDisk() -> [String: Entry] {
        ensureDirectory()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([String: Entry].self, from: data)
        else {
            return [:]
        }
        return migrate(decoded)
    }

    private func write(_ entries: [String: Entry]) -> Bool {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(entries).write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: AppSupportFolder.url(), withIntermediateDirectories: true)
    }
}
