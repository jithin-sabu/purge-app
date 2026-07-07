import Foundation

struct UserOverrideEntry: Codable, Sendable {
    let overrideTag: String
    let overrideDate: Date
    let originalTag: String

    enum CodingKeys: String, CodingKey {
        case overrideTag
        case overrideDate
        case originalTag
    }
}

/// Persists user-chosen safety categories keyed by exact filesystem path.
/// Overrides take absolute priority over AI cache, bundled database, and tier list.
enum UserOverridesStore {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var loadedEntries: [String: UserOverrideEntry]?

    nonisolated private static func supportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("io.getpurge.app", isDirectory: true)
    }

    nonisolated static func fileURL() -> URL {
        supportURL().appendingPathComponent("user_overrides.json", isDirectory: false)
    }

    nonisolated private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: supportURL(), withIntermediateDirectories: true)
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    nonisolated private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    nonisolated private static func readFromDisk() -> [String: UserOverrideEntry] {
        ensureDirectory()
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? makeDecoder().decode([String: UserOverrideEntry].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    nonisolated private static func loadEntriesLocked() -> [String: UserOverrideEntry] {
        if let loadedEntries { return loadedEntries }
        let disk = readFromDisk()
        loadedEntries = disk
        return disk
    }

    nonisolated private static func persistLocked(_ entries: [String: UserOverrideEntry]) {
        ensureDirectory()
        if let data = try? makeEncoder().encode(entries) {
            try? data.write(to: fileURL(), options: [.atomic])
        }
        loadedEntries = entries
    }

    nonisolated private static func canonicalKey(forPath url: URL) -> String {
        url.standardizedFileURL.path
    }

    nonisolated static func read(path: URL) -> UserOverrideEntry? {
        lock.lock()
        defer { lock.unlock() }
        return loadEntriesLocked()[canonicalKey(forPath: path)]
    }

    nonisolated static func write(
        path: URL,
        overrideTag: String,
        originalTag: String,
        date: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadEntriesLocked()
        entries[canonicalKey(forPath: path)] = UserOverrideEntry(
            overrideTag: overrideTag,
            overrideDate: date,
            originalTag: originalTag
        )
        persistLocked(entries)
    }

    nonisolated static func remove(path: URL) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadEntriesLocked()
        guard entries.removeValue(forKey: canonicalKey(forPath: path)) != nil else { return }
        persistLocked(entries)
    }

    nonisolated static func allOverriddenPaths() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(loadEntriesLocked().keys)
    }

    nonisolated static func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return loadEntriesLocked().count
    }

    /// Modification date of `user_overrides.json`, if the file exists on disk.
    nonisolated static func lastUpdated() -> Date? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        return attrs[.modificationDate] as? Date
    }

    /// Resolves a stored override into a `SafetyInfo` that takes priority over
    /// AI cache, bundled database, and tier list. The displayed headline keeps
    /// the friendly fallback so labels reflect the same name shown elsewhere.
    nonisolated static func safetyInfo(
        from entry: UserOverrideEntry,
        friendlyHeadline: String
    ) -> SafetyInfo {
        let level: SafetyLevel
        switch entry.overrideTag.lowercased() {
        case "safe": level = .safe
        case "medium": level = .medium
        // Legacy "danger" override maps to Not Sure; the "Do Not Delete" tier
        // no longer exists.
        case "danger": level = .unknown
        case "unknown": level = .unknown
        default: level = .unknown
        }

        let explanation: String
        switch level {
        case .safe:
            explanation = "You marked this as Safe to Clean."
        case .medium:
            explanation = "You marked this as Check First."
        case .unknown:
            explanation = "You marked this as Not Sure."
        }

        return SafetyInfo(
            level: level,
            headline: friendlyHeadline,
            explanation: explanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }
}
