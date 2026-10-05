import AppIntents
import Foundation

struct ScanMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan My Mac"
    static let description = IntentDescription(
        "Opens Purge, scans your Mac, and says how much is safe to clean in App Caches and Dev Tools. Nothing is cleaned."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitInformationStorage>?> & ProvidesDialog {
        let outcome = await IntentRouter.shared.scanMac()
        return .result(value: outcome.safeSize, dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

extension IntentRouter.ScanOutcome {
    /// Returned to Shortcuts as a file size, so a shortcut can compare it.
    var safeSize: Measurement<UnitInformationStorage>? {
        guard case .scanned(let bytes) = self else { return nil }
        return Measurement(value: Double(bytes), unit: .bytes)
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
