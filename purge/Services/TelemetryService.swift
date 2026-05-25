import Foundation

enum TelemetryConfig {
    static let airtableBaseID = "appB56sjEInyw0Pxq"
    static let airtableTableName = "Table 1"

    static let airtableAPIKey: String = {
        if let key = Bundle.main.infoDictionary?["AIRTABLE_API_KEY"] as? String,
           !key.isEmpty,
           key != "$(AIRTABLE_API_KEY)" {
            print("🔑 Using key from bundle")
            return key
        }
        if let envKey = ProcessInfo.processInfo.environment["AIRTABLE_API_KEY"],
           !envKey.isEmpty {
            print("🔑 Using AIRTABLE_API_KEY from process environment")
            return envKey
        }
        print("🔑 Bundle key empty or unexpanded; copy Secrets.xcconfig.template to Secrets.xcconfig and set AIRTABLE_API_KEY")
        return ""
    }()

    static let endpoint = "https://api.airtable.com/v0/\(airtableBaseID)/\(airtableTableName)"
}

struct TelemetryPayload: Encodable {
    let submissionDate: String
    let appVersion: String
    let macOSVersion: String
    let totalCount: Int
    /// Newline-separated `folderName<TAB>category` rows (`safe` or `medium` only).
    let folderCategories: String

    var folderCategoryRows: [TelemetryFolderCategoryRow] {
        Self.parseFolderCategories(folderCategories)
    }
}

struct TelemetryFolderCategoryRow: Identifiable, Hashable {
    let folderName: String
    let category: SafetyLevel

    var id: String { "\(folderName)\t\(category.rawValue)" }

    var categoryLabel: String { category.displayName }
}

extension TelemetryPayload {
    static func parseFolderCategories(_ text: String) -> [TelemetryFolderCategoryRow] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let category = SafetyLevel(rawValue: String(parts[1])) else { return nil }
                return TelemetryFolderCategoryRow(folderName: String(parts[0]), category: category)
            }
    }
}

enum TelemetryError: Error {
    case invalidEndpoint
    case sendFailed
}

enum TelemetryService {
    /// Only these levels are included in anonymous reports.
    private static let includedSafetyLevels: Set<SafetyLevel> = [.safe, .medium]

    private struct CacheTelemetryRow {
        let folderName: String
        let safetyLevel: SafetyLevel
    }

    private struct AirtableRecord: Encodable {
        let fields: TelemetryPayload
    }

    /// Telemetry is strictly opt-in. This service is only called from explicit user actions,
    /// never on app launch, after scans, or in the background.
    static func sendTelemetry(payload: TelemetryPayload) async throws {
        print("🔑 Airtable API key being used: '\(TelemetryConfig.airtableAPIKey)'")
        print("🔑 Key length: \(TelemetryConfig.airtableAPIKey.count)")
        print("🔑 Key starts with pat: \(TelemetryConfig.airtableAPIKey.hasPrefix("pat"))")

        guard !TelemetryConfig.airtableAPIKey.isEmpty else {
            print("Telemetry: No API key configured, skipping send")
            return
        }

        guard let url = URL(string: TelemetryConfig.endpoint) else {
            throw TelemetryError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(TelemetryConfig.airtableAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = AirtableRecord(fields: payload)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // DEBUG: print full response
        if let httpResponse = response as? HTTPURLResponse {
            print("Airtable status code: \(httpResponse.statusCode)")
        }
        if let responseString = String(data: data, encoding: .utf8) {
            print("Airtable response body: \(responseString)")
        }
        // Also print what we are sending
        if let bodyData = request.httpBody, let bodyString = String(data: bodyData, encoding: .utf8) {
            print("Airtable request body: \(bodyString)")
        }

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw TelemetryError.sendFailed
        }
    }

    @MainActor
    static func makePayload(from store: PurgeStore, submissionDate: Date = Date()) -> TelemetryPayload {
        let rows = cacheTelemetryRows(from: store)
        let folderCategories = rows
            .map { "\($0.folderName)\t\($0.safetyLevel.rawValue)" }
            .joined(separator: "\n")

        return TelemetryPayload(
            submissionDate: ISO8601DateFormatter().string(from: submissionDate),
            appVersion: appVersion,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            totalCount: rows.count,
            folderCategories: folderCategories
        )
    }

    @MainActor
    private static func cacheTelemetryRows(from store: PurgeStore) -> [CacheTelemetryRow] {
        store.cacheItems
            .filter { includedSafetyLevels.contains($0.safetyInfo.level) }
            .map { item in
                CacheTelemetryRow(
                    folderName: item.bundleID,
                    safetyLevel: item.safetyInfo.level
                )
            }
            .sorted {
                $0.folderName.localizedCaseInsensitiveCompare($1.folderName) == .orderedAscending
            }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)) where build != version:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        case let (_, .some(build)):
            return build
        default:
            return "1.0.0"
        }
    }
}
