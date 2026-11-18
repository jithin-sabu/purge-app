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
        let ids = Self.fieldIDs(inIssueForm: form)

        #expect(ids.contains(FeedbackLinks.purgeVersionField))
        #expect(ids.contains(FeedbackLinks.macOSVersionField))
        #expect(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent(".github/ISSUE_TEMPLATE/feature_request.yml").path
        ))
    }

    @Test
    func fieldIDReaderSkipsMarkdownTextAndQuotes() {
        let form = """
        name: Bug report
        body:
          - type: markdown
            attributes:
              value: |
                id: purge-version
                - type: input
                  id: crash-log
          - type: input
            id: "macos-version"
          - id: 'logs'
            type: textarea
          - type: checkboxes
            attributes:
              label: Extra
        """

        #expect(Self.fieldIDs(inIssueForm: form) == ["macos-version", "logs"])
    }

    /// The `id` of each field in an issue form's `body`, read the way YAML
    /// reads it. Only a key of a `body` item counts, in any order, so text
    /// inside a markdown block never does, even when it looks like an item.
    /// Quotes around the value are dropped. Foundation has no YAML parser, and
    /// the forms only use this plain block style.
    static func fieldIDs(inIssueForm form: String) -> Set<String> {
        var ids: Set<String> = []
        var inBody = false
        var dashIndent: Int?
        var item: [String: String] = [:]

        func finishItem() {
            if let id = item["id"], item["type"] != "markdown" { ids.insert(id) }
            item = [:]
        }
        func readKey(_ text: Substring) {
            guard let colon = text.firstIndex(of: ":") else { return }
            let key = text[..<colon].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if item[key] == nil { item[key] = value }
        }

        for line in form.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.drop { $0 == " " }
            if trimmed.isEmpty { continue }
            if indent == 0 {
                // A top-level key ends the body list.
                if inBody { finishItem() }
                inBody = trimmed.hasPrefix("body:")
                dashIndent = nil
                continue
            }
            guard inBody else { continue }
            if dashIndent == nil, trimmed.hasPrefix("- ") { dashIndent = indent }
            guard let dashIndent else { continue }
            if indent == dashIndent, trimmed.hasPrefix("- ") {
                finishItem()
                readKey(trimmed.dropFirst(2))
            } else if indent == dashIndent + 2 {
                readKey(trimmed)
            }
        }
        if inBody { finishItem() }
        return ids
    }
}
