import Foundation

private struct OpenRouterChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct OpenRouterChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message?
    }
    let choices: [Choice]?
}

enum OpenRouterExplanationClient {
    private static let maxRateLimitRetries = 6
    private static let apiKeyAccount = "openrouter-api-key"
    private static let baseURL = "https://openrouter.ai/api/v1/chat/completions"

    private static func resolvedModel() -> String {
        if let value = ProcessInfo.processInfo.environment["OPENROUTER_MODEL"], !value.isEmpty {
            return value
        }
        return "openai/gpt-oss-120b:free"
    }

    /// OpenRouter keys are typically `sk-or-v1-...` or legacy `sk-or-...`.
    static func looksLikeAPIKey(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("sk-or-v1-") || t.hasPrefix("sk-or-")
    }

    static func fetchExplanation(folderName: String) async throws -> AIExplanationResult {
        do {
            let result = try await fetchExplanationWithRetries(folderName: folderName)
            await MainActor.run {
                AIUsageStore.shared.recordSuccess(folderName: folderName)
            }
            return result
        } catch {
            let message = Self.friendlyMessage(for: error)
            await MainActor.run {
                AIUsageStore.shared.recordFailure(folderName: folderName, error: message)
            }
            throw error
        }
    }

    /// Maps API and transport errors to short plain-English strings for settings/debug UI.
    static func friendlyMessage(for error: Error) -> String {
        if let open = error as? OpenRouterError {
            switch open {
            case .missingAPIKey:
                return "Something went wrong. Error: API key is missing"
            case .invalidURL:
                return "Something went wrong. Error: invalid URL"
            case .badStatus(let code):
                switch code {
                case -1:
                    return "Could not reach the AI service. Check your internet connection."
                case 401, 403:
                    return "Your API key was rejected. Double check it is correct."
                case 404:
                    return "The AI model could not be found. The key may be for a different service."
                case 429:
                    return "Too many requests. Try again in a few minutes."
                default:
                    return "Something went wrong. Error: HTTP \(code)"
                }
            case .rateLimited:
                return "Too many requests. Try again in a few minutes."
            case .emptyResponse:
                return "The AI returned an unexpected response. Try again."
            }
        }

        if error is DecodingError {
            return "The AI returned an unexpected response. Try again."
        }

        if error is AIExplanationSupport.AIExplanationParseError {
            return "The AI returned an unexpected response. Try again."
        }

        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "Could not reach the AI service. Check your internet connection."
        }

        return "Something went wrong. Error: \(error.localizedDescription)"
    }

    private static func fetchExplanationWithRetries(folderName: String) async throws -> AIExplanationResult {
        var backoffSeconds: Double = 1
        var lastRateLimitError: Error = OpenRouterError.rateLimited(retryAfter: nil)

        for _ in 0..<maxRateLimitRetries {
            do {
                return try await fetchExplanationOnce(folderName: folderName)
            } catch OpenRouterError.rateLimited(let serverHint) {
                lastRateLimitError = OpenRouterError.rateLimited(retryAfter: serverHint)
                let wait = min(max(serverHint ?? backoffSeconds, 0.5), 60)
                backoffSeconds = min(backoffSeconds * 2, 32)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            } catch {
                throw error
            }
        }
        throw lastRateLimitError
    }

    private static func fetchExplanationOnce(folderName: String) async throws -> AIExplanationResult {
        guard let apiKey = resolvedAPIKey() else {
            throw OpenRouterError.missingAPIKey
        }

        let prompt = AIExplanationSupport.prompt(forFolderName: folderName)
        let model = resolvedModel()

        guard let url = URL(string: baseURL) else {
            throw OpenRouterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let title = appTitleString() {
            request.setValue(title, forHTTPHeaderField: "X-Title")
        }

        let body = OpenRouterChatRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            temperature: 0.2
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.badStatus(code: -1)
        }
        if http.statusCode == 429 {
            let hint = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            throw OpenRouterError.rateLimited(retryAfter: hint)
        }
        guard (200...299).contains(http.statusCode) else {
            throw OpenRouterError.badStatus(code: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        guard let text = decoded.choices?.first?.message?.content else {
            throw OpenRouterError.emptyResponse
        }

        return try AIExplanationSupport.parseModelJSONText(text)
    }

    private static func resolvedAPIKey() -> String? {
        if let keychainKey = KeychainStore.read(key: apiKeyAccount) {
            return keychainKey
        }
        let environmentKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let environmentKey, !environmentKey.isEmpty else {
            return nil
        }
        return environmentKey
    }

    private static func appTitleString() -> String? {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let fallback = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let title = (name?.isEmpty == false ? name : nil) ?? fallback
        return title?.isEmpty == false ? title : "Purge"
    }

    enum OpenRouterError: Error {
        case missingAPIKey
        case invalidURL
        case badStatus(code: Int)
        case rateLimited(retryAfter: Double?)
        case emptyResponse
    }
}
