import AppIntents
import Foundation

/// Named for what it finds: "Scan My Mac" read like a virus scan, and the
/// answer covers only App Caches and Dev Tools.
struct ScanForJunkIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan for Junk"
    /// One action for every way of asking about junk and space: Spotlight
    /// matches typed words against the title, the App Shortcut phrases and
    /// these keywords, so "free up space", "storage full" or "how much can I
    /// free" all find it.
    static let description = IntentDescription(
        "Opens Purge on the Overview, scans for junk, and says how much is safe to clean in App Caches and Dev Tools. Nothing is cleaned until you confirm in Purge.",
        searchKeywords: [
            // Cleaning words go to Clean Safe Junk; this keeps the ones that
            // only ask how things stand.
            "junk", "scan", "scan my mac", "check junk", "find junk",
            "free space", "free up space", "space", "storage", "storage full", "disk full",
            "disk space", "mac is full", "low on space", "how much can i free",
            "what's taking space", "cache", "caches",
        ]
    )

    /// Opens Purge, and answers with one line of text. That is the form
    /// Spotlight keeps inside its own panel: a card, a follow-up question or a
    /// background run moves the action into a separate box. Progress is not
    /// reported: Spotlight shows the action's name while it runs regardless.
    /// Cleaning happens in the window, on the Overview's Clean Safe Items.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AttributedString> & ProvidesDialog {
        let outcome = await IntentRouter.shared.scanMac()
        return .result(value: outcome.styledAnswer, dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

extension IntentRouter.ScanOutcome {
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
