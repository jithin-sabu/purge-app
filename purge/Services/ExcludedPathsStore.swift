import Foundation

nonisolated struct ExcludedPathEntry: Codable, Sendable {
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
    // Entries persisted before keys resolved symlinks are re-keyed on load, so an
    // existing exclusion keeps matching instead of silently going stale.
    nonisolated private static let store = JSONPathStore<ExcludedPathEntry>(fileName: "excluded_paths.json") { decoded in
        decoded.reduce(into: [String: ExcludedPathEntry]()) { result, pair in
            let key = canonicalKey(forPath: URL(fileURLWithPath: pair.value.path))
            result[key] = ExcludedPathEntry(
                path: key,
                displayName: pair.value.displayName,
                dateAdded: pair.value.dateAdded
            )
        }
    }

    nonisolated static func fileURL() -> URL {
        store.fileURL
    }

    /// Resolves symlinks so a path reached through different chains (`/tmp/x` vs
    /// `/private/tmp/x`, or a symlinked project root) yields one key. Every read and
    /// write routes through here, including entries loaded from disk, so the ancestor
    /// prefix match in `isExcluded` never compares a resolved path to an unresolved key.
    nonisolated private static func canonicalKey(forPath url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func contains(path: URL) -> Bool {
        store.read { $0[canonicalKey(forPath: path)] != nil }
    }

    /// True when `url` is an excluded path or any descendant (component-wise prefix
    /// match). Exclusions only subtract from allowlist-approved candidates.
    nonisolated static func isExcluded(_ url: URL) -> Bool {
        let keys = store.read { Set($0.keys) }
        guard !keys.isEmpty else { return false }

        let path = canonicalKey(forPath: url)
        if keys.contains(path) { return true }
        return keys.contains { PathContainment.isInside(path, $0) }
    }

    /// Returns false when the list could not be saved. The exclusion still holds
    /// until Purge quits.
    @discardableResult
    nonisolated static func write(
        path: URL,
        displayName: String,
        date: Date = Date()
    ) -> Bool {
        let key = canonicalKey(forPath: path)
        return store.update { entries in
            entries[key] = ExcludedPathEntry(
                path: key,
                displayName: displayName,
                dateAdded: date
            )
            return true
        }
    }

    /// Returns false when the list could not be saved.
    @discardableResult
    nonisolated static func remove(path: URL) -> Bool {
        let key = canonicalKey(forPath: path)
        return store.update { $0.removeValue(forKey: key) != nil }
    }

    nonisolated static func allExcludedPaths() -> Set<String> {
        store.read { Set($0.keys) }
    }

    nonisolated static func allEntries() -> [ExcludedPathEntry] {
        store.read { entries in
            entries.values.sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    nonisolated static func count() -> Int {
        store.read(\.count)
    }

    /// Modification date of `excluded_paths.json`, if the file exists on disk.
    nonisolated static func lastUpdated() -> Date? {
        store.lastUpdated
    }
}
