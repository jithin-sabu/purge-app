import Foundation

struct ExcludedPathEntry: Codable, Sendable {
    let path: String
    let displayName: String
    let dateAdded: Date

    enum CodingKeys: String, CodingKey {
        case path
        case displayName
        case dateAdded
    }
}

/// Persists user-chosen scan exclusions keyed by exact filesystem path.
/// An exclusion only ever removes a path the allowlist already approved: the
/// scanner drops excluded paths *after* `DeletionSafetyPolicy.isOfferedForCleanup`,
/// so un-excluding a path still requires it to pass the normal allowlist gate.
enum ExcludedPathsStore {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var loadedEntries: [String: ExcludedPathEntry]?

    nonisolated private static func supportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("io.getpurge.app", isDirectory: true)
    }

    nonisolated static func fileURL() -> URL {
        supportURL().appendingPathComponent("excluded_paths.json", isDirectory: false)
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

    nonisolated private static func readFromDisk() -> [String: ExcludedPathEntry] {
        ensureDirectory()
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? makeDecoder().decode([String: ExcludedPathEntry].self, from: data)
        else {
            return [:]
        }
        // Entries persisted before keys resolved symlinks are re-keyed on load, so an
        // existing exclusion keeps matching instead of silently going stale.
        return decoded.reduce(into: [String: ExcludedPathEntry]()) { result, pair in
            let key = canonicalKey(forPath: URL(fileURLWithPath: pair.value.path))
            result[key] = ExcludedPathEntry(
                path: key,
                displayName: pair.value.displayName,
                dateAdded: pair.value.dateAdded
            )
        }
    }

    nonisolated private static func loadEntriesLocked() -> [String: ExcludedPathEntry] {
        if let loadedEntries { return loadedEntries }
        let disk = readFromDisk()
        loadedEntries = disk
        return disk
    }

    nonisolated private static func persistLocked(_ entries: [String: ExcludedPathEntry]) {
        ensureDirectory()
        if let data = try? makeEncoder().encode(entries) {
            try? data.write(to: fileURL(), options: [.atomic])
        }
        loadedEntries = entries
    }

    /// Resolves symlinks so a path reached through different chains (`/tmp/x` vs
    /// `/private/tmp/x`, or a symlinked project root) yields one key. Every read and
    /// write routes through here, including entries loaded from disk, so the ancestor
    /// prefix match in `isExcluded` never compares a resolved path to an unresolved key.
    nonisolated private static func canonicalKey(forPath url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func contains(path: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadEntriesLocked()[canonicalKey(forPath: path)] != nil
    }

    /// True when `url` is an excluded path or any descendant (component-wise prefix
    /// match). Exclusions only subtract from allowlist-approved candidates.
    nonisolated static func isExcluded(_ url: URL) -> Bool {
        lock.lock()
        let keys = Set(loadEntriesLocked().keys)
        lock.unlock()
        guard !keys.isEmpty else { return false }

        let path = canonicalKey(forPath: url)
        if keys.contains(path) { return true }
        return keys.contains { key in
            key != path && path.hasPrefix(key.hasSuffix("/") ? key : key + "/")
        }
    }

    nonisolated static func write(
        path: URL,
        displayName: String,
        date: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadEntriesLocked()
        let key = canonicalKey(forPath: path)
        entries[key] = ExcludedPathEntry(
            path: key,
            displayName: displayName,
            dateAdded: date
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

    nonisolated static func allExcludedPaths() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(loadEntriesLocked().keys)
    }

    nonisolated static func allEntries() -> [ExcludedPathEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadEntriesLocked().values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    nonisolated static func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return loadEntriesLocked().count
    }

    /// Modification date of `excluded_paths.json`, if the file exists on disk.
    nonisolated static func lastUpdated() -> Date? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        return attrs[.modificationDate] as? Date
    }
}
