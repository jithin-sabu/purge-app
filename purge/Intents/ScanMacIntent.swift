import AppIntents
import Foundation

struct ScanMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan My Mac"
    static let description = IntentDescription(
        "Scans your Mac and says how much is safe to clean in App Caches and Dev Tools. Nothing is cleaned without your confirmation in Purge.",
        searchKeywords: ["scan", "clean", "clean up", "junk", "cache", "caches", "free space", "free up space", "storage", "disk space", "space"]
    )

    /// Runs inside Spotlight or Siri with Purge in the background, so the panel
    /// can show progress, the answer and the "Clean it up?" question. An action
    /// that opens Purge first hands itself over to the app, and the panel can no
    /// longer ask anything. Purge comes forward only after Continue.
    static let openAppWhenRun = false

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AttributedString> & ProvidesDialog {
        let router = IntentRouter.shared
        if #available(macOS 14.0, *) {
            progress.totalUnitCount = 1
            progress.localizedDescription = "Scanning App Caches and Dev Tools…"
        }
        let outcome = await router.scanMac()
        if #available(macOS 14.0, *) {
            progress.completedUnitCount = 1
        }

        let (value, spoken) = try await answerOrOpenReview(outcome)
        return .result(value: value, dialog: IntentDialog(stringLiteral: spoken))
    }

    /// The answer, or, when there is something to clean and the person says
    /// Continue, Purge's confirmation and a line saying so.
    @MainActor
    private func answerOrOpenReview(_ outcome: IntentRouter.ScanOutcome) async throws -> (AttributedString, String) {
        guard case .scanned(let bytes) = outcome, bytes > 0, #available(macOS 15.0, *) else {
            return (outcome.styledAnswer, outcome.dialog)
        }
        do {
            try await requestConfirmation(
                actionName: .continue,
                dialog: IntentDialog(stringLiteral: outcome.cleanUpQuestion)
            )
        } catch {
            // Declined or dismissed: just give the answer.
            return (outcome.styledAnswer, outcome.dialog)
        }
        try await bringPurgeForward()
        IntentRouter.shared.reviewSafeClean()
        let text = "Purge is showing what it will clean. Confirm there to move it to the Trash."
        return (AttributedString(text), text)
    }

    /// Continue was chosen: bring Purge to the front for its confirmation.
    @available(macOS 15.0, *)
    @MainActor
    private func bringPurgeForward() async throws {
        if #available(macOS 26.0, *) {
            try await continueInForeground(alwaysConfirm: false)
        } else {
            try await requestToContinueInForeground()
        }
    }
}

/// Spotlight shows "Scanning App Caches and Dev Tools…" while the scan runs,
/// instead of only the action's name.
@available(macOS 14.0, *)
extension ScanMacIntent: ProgressReportingIntent {}

/// The pre-macOS 26 way to bring Purge forward after Continue.
@available(macOS 13.3, *)
extension ScanMacIntent: ForegroundContinuableIntent {}

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
