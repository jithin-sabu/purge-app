import Darwin
import Foundation

/// Where "Report a bug" and "Request a feature" go (#401). They once opened
/// `mailto:` links, which do nothing when no mail app handles them, such as
/// when Chrome is the default for `mailto:`. They now open the repo's GitHub
/// issue forms, and the email address stays on screen with a Copy button.
enum FeedbackLinks {
    static let emailAddress = "jithin@purgemac.com"

    /// Query names for the bug form's fields. GitHub issue forms take a
    /// field's value from the query parameter named after its `id` in
    /// `.github/ISSUE_TEMPLATE/bug_report.yml`.
    static let purgeVersionField = "purge-version"
    static let macOSVersionField = "macos-version"

    /// The bug report form with the Purge and macOS versions filled in.
    static func bugReport(appVersion: String, systemVersion: String) -> URL {
        issueForm(template: "bug_report.yml", fields: [
            URLQueryItem(name: purgeVersionField, value: appVersion),
            URLQueryItem(name: macOSVersionField, value: systemVersion),
        ])
    }

    /// The feature request form. It has no version fields.
    static var featureRequest: URL {
        issueForm(template: "feature_request.yml", fields: [])
    }

    /// The bug report form for this copy of Purge on this Mac.
    static var bugReportForThisMac: URL {
        bugReport(
            appVersion: appVersion(info: Bundle.main.infoDictionary),
            systemVersion: systemDescription(
                os: ProcessInfo.processInfo.operatingSystemVersion,
                isAppleSilicon: isAppleSilicon
            )
        )
    }

    private static func issueForm(template: String, fields: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "\(AboutView.repoBaseURL.absoluteString)/issues/new")!
        components.queryItems = [URLQueryItem(name: "template", value: template)] + fields
        return components.url!
    }

    /// "1.16.2", or "1.16.2 (40)" when the build number differs. Not
    /// localized, because it goes into a GitHub form.
    static func appVersion(info: [String: Any]?) -> String {
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let build = (info?["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch (version, build) {
        case let (.some(version), .some(build)) where build != version:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        case let (_, .some(build)):
            return build
        case (.none, .none):
            return "unknown"
        }
    }

    /// "macOS 27.2.1, Apple silicon" or "macOS 26.1, Intel". A zero patch
    /// number is left off, as macOS itself shows it.
    static func systemDescription(os: OperatingSystemVersion, isAppleSilicon: Bool) -> String {
        var name = "macOS \(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 { name += ".\(os.patchVersion)" }
        return "\(name), \(isAppleSilicon ? "Apple silicon" : "Intel")"
    }

    /// True on Apple silicon, also when Purge runs under Rosetta, where
    /// `uname` would say x86_64.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }
}
