import AppIntents
import Foundation

struct ScanMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan My Mac"
    static let description = IntentDescription(
        "Opens Purge on the Overview, scans your Mac, and says how much is safe to clean in App Caches and Dev Tools. Nothing is cleaned.",
        searchKeywords: ["scan", "clean", "clean up", "junk", "cache", "caches", "free space", "free up space", "storage", "disk space", "space"]
    )

    /// Opens Purge, and answers with one line of text. That is the only form
    /// Spotlight keeps inside its own panel: a card, a progress line or a
    /// follow-up question all move the action into a separate box, and so does
    /// running in the background for more than a moment. Cleaning happens in
    /// the window, on the Overview's Clean Safe Items.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AttributedString> & ProvidesDialog {
        let outcome = await IntentRouter.shared.scanMac()
        return .result(value: outcome.styledAnswer, dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

extension IntentRouter.ScanOutcome {
    /// The size a Shortcuts automation can compare, for Get Safe-to-Clean Size.
    var safeSize: Measurement<UnitInformationStorage>? {
        guard case .scanned(let bytes) = self else { return nil }
        return IntentFileSize.measurement(bytes)
    }

    /// The answer Spotlight shows, with the size in bold.
    var styledAnswer: AttributedString {
        guard case .scanned(let bytes) = self, bytes > 0 else { return AttributedString(dialog) }
        var size = AttributedString(formatBytes(bytes))
        size.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString("Found ") + size + AttributedString(" that's safe to clean.")
    }

    var dialog: String {
        switch self {
        case .needsSetup:
            return "Finish setting up Purge first."
        case .busyCleaning:
            return "Purge is cleaning right now. Scan again when it's done."
        case .scanned(let bytes) where bytes > 0:
            return "Found \(formatBytes(bytes)) that's safe to clean."
        case .scanned:
            return "Nothing needs cleaning right now."
        case .stopped:
            return "The scan stopped before it finished."
        }
    }
}

/// Sizes handed back to Spotlight and Shortcuts. Spotlight shows a returned
/// value as it is, so a plain byte count reads "1,576,079,360 B". This picks
/// the unit `formatBytes` would and rounds to two places: "1.58 GB". Shortcuts
/// still compares it as a file size, whatever the unit.
enum IntentFileSize {
    static func measurement(_ bytes: Int64) -> Measurement<UnitInformationStorage> {
        let value = Double(max(bytes, 0))
        let unit: UnitInformationStorage
        switch value {
        case 1e12...: unit = .terabytes
        case 1e9...: unit = .gigabytes
        case 1e6...: unit = .megabytes
        case 1e3...: unit = .kilobytes
        default: unit = .bytes
        }
        let converted = Measurement(value: value, unit: UnitInformationStorage.bytes).converted(to: unit)
        return Measurement(value: (converted.value * 100).rounded() / 100, unit: unit)
    }
}
