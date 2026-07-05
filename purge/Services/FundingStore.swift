import Combine
import Foundation

struct FundingInfo: Codable {
    var raised: Double
    var contributorCount: Int
    var goal: Double
    var currency: String
    var paymentURL: String
    var signed: Bool

    init(
        raised: Double,
        contributorCount: Int,
        goal: Double,
        currency: String,
        paymentURL: String,
        signed: Bool
    ) {
        self.raised = raised
        self.contributorCount = contributorCount
        self.goal = goal
        self.currency = currency
        self.paymentURL = paymentURL
        self.signed = signed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        raised = try container.decode(Double.self, forKey: .raised)
        // Tolerate older payloads that predate the contributor count.
        contributorCount = try container.decodeIfPresent(Int.self, forKey: .contributorCount) ?? 0
        goal = try container.decode(Double.self, forKey: .goal)
        currency = try container.decode(String.self, forKey: .currency)
        paymentURL = try container.decode(String.self, forKey: .paymentURL)
        signed = try container.decode(Bool.self, forKey: .signed)
    }
}

@MainActor
final class FundingStore: ObservableObject {
    @Published private(set) var info: FundingInfo

    private static let remoteURL = URL(string: "https://raw.githubusercontent.com/jithin-sabu/purge-app/main/funding.json")!

    init() {
        if let url = Bundle.main.url(forResource: "funding", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundled = try? JSONDecoder().decode(FundingInfo.self, from: data) {
            info = bundled
        } else {
            info = FundingInfo(
                raised: 0,
                contributorCount: 0,
                goal: 99,
                currency: "USD",
                paymentURL: "",
                signed: false
            )
        }
    }

    var isComplete: Bool {
        info.signed || info.raised >= info.goal
    }

    var progress: Double {
        info.goal <= 0 ? 1 : min(max(info.raised / info.goal, 0), 1)
    }

    /// Fetches the latest funding info. Returns `true` only when a fresh payload
    /// was successfully fetched and decoded, so callers can react to the outcome.
    @discardableResult
    func refresh() async -> Bool {
        do {
            // Defeat GitHub's raw CDN cache so a freshly committed amount shows up:
            // a unique query item plus an ignore-cache policy forces a real fetch.
            var components = URLComponents(url: Self.remoteURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
            let url = components?.url ?? Self.remoteURL
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }
            info = try JSONDecoder().decode(FundingInfo.self, from: data)
            return true
        } catch {
            // Keep bundled value on any failure.
            return false
        }
    }
}
