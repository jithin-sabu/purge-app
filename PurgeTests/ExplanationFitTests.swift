import AppKit
import SwiftUI
import Testing
@testable import Purge

/// A scan row shows its explanation in two lines and cuts the rest off with no way
/// to read it. Every explanation in `explanations.json`, and its translation in each
/// language the app ships, must fit in two lines of the real column.
///
/// The window is a fixed 980 pt wide. The explanation column and the trailing
/// column (size above the safety badge) share 550 pt: a probe of the App Caches
/// list measured 464 pt next to an 86 pt "Safe to Clean" column. The badge's width
/// depends on the level and the language, so the column is worked out for each.
/// The test keeps 6 pt in hand so a small change in text layout between macOS
/// versions does not push a line over.
@MainActor
@Suite("Explanations fit in two lines")
struct ExplanationFitTests {
    static let sharedWidth: CGFloat = 550
    static let margin: CGFloat = 6
    static let languages = ["en", "zh-Hans", "ru", "tr"]

    private struct Entry: Decodable {
        let key: String
        let tag: String
        let explanation: String
    }

    static func bundle(for language: String) throws -> Bundle {
        if language == "en" { return .main }
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    static func level(_ tag: String) -> SafetyLevel {
        switch tag {
        case "safe": .safe
        case "medium": .medium
        default: .unknown
        }
    }

    static func badgeLabel(_ level: SafetyLevel, in bundle: Bundle) -> String {
        let english: String
        switch level {
        case .safe: english = "Safe to Clean"
        case .medium: english = "Check First"
        case .unknown: english = "Not Sure"
        }
        return bundle.localizedString(forKey: english, value: english, table: nil)
    }

    static func fittingSize<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    /// The trailing column is as wide as its widest line: the size or the badge.
    static func trailingWidth(_ level: SafetyLevel, in bundle: Bundle) -> CGFloat {
        let badge = fittingSize(AppBadge(text: badgeLabel(level, in: bundle))).width
        let size = fittingSize(
            Text(verbatim: "999.9 MB")
                .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                .monospacedDigit()
        ).width
        return max(badge, size)
    }

    static func columnWidth(_ level: SafetyLevel, in bundle: Bundle) -> CGFloat {
        sharedWidth - trailingWidth(level, in: bundle) - margin
    }

    static func lineCount(_ text: String, width: CGFloat) -> Int {
        func height(_ string: String) -> CGFloat {
            fittingSize(
                Text(verbatim: string)
                    .font(AppStyle.Typography.metadata)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, alignment: .leading)
            ).height
        }
        return Int((height(text) / height("Ag")).rounded())
    }

    @Test(arguments: languages)
    func everyBundledExplanationFitsInTwoLines(language: String) throws {
        let url = try #require(Bundle.main.url(forResource: "explanations", withExtension: "json"))
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        let bundle = try Self.bundle(for: language)
        var widths: [SafetyLevel: CGFloat] = [:]
        var tooLong: [String] = []
        for entry in entries {
            let level = Self.level(entry.tag)
            let width = widths[level] ?? Self.columnWidth(level, in: bundle)
            widths[level] = width
            let text = bundle.localizedString(forKey: entry.explanation, value: entry.explanation, table: "Explanations")
            let lines = Self.lineCount(text, width: width)
            if lines > 2 {
                tooLong.append("\(entry.key) (\(lines) lines at \(Int(width)) pt): \(text)")
            }
        }
        #expect(tooLong.isEmpty, "\(tooLong.count) explanations need more than two lines:\n\(tooLong.joined(separator: "\n"))")
    }

    /// Dev Tools builds these in code. Runtime and Xcode component rows have two
    /// lines; simulator device rows have one. Checked at their longest: a large
    /// size, the longest reach prefix and a usage sentence with a count.
    @Test func devToolsExplanationsFitTheirRows() throws {
        let width = Self.columnWidth(.medium, in: .main)
        let now = Date()
        let elevenMonthsAgo = try #require(Calendar.current.date(byAdding: .month, value: -11, to: now))
        let twoLines: [String] = [
            XcodeComponent.safetyInfo(kind: .metalToolchain, sizeBytes: 1_023_900_000).explanation,
            SimulatorRuntime.safetyInfo(
                platformName: "visionOS", version: "26.2", state: "Ready", sizeBytes: 8_120_000_000,
                lastUsedAt: elevenMonthsAgo, deviceCount: 0, isXcodeDefault: false,
                deviceReach: .only(["iPhone", "iPad", "Apple Vision"]), now: now
            ).explanation,
            SimulatorRuntime.safetyInfo(
                platformName: "visionOS", version: "26.2", state: "Ready", sizeBytes: 8_120_000_000,
                lastUsedAt: elevenMonthsAgo, deviceCount: 0, isXcodeDefault: false,
                deviceReach: .onlyGeneralRuntime, now: now
            ).explanation,
        ]
        for text in twoLines {
            #expect(Self.lineCount(text, width: width) <= 2, "\(text)")
        }
        let oneLine: [String] = [
            SimulatorDevice.runningSafetyInfo(deviceName: "iPhone 17 Pro", runtimeVersion: "26.2", isBooted: true).explanation,
            SimulatorDevice.runningSafetyInfo(deviceName: "iPhone 17 Pro", runtimeVersion: "26.2", isBooted: false).explanation,
            SimulatorDevice.safetyInfo(isAvailable: false, lastBootedAt: nil, deviceName: "iPhone", runtimeVersion: "26.2").explanation,
            SimulatorDevice.safetyInfo(isAvailable: true, lastBootedAt: elevenMonthsAgo, deviceName: "iPhone", runtimeVersion: "26.2").explanation,
        ]
        for text in oneLine {
            #expect(Self.lineCount(text, width: width) == 1, "\(text)")
        }
    }
}
