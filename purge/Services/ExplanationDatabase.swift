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

/// Loads and matches against explicit entries in the local explanation database.
enum ExplanationDatabase {
    private nonisolated(unsafe) static var cachedRecords: [String: BundledExplanationRecord]?
    private nonisolated(unsafe) static var cachedBundleIndex: [String: BundledExplanationRecord]?

    private nonisolated static func loadFromBundle() -> [String: BundledExplanationRecord] {
        if let cachedRecords { return cachedRecords }
        guard let url = Bundle.main.url(forResource: "explanations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: BundledExplanationRecord].self, from: data)
        else {
            cachedRecords = [:]
            cachedBundleIndex = [:]
            return [:]
        }
        cachedRecords = decoded
        return decoded
    }

    private nonisolated static func bundleIdIndex() -> [String: BundledExplanationRecord] {
        if let cachedBundleIndex { return cachedBundleIndex }
        let dict = loadFromBundle()
        var index: [String: BundledExplanationRecord] = [:]
        for record in dict.values {
            guard let bundleIds = record.bundleIds else { continue }
            for id in bundleIds {
                index[id.lowercased()] = record
            }
        }
        cachedBundleIndex = index
        return index
    }

    /// Exact keys and explicit bundle IDs only. All matching is case-insensitive.
    nonisolated static func matchBundledDatabase(folderName: String) -> BundledExplanationRecord? {
        let lower = folderName.lowercased()
        let dict = loadFromBundle()

        func record(forKey keyLower: String) -> BundledExplanationRecord? {
            dict.first { $0.key.lowercased() == keyLower }?.value
        }

        if let record = record(forKey: lower) {
            return record
        }

        if let record = bundleIdIndex()[lower] {
            return record
        }

        return nil
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
