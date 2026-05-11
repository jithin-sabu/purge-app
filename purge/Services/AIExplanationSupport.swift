import Foundation

/// Parsed model output for cache-folder explanations (provider-agnostic).
struct AIExplanationResult: Sendable {
    let displayName: String
    let tag: String
    let explanation: String
    let confidence: String
}

private struct AIParsedPayload: Decodable {
    let displayName: String
    let tag: String
    let explanation: String
    let confidence: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case tag
        case explanation
        case confidence
    }
}

enum AIExplanationSupport {
    static func prompt(forFolderName folderName: String) -> String {
        """
        The following is a macOS cache folder name: "\(folderName)"

        You are a safety classifier for a Mac cleaning app.
        Categorize this folder for deletion safety.

        Rules:
        - Only tag as safe if you are certain it is auto regenerated
          with zero data loss
        - Tag as medium if deleting causes inconvenience but no
          permanent data loss
        - Tag as danger if deleting could cause permanent data loss
          or system problems
        - Tag as unknown if you are not confident

        When in doubt between two tags always choose the more
        cautious one. But do not be paranoid. Standard app caches
        that apps recreate automatically should be safe.

        Respond only with valid JSON, no markdown:
        {
        "display_name": "friendly name max 4 words",
        "tag": "safe" or "medium" or "danger" or "unknown",
        "explanation": "one or two plain English sentences for a non technical user",
        "confidence": "high" or "medium" or "low"
        }
        """
    }

    static func parseModelJSONText(_ text: String) throws -> AIExplanationResult {
        let trimmed = sanitizeJSONText(text)
        guard let payloadData = trimmed.data(using: .utf8) else {
            throw AIExplanationParseError.invalidJSON
        }
        let payload = try JSONDecoder().decode(AIParsedPayload.self, from: payloadData)
        let tagLower = payload.tag.lowercased()
        guard ["safe", "medium", "danger", "unknown"].contains(tagLower) else {
            throw AIExplanationParseError.invalidTag
        }
        let confidenceLower = payload.confidence.lowercased()
        guard ["high", "medium", "low"].contains(confidenceLower) else {
            throw AIExplanationParseError.invalidConfidence
        }
        return AIExplanationResult(
            displayName: payload.displayName,
            tag: tagLower,
            explanation: payload.explanation,
            confidence: confidenceLower
        )
    }

    static func sanitizeJSONText(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = String(t.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.lowercased().hasPrefix("json") {
                t = String(t.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let end = t.lastIndex(of: "`") {
                t = String(t[..<end])
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum AIExplanationParseError: Error {
        case invalidJSON
        case invalidTag
        case invalidConfidence
    }
}

nonisolated func applyBalancedDowngrade(tag: String, confidence: String) -> String {
    switch (tag.lowercased(), confidence.lowercased()) {
    // Low confidence safe becomes medium, not unknown
    case ("safe", "low"):
        return "medium"
    // Low confidence medium stays medium
    case ("medium", "low"):
        return "medium"
    // Low confidence danger stays danger
    case ("danger", "low"):
        return "danger"
    // Medium confidence safe stays safe
    // We trust medium confidence for safe calls
    case ("safe", "medium"):
        return "safe"
    // Everything else keeps its tag
    default:
        return tag.lowercased()
    }
}
