import AppIntents
import Foundation
import SwiftUI

struct ScanMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan My Mac"
    static let description = IntentDescription(
        "Opens Purge, scans your Mac, and says how much is safe to clean in App Caches and Dev Tools. Nothing is cleaned."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitInformationStorage>?> & ProvidesDialog & ShowsSnippetView {
        let outcome = await IntentRouter.shared.scanMac()
        // The card is what Spotlight shows; Siri speaks the dialog; Shortcuts
        // gets the size to compare.
        return .result(
            value: outcome.safeSize,
            dialog: IntentDialog(stringLiteral: outcome.dialog),
            view: ScanResultSnippet(outcome: outcome)
        )
    }
}

extension IntentRouter.ScanOutcome {
    /// Returned to Shortcuts as a file size, so a shortcut can compare it.
    var safeSize: Measurement<UnitInformationStorage>? {
        guard case .scanned(let bytes) = self else { return nil }
        return IntentFileSize.measurement(bytes)
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
