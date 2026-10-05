import AppIntents
import Foundation

/// Named for what it finds: "Scan My Mac" read like a virus scan, and the
/// answer covers only App Caches and Dev Tools.
struct ScanForJunkIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan for Junk"
    static let description = IntentDescription(
        "Opens Purge on the Overview, scans for junk, and says how much is safe to clean in App Caches and Dev Tools. Nothing is cleaned.",
        searchKeywords: ["scan", "scan my mac", "junk", "clean", "clean up", "cache", "caches", "free space", "free up space", "storage", "disk space", "space"]
    )

    /// Opens Purge, and answers with one line of text. That is the form
    /// Spotlight keeps inside its own panel: a card, a follow-up question or a
    /// background run moves the action into a separate box. Cleaning happens in
    /// the window, on the Overview's Clean Safe Items.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AttributedString> & ProvidesDialog {
        if #available(macOS 14.0, *) {
            progress.totalUnitCount = 1
            progress.localizedDescription = "Scanning for junk…"
        }
        let outcome = await IntentRouter.shared.scanMac()
        if #available(macOS 14.0, *) {
            progress.completedUnitCount = 1
        }
        return .result(value: outcome.styledAnswer, dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

/// Lets Spotlight say "Scanning for junk…" while it runs, instead of repeating
/// the action's name.
@available(macOS 14.0, *)
extension ScanForJunkIntent: ProgressReportingIntent {}

extension IntentRouter.ScanOutcome {
    /// The size a Shortcuts automation can compare, for a size-only action.
    var safeSize: Measurement<UnitInformationStorage>? {
        guard case .scanned(let bytes) = self else { return nil }
        return IntentFileSize.measurement(bytes)
    }

    /// The answer Spotlight shows, with the size in bold.
    var styledAnswer: AttributedString {
        guard case .scanned(let bytes) = self, bytes > 0 else { return AttributedString(dialog) }
        var size = AttributedString(formatBytes(bytes))
        size.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString("Found ") + size + AttributedString(" of junk that's safe to clean.")
    }

    var dialog: String {
        switch self {
        case .needsSetup:
            return "Finish setting up Purge first."
        case .busyCleaning:
            return "Purge is cleaning right now. Scan again when it's done."
        case .scanned(let bytes) where bytes > 0:
            return "Found \(formatBytes(bytes)) of junk that's safe to clean."
        case .scanned:
            return "No junk to clean right now."
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
