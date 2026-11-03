import Foundation

nonisolated struct UserOverrideEntry: Codable, Sendable {
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
    nonisolated private static let store = JSONPathStore<UserOverrideEntry>(fileName: "user_overrides.json")

    nonisolated static func fileURL() -> URL {
        store.fileURL
    }

    nonisolated private static func canonicalKey(forPath url: URL) -> String {
        url.standardizedFileURL.path
    }

    nonisolated static func read(path: URL) -> UserOverrideEntry? {
        store.read { $0[canonicalKey(forPath: path)] }
    }

    /// Returns false when the change could not be saved.
    @discardableResult
    nonisolated static func remove(path: URL) -> Bool {
        let key = canonicalKey(forPath: path)
        return store.update { $0.removeValue(forKey: key) != nil }
    }

    nonisolated static func allOverriddenPaths() -> Set<String> {
        store.read { Set($0.keys) }
    }

    nonisolated static func count() -> Int {
        store.read(\.count)
    }

    /// Modification date of `user_overrides.json`, if the file exists on disk.
    nonisolated static func lastUpdated() -> Date? {
        store.lastUpdated
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
            explanation = String(localized: "You marked this as Safe to Clean.")
        case .medium:
            explanation = String(localized: "You marked this as Check First.")
        case .unknown:
            explanation = String(localized: "You marked this as Not Sure.")
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
