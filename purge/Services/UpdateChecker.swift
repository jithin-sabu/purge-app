import Combine
import Foundation

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(current: String)
    case updateAvailable(latest: String, url: URL)
    case failed
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var status: UpdateStatus = .idle

    private static let releasesAPIURL = URL(string: "https://api.github.com/repos/jithin-sabu/purge-app/releases/latest")!

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
    }

    func check() async {
        status = .checking

        let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        do {
            let (data, response) = try await fetchLatestRelease()
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                status = .failed
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = normalizeTag(release.tag_name)

            if compareVersions(installed, latest) >= 0 {
                status = .upToDate(current: installed)
            } else if let url = URL(string: release.html_url) {
                status = .updateAvailable(latest: latest, url: url)
            } else {
                status = .failed
            }
        } catch {
            status = .failed
        }
    }

    private func fetchLatestRelease() async throws -> (Data, URLResponse) {
        var request = URLRequest(url: Self.releasesAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        return try await URLSession.shared.data(for: request)
    }

    private func normalizeTag(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private func compareVersions(_ installed: String, _ latest: String) -> Int {
        let installedComponents = installed.split(separator: ".").map { Int($0) ?? 0 }
        let latestComponents = latest.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(installedComponents.count, latestComponents.count)

        for index in 0..<count {
            let installedValue = index < installedComponents.count ? installedComponents[index] : 0
            let latestValue = index < latestComponents.count ? latestComponents[index] : 0
            if installedValue < latestValue { return -1 }
            if installedValue > latestValue { return 1 }
        }
        return 0
    }
}
