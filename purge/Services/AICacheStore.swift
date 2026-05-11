import Foundation

struct AICacheEntry: Codable, Sendable {
    let displayName: String
    let tag: String
    let explanation: String
    let confidence: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case tag
        case explanation
        case confidence
    }
}

/// Persists AI explanation results in Application Support; keys are original folder names from disk.
enum AICacheStore {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var loadedEntries: [String: AICacheEntry]?
    nonisolated(unsafe) private static var canonicalKeysLower: [String: String] = [:]

    nonisolated private static func supportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("io.getpurge.app", isDirectory: true)
    }

    nonisolated private static func fileURL() -> URL {
        supportURL().appendingPathComponent("ai_cache.json", isDirectory: false)
    }

    nonisolated private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: supportURL(), withIntermediateDirectories: true)
    }

    nonisolated private static func readFromDisk() -> [String: AICacheEntry] {
        ensureDirectory()
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: AICacheEntry].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    nonisolated private static func refreshCacheLocked(_ entries: [String: AICacheEntry]) {
        loadedEntries = entries
        canonicalKeysLower = Dictionary(uniqueKeysWithValues: entries.keys.map { ($0.lowercased(), $0) })
    }

    nonisolated private static func loadEntriesLocked() -> [String: AICacheEntry] {
        if let loadedEntries { return loadedEntries }
        let disk = readFromDisk()
        refreshCacheLocked(disk)
        return disk
    }

    nonisolated static func read(folderName: String) -> AICacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        let entries = loadEntriesLocked()
        if let exact = entries[folderName] { return exact }
        if let canonical = canonicalKeysLower[folderName.lowercased()] {
            return entries[canonical]
        }
        return nil
    }

    nonisolated static func write(
        folderName: String,
        displayName: String,
        tag: String,
        explanation: String,
        confidence: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadEntriesLocked()
        entries[folderName] = AICacheEntry(
            displayName: displayName,
            tag: tag,
            explanation: explanation,
            confidence: confidence
        )
        ensureDirectory()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL(), options: [.atomic])
        }
        refreshCacheLocked(entries)
    }

    nonisolated static func remove(folderName: String) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadEntriesLocked()
        if entries.removeValue(forKey: folderName) == nil {
            if let canonical = canonicalKeysLower[folderName.lowercased()] {
                entries.removeValue(forKey: canonical)
            } else {
                return
            }
        }
        ensureDirectory()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL(), options: [.atomic])
        }
        refreshCacheLocked(entries)
    }

    nonisolated static func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        ensureDirectory()
        if let data = try? JSONEncoder().encode([String: AICacheEntry]()) {
            try? data.write(to: fileURL(), options: [.atomic])
        }
        refreshCacheLocked([:])
    }

    nonisolated static func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return loadEntriesLocked().count
    }

    /// Modification date of `ai_cache.json`, if the file exists on disk.
    nonisolated static func lastUpdated() -> Date? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        return attrs[.modificationDate] as? Date
    }

    nonisolated static func safetyInfo(from entry: AICacheEntry) -> SafetyInfo {
        let level: SafetyLevel
        switch entry.tag.lowercased() {
        case "safe": level = .safe
        case "medium": level = .medium
        case "danger": level = .danger
        case "unknown": level = .unknown
        default: level = .unknown
        }
        return SafetyInfo(
            level: level,
            headline: entry.displayName,
            explanation: entry.explanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }
}
