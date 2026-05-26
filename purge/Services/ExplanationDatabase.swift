import Foundation

/// Record from bundled `explanations.json`.
struct BundledExplanationRecord: Codable, Sendable {
    let displayName: String
    let tag: String
    let explanation: String
    let bundleIds: [String]?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case tag
        case explanation
        case bundleIds = "bundle_ids"
    }

    nonisolated var safetyLevel: SafetyLevel {
        switch tag.lowercased() {
        case "safe": return .safe
        case "medium": return .medium
        case "danger": return .danger
        case "unknown": return .unknown
        default: return .unknown
        }
    }
}

/// Intermediate type for decoding the JSON array format used by `explanations.json`.
private struct BundledArrayEntry: Codable {
    let key: String
    let displayName: String
    let tag: String
    let explanation: String
    let bundleIds: [String]?
    let aliases: [String]?

    enum CodingKeys: String, CodingKey {
        case key
        case displayName = "display_name"
        case tag
        case explanation
        case bundleIds = "bundle_ids"
        case aliases
    }

    var record: BundledExplanationRecord {
        BundledExplanationRecord(
            displayName: displayName,
            tag: tag,
            explanation: explanation,
            bundleIds: bundleIds
        )
    }
}

/// Loads and matches against explicit entries in the local explanation database.
enum ExplanationDatabase {
    private nonisolated(unsafe) static var cachedRecords: [String: BundledExplanationRecord]?
    private nonisolated(unsafe) static var cachedBundleIndex: [String: BundledExplanationRecord]?
    private nonisolated(unsafe) static var cachedAliasIndex: [String: BundledExplanationRecord]?
    private nonisolated(unsafe) static var cachedAliasKeyIndex: [String: String]?
    private nonisolated(unsafe) static var cachedBundleKeyIndex: [String: String]?
    private nonisolated(unsafe) static var cachedBundleIDsByKey: [String: [String]]?
    private nonisolated(unsafe) static var cachedAliasesByKey: [String: [String]]?

    private nonisolated static func loadFromBundle() -> [String: BundledExplanationRecord] {
        if let cachedRecords { return cachedRecords }
        guard let url = Bundle.main.url(forResource: "explanations", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            cachedRecords = [:]
            cachedBundleIndex = [:]
            cachedAliasIndex = [:]
            return [:]
        }

        if let array = try? JSONDecoder().decode([BundledArrayEntry].self, from: data) {
            var dict: [String: BundledExplanationRecord] = [:]
            var aliasIndex: [String: BundledExplanationRecord] = [:]
            var aliasKeyIndex: [String: String] = [:]
            var bundleIDsByKey: [String: [String]] = [:]
            var aliasesByKey: [String: [String]] = [:]
            for entry in array {
                let rec = entry.record
                dict[entry.key] = rec
                if let bundleIds = entry.bundleIds, !bundleIds.isEmpty {
                    bundleIDsByKey[entry.key] = bundleIds
                }
                if let aliases = entry.aliases, !aliases.isEmpty {
                    aliasesByKey[entry.key] = aliases
                }
                if let aliases = entry.aliases {
                    for alias in aliases {
                        aliasIndex[alias.lowercased()] = rec
                        aliasKeyIndex[alias.lowercased()] = entry.key
                    }
                }
            }
            cachedRecords = dict
            cachedAliasIndex = aliasIndex
            cachedAliasKeyIndex = aliasKeyIndex
            cachedBundleIDsByKey = bundleIDsByKey
            cachedAliasesByKey = aliasesByKey
            return dict
        }

        if let decoded = try? JSONDecoder().decode([String: BundledExplanationRecord].self, from: data) {
            cachedRecords = decoded
            cachedAliasIndex = [:]
            return decoded
        }

        cachedRecords = [:]
        cachedBundleIndex = [:]
        cachedAliasIndex = [:]
        return [:]
    }

    private nonisolated static func aliasIndex() -> [String: BundledExplanationRecord] {
        if let cachedAliasIndex { return cachedAliasIndex }
        _ = loadFromBundle()
        return cachedAliasIndex ?? [:]
    }

    private nonisolated static func bundleIdIndex() -> [String: BundledExplanationRecord] {
        if let cachedBundleIndex { return cachedBundleIndex }
        let dict = loadFromBundle()
        var index: [String: BundledExplanationRecord] = [:]
        var keyIndex: [String: String] = [:]
        for (key, record) in dict {
            guard let bundleIds = record.bundleIds else { continue }
            for id in bundleIds {
                index[id.lowercased()] = record
                keyIndex[id.lowercased()] = key
            }
        }
        cachedBundleIndex = index
        cachedBundleKeyIndex = keyIndex
        return index
    }

    private nonisolated static func bundleKeyIndex() -> [String: String] {
        if let cachedBundleKeyIndex { return cachedBundleKeyIndex }
        _ = bundleIdIndex()
        return cachedBundleKeyIndex ?? [:]
    }

    private nonisolated static func aliasKeyIndex() -> [String: String] {
        if let cachedAliasKeyIndex { return cachedAliasKeyIndex }
        _ = loadFromBundle()
        return cachedAliasKeyIndex ?? [:]
    }

    private nonisolated static func bundleIDsByKeyIndex() -> [String: [String]] {
        if let cachedBundleIDsByKey { return cachedBundleIDsByKey }
        _ = loadFromBundle()
        return cachedBundleIDsByKey ?? [:]
    }

    /// Keys, aliases, and bundle IDs. All matching is case-insensitive.
    nonisolated static func matchBundledDatabase(folderName: String) -> BundledExplanationRecord? {
        let lower = folderName.lowercased()
        let dict = loadFromBundle()

        if let record = dict.first(where: { $0.key.lowercased() == lower })?.value {
            return record
        }

        if let record = aliasIndex()[lower] {
            return record
        }

        if let record = bundleIdIndex()[lower] {
            return record
        }

        return nil
    }

    /// Canonical `explanations.json` key for a folder name, alias, or bundle ID (case-insensitive).
    nonisolated static func definitionKey(forFolderName folderName: String) -> String? {
        let lower = folderName.lowercased()
        let dict = loadFromBundle()

        if let key = dict.keys.first(where: { $0.lowercased() == lower }) {
            return key
        }
        if let key = aliasKeyIndex()[lower] {
            return key
        }
        if let key = bundleKeyIndex()[lower] {
            return key
        }
        return nil
    }

    /// All bundle IDs declared under a definition key.
    nonisolated static func allBundleIDs(forKey key: String) -> [String] {
        bundleIDsByKeyIndex()[key] ?? []
    }

    /// Bundle IDs plus alias strings that look like bundle identifiers (for container cache probing).
    nonisolated static func containerProbeBundleIDs(forKey key: String) -> [String] {
        var ids = Set(allBundleIDs(forKey: key))
        for alias in aliasesByKeyIndex()[key] ?? [] where alias.contains(".") {
            ids.insert(alias)
        }
        return Array(ids)
    }

    private nonisolated static func aliasesByKeyIndex() -> [String: [String]] {
        if let cachedAliasesByKey { return cachedAliasesByKey }
        _ = loadFromBundle()
        return cachedAliasesByKey ?? [:]
    }

    /// Sandbox app container cache folder when present.
    nonisolated static func containerCacheURL(forBundleID bundleID: String, home: URL) -> URL? {
        let url = home
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Caches", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    nonisolated static func record(forKey key: String) -> BundledExplanationRecord? {
        loadFromBundle()[key]
    }

    nonisolated static func safetyInfo(from record: BundledExplanationRecord, reinstallCommand: String? = nil) -> SafetyInfo {
        SafetyInfo(
            level: record.safetyLevel,
            headline: record.displayName,
            explanation: record.explanation,
            recoverySteps: "",
            reinstallCommand: reinstallCommand
        )
    }

    /// Unknown bundled keys: conservative copy for dev-tool-only local path.
    nonisolated static let unsureExplanation = "We are not sure what this is. We recommend leaving it alone."

    nonisolated static func safetyInfoForUnknownBundledLookup(friendlyFallback: String) -> SafetyInfo {
        SafetyInfo(
            level: .unknown,
            headline: friendlyFallback,
            explanation: unsureExplanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }
}
