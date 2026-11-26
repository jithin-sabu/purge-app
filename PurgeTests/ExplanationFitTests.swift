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
    static let languages = ["en", "zh-Hans", "ru", "tr", "ar"]

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

    /// The test host runs in English, so each style is set in the font
    /// `language` gets in the app, not the host's.
    static func styled(_ text: String, _ style: AppStyle.TextStyle, in language: String) -> Text {
        Text(verbatim: text).font(style.font(for: language)).tracking(style.tracking)
    }

    /// The trailing column is as wide as its widest line: the size or the badge.
    /// The badge is measured as `AppBadge` lays it out.
    static func trailingWidth(_ level: SafetyLevel, in bundle: Bundle, language: String) -> CGFloat {
        let badge = fittingSize(
            styled(badgeLabel(level, in: bundle), AppStyle.Typography.metadataEmphasis, in: language)
                .padding(.horizontal, AppStyle.Spacing.xxSmallPlus)
                .padding(.vertical, AppStyle.Spacing.xxxSmall)
        ).width
        let size = fittingSize(
            Text(verbatim: "999.9 MB")
                .font(AppStyle.Typography.metadata.weight(.medium).numbers)
                .monospacedDigit()
        ).width
        return max(badge, size)
    }

    static func columnWidth(_ level: SafetyLevel, in bundle: Bundle, language: String) -> CGFloat {
        sharedWidth - trailingWidth(level, in: bundle, language: language) - margin
    }

    static func lineCount(_ text: String, width: CGFloat, language: String) -> Int {
        func height(_ string: String) -> CGFloat {
            fittingSize(
                styled(string, AppStyle.Typography.metadata, in: language)
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
            let width = widths[level] ?? Self.columnWidth(level, in: bundle, language: language)
            widths[level] = width
            let text = bundle.localizedString(forKey: entry.explanation, value: entry.explanation, table: "Explanations")
            let lines = Self.lineCount(text, width: width, language: language)
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
        let width = Self.columnWidth(.medium, in: .main, language: "en")
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
            #expect(Self.lineCount(text, width: width, language: "en") <= 2, "\(text)")
        }
        let oneLine: [String] = [
            SimulatorDevice.runningSafetyInfo(deviceName: "iPhone 17 Pro", runtimeVersion: "26.2", isBooted: true).explanation,
            SimulatorDevice.runningSafetyInfo(deviceName: "iPhone 17 Pro", runtimeVersion: "26.2", isBooted: false).explanation,
            SimulatorDevice.safetyInfo(isAvailable: false, lastBootedAt: nil, deviceName: "iPhone", runtimeVersion: "26.2").explanation,
            SimulatorDevice.safetyInfo(isAvailable: true, lastBootedAt: elevenMonthsAgo, deviceName: "iPhone", runtimeVersion: "26.2").explanation,
        ]
        for text in oneLine {
            #expect(Self.lineCount(text, width: width, language: "en") == 1, "\(text)")
        }
    }

    /// The test host runs in English, so the code above only ever builds English.
    /// This builds the same Dev Tools sentences from each language's own tables,
    /// plural rules included, the way `String(localized:)` does in that language:
    /// every runtime usage sentence with and without each reach prefix, Metal
    /// Toolchain, and the one-line simulator device sentences.
    @Test(arguments: languages)
    func devToolsExplanationsFitTheirRowsInEveryLanguage(language: String) throws {
        let bundle = try Self.bundle(for: language)
        let locale = Locale(identifier: language)
        func text(_ key: String, _ arguments: CVarArg...) -> String {
            String(format: bundle.localizedString(forKey: key, value: key, table: nil), locale: locale, arguments: arguments)
        }
        let width = Self.columnWidth(.medium, in: bundle, language: language)
        let lists = ListFormatter()
        lists.locale = locale
        let devices = lists.string(from: ["iPhone", "iPad", "Apple Vision"]) ?? ""
        let cost = text("Xcode downloads it again (%@) if a simulator needs it.", "8.12 GB")
        // Proves the language's own table is read, not the English key.
        if language != "en" {
            #expect(cost != "Xcode downloads it again (8.12 GB) if a simulator needs it.")
        }
        let bases = [
            text("Xcode can no longer use this runtime. %@", cost),
            text("Xcode lists it as %@. %@", "unmounting", cost),
            text("Could not check if Xcode uses it for new simulators. %@", cost),
            text("Xcode creates new simulators on this runtime. %@", cost),
            text("Could not check which simulators use it. %@", cost),
            text("1 simulator uses it. %@", cost),
            text("%lld simulators use it. %@", 11, cost),
            text("No simulator uses it. Last use unknown. %@", cost),
            text("No simulator uses it, but it was used in the last month. %@", cost),
            text("No simulator uses it. Last used over a month ago. %@", cost),
            text("No simulator uses it. Last used 1 month ago. %@", cost),
            text("No simulator uses it. Last used %lld months ago. %@", 11, cost),
        ]
        var twoLines = [text(
            "Xcode's shader compiler for every account on this Mac. Xcode downloads it again (%@) if needed, or run %@.",
            "1023.9 MB", "xcodebuild -downloadComponent MetalToolchain"
        )]
        for base in bases {
            twoLines += [
                base,
                text("Only runs %@ simulators. %@", devices, base),
                text("The only %@ runtime here that runs most devices. %@", "visionOS", base),
            ]
        }
        let deletes = text("Deletes its apps and data.")
        let oneLine = [
            text("Running now, so it can't be removed. Shut it down in Simulator, then scan again."),
            text("Busy right now, so it can't be removed. Scan again in a moment."),
            text("Xcode can no longer run this device. %@", deletes),
            text("Used in the last month. %@", deletes),
            text("Last used 1 month ago. %@", deletes),
            text("Last used %lld months ago. %@", 11, deletes),
            text("Last use unknown. %@", deletes),
        ]
        let tooLong = twoLines.filter { Self.lineCount($0, width: width, language: language) > 2 }
            + oneLine.filter { Self.lineCount($0, width: width, language: language) > 1 }
        #expect(tooLong.isEmpty, "\(language): \(tooLong.joined(separator: "\n"))")
    }
}
