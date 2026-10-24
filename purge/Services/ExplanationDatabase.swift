import Foundation

/// Record from bundled `explanations.json`.
struct BundledExplanationRecord: Codable, Sendable {
    let displayName: String
    let tag: String
    let explanation: String
    let bundleIds: [String]?
    /// Raw `kind` value; see `CacheKind`.
    let kind: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case tag
        case explanation
        case bundleIds = "bundle_ids"
        case kind
    }

    nonisolated var cacheKind: CacheKind? {
        kind.flatMap(CacheKind.init(rawValue:))
    }

    nonisolated var safetyLevel: SafetyLevel {
        switch tag.lowercased() {
        case "safe": return .safe
        case "medium": return .medium
        // Legacy "danger" tag: the "Do Not Delete" tier no longer exists.
        // Treat it as unclassified so it is dropped at the assembly boundary
        // rather than surfacing.
        case "danger": return .unknown
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
    let kind: String?

    enum CodingKeys: String, CodingKey {
        case key
        case displayName = "display_name"
        case tag
        case explanation
        case bundleIds = "bundle_ids"
        case aliases
        case kind
    }

    var record: BundledExplanationRecord {
        BundledExplanationRecord(
            displayName: displayName,
            tag: tag,
            explanation: explanation,
            bundleIds: bundleIds,
            kind: kind
        )
    }
}

/// Loads and matches against explicit entries in the local explanation database.
enum ExplanationDatabase {
    /// Every lookup table, built once from `explanations.json`. A `static let` is
    /// initialised exactly once even when the scanners reach it from several
    /// threads at the same time, which the lazily filled `static var`s it replaced
    /// were not (#190). Keys of the case-insensitive tables are lowercased.
    private nonisolated struct Index: Sendable {
        var records: [String: BundledExplanationRecord] = [:]
        var keyByLowercasedKey: [String: String] = [:]
        var recordByAlias: [String: BundledExplanationRecord] = [:]
        var keyByAlias: [String: String] = [:]
        var recordByBundleID: [String: BundledExplanationRecord] = [:]
        var keyByBundleID: [String: String] = [:]
        var bundleIDsByKey: [String: [String]] = [:]
    }

    private nonisolated static let index: Index = loadIndex()

    private nonisolated static func loadIndex() -> Index {
        guard let url = Bundle.main.url(forResource: "explanations", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return Index() }

        var index = Index()
        if let array = try? JSONDecoder().decode([BundledArrayEntry].self, from: data) {
            for entry in array {
                let rec = entry.record
                index.records[entry.key] = rec
                if let bundleIds = entry.bundleIds, !bundleIds.isEmpty {
                    index.bundleIDsByKey[entry.key] = bundleIds
                }
                // A later entry wins an alias two entries share, as it always has.
                for alias in entry.aliases ?? [] {
                    index.recordByAlias[alias.lowercased()] = rec
                    index.keyByAlias[alias.lowercased()] = entry.key
                }
            }
        } else if let decoded = try? JSONDecoder().decode([String: BundledExplanationRecord].self, from: data) {
            index.records = decoded
        } else {
            return Index()
        }

        for (key, record) in index.records {
            index.keyByLowercasedKey[key.lowercased()] = key
            for id in record.bundleIds ?? [] {
                index.recordByBundleID[id.lowercased()] = record
                index.keyByBundleID[id.lowercased()] = key
            }
        }
        return index
    }

    /// Keys, aliases, and bundle IDs. All matching is case-insensitive.
    nonisolated static func matchBundledDatabase(folderName: String) -> BundledExplanationRecord? {
        let lower = folderName.lowercased()
        if let key = index.keyByLowercasedKey[lower], let record = index.records[key] {
            return record
        }
        return index.recordByAlias[lower] ?? index.recordByBundleID[lower]
    }

    /// Canonical `explanations.json` key for a folder name, alias, or bundle ID (case-insensitive).
    nonisolated static func definitionKey(forFolderName folderName: String) -> String? {
        let lower = folderName.lowercased()
        return index.keyByLowercasedKey[lower] ?? index.keyByAlias[lower] ?? index.keyByBundleID[lower]
    }

    /// All bundle IDs declared under a definition key.
    nonisolated static func allBundleIDs(forKey key: String) -> [String] {
        index.bundleIDsByKey[key] ?? []
    }

    nonisolated static func record(forKey key: String) -> BundledExplanationRecord? {
        index.records[key]
    }

    /// The `kind` of a definition, which picks the row symbol when the cache
    /// has no brand glyph.
    nonisolated static func kind(forKey key: String) -> CacheKind? {
        record(forKey: key)?.cacheKind
    }

    nonisolated static func safetyInfo(from record: BundledExplanationRecord, reinstallCommand: String? = nil) -> SafetyInfo {
        SafetyInfo(
            level: record.safetyLevel,
            headline: Bundle.main.localizedString(forKey: record.displayName, value: record.displayName, table: "Explanations"),
            explanation: Bundle.main.localizedString(forKey: record.explanation, value: record.explanation, table: "Explanations"),
            recoverySteps: "",
            reinstallCommand: reinstallCommand
        )
    }

    /// Unknown bundled keys: conservative copy for dev-tool-only local path.
    nonisolated static let unsureExplanation = String(localized: "We are not sure what this is. We recommend leaving it alone.")

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
