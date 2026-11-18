import Foundation
import Testing
@testable import Purge

/// "Report a bug" and "Request a feature" open the repo's GitHub issue forms,
/// with the bug form's version fields filled in (#401).
@MainActor
@Suite("Feedback links open the GitHub issue forms")
struct FeedbackLinksTests {
    private func queryItems(_ url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    @Test
    func bugReportFillsBothVersionFields() {
        let url = FeedbackLinks.bugReport(appVersion: "1.16.2 (40)", systemVersion: "macOS 27.2.1, Apple silicon")

        #expect(url.absoluteString.hasPrefix("\(AboutView.repoBaseURL.absoluteString)/issues/new?"))
        #expect(url.scheme == "https")
        #expect(queryItems(url) == [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "purge-version", value: "1.16.2 (40)"),
            URLQueryItem(name: "macos-version", value: "macOS 27.2.1, Apple silicon"),
        ])
        // Spaces, commas and parentheses must not break the query.
        #expect(!url.absoluteString.contains(" "))
    }

    @Test
    func featureRequestOpensItsFormOnly() {
        let url = FeedbackLinks.featureRequest

        #expect(url.absoluteString.hasPrefix("\(AboutView.repoBaseURL.absoluteString)/issues/new?"))
        #expect(url.scheme == "https")
        #expect(queryItems(url) == [URLQueryItem(name: "template", value: "feature_request.yml")])
    }

    @Test
    func bugReportForThisMacIsFilledIn() {
        let items = queryItems(FeedbackLinks.bugReportForThisMac)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(values["purge-version"]?.isEmpty == false)
        #expect(values["macos-version"]?.hasPrefix("macOS ") == true)
    }

    @Test
    func appVersionShowsTheBuildOnlyWhenItDiffers() {
        #expect(FeedbackLinks.appVersion(info: ["CFBundleShortVersionString": "1.16.2", "CFBundleVersion": "40"]) == "1.16.2 (40)")
        #expect(FeedbackLinks.appVersion(info: ["CFBundleShortVersionString": "1.16.2", "CFBundleVersion": "1.16.2"]) == "1.16.2")
        #expect(FeedbackLinks.appVersion(info: ["CFBundleShortVersionString": "1.16.2"]) == "1.16.2")
        #expect(FeedbackLinks.appVersion(info: ["CFBundleShortVersionString": "", "CFBundleVersion": "40"]) == "40")
        #expect(FeedbackLinks.appVersion(info: nil) == "unknown")
    }

    @Test
    func systemDescriptionNamesVersionAndChip() {
        let withPatch = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)
        let noPatch = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)

        #expect(FeedbackLinks.systemDescription(os: withPatch, isAppleSilicon: true) == "macOS 27.2.1, Apple silicon")
        #expect(FeedbackLinks.systemDescription(os: noPatch, isAppleSilicon: false) == "macOS 26.1, Intel")
    }

    /// GitHub fills a form field only when the query name matches its `id`, so
    /// renaming a field in the form must fail here.
    @Test
    func queryNamesMatchTheBugFormFieldIDs() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let form = try String(
            contentsOf: repo.appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml"),
            encoding: .utf8
        )
        let ids = Set(form.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("id:") else { return nil }
            return trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        })

        #expect(ids.contains(FeedbackLinks.purgeVersionField))
        #expect(ids.contains(FeedbackLinks.macOSVersionField))
        #expect(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".github/ISSUE_TEMPLATE/feature_request.yml").path
        ))
    }
}
