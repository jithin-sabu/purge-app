import AppIntents
import Foundation

struct ScanMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan My Mac"
    static let description = IntentDescription(
        "Opens Purge, scans your Mac, and says how much is safe to clean in App Caches and Dev Tools. Nothing is cleaned without your confirmation in Purge.",
        searchKeywords: ["scan", "clean", "clean up", "junk", "cache", "caches", "free space", "free up space", "storage", "disk space", "space"]
    )
    static let openAppWhenRun = true

    /// Returns the sentence as the value, not a size or a card: Spotlight shows
    /// a returned value inline in its own panel, while a card opens separately.
    /// Shortcuts automations that compare sizes use Get Safe-to-Clean Size.
    ///
    /// When there is something to clean, it asks "Clean it up in Purge?" in the
    /// same panel. Yes opens Purge's own Clean Safe Items confirmation; nothing
    /// is cleaned from Spotlight or Siri.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let router = IntentRouter.shared
        let outcome = await router.scanMac()
        if #available(macOS 15.0, *), case .scanned(let bytes) = outcome, bytes > 0 {
            do {
                try await requestConfirmation(
                    actionName: .continue,
                    dialog: IntentDialog(stringLiteral: outcome.cleanUpQuestion)
                )
            } catch {
                // Declined or dismissed: just give the answer.
                return .result(value: outcome.dialog, dialog: IntentDialog(stringLiteral: outcome.dialog))
            }
            router.reviewSafeClean()
            let answer = "Purge is showing what it will clean. Confirm there to move it to the Trash."
            return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
        }
        return .result(value: outcome.dialog, dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

extension IntentRouter.ScanOutcome {
    /// The size a Shortcuts automation can compare, for Get Safe-to-Clean Size.
    var safeSize: Measurement<UnitInformationStorage>? {
        guard case .scanned(let bytes) = self else { return nil }
        return IntentFileSize.measurement(bytes)
    }

    /// Asked in the Spotlight or Siri panel when there is something to clean.
    var cleanUpQuestion: String {
        guard case .scanned(let bytes) = self else { return dialog }
        return "Found \(formatBytes(bytes)) that's safe to clean. Clean it up in Purge?"
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
