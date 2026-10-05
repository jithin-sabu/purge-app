import AppIntents
import AppKit

/// The menu bar's Clean, from Spotlight or Siri: scans, then moves Safe items
/// in App Caches and Dev Tools to the Trash, where they can be recovered.
/// Check First items are never touched. Only explicit cleaning words lead
/// here; vague ones ("free up space", "clean up my Mac") stay with Scan for
/// Junk, so a loose request never cleans by accident.
struct CleanSafeJunkIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Safe Junk"
    static let description = IntentDescription(
        "Scans for junk and moves the Safe items in App Caches and Dev Tools to the Trash, like Clean in Purge's menu bar. Check First items are left alone.",
        searchKeywords: [
            "clean", "clean junk", "clean safe junk", "clean my mac", "cleanup",
            "clear junk", "clear cache", "clear caches", "delete junk", "remove junk",
            "empty caches", "trash junk",
        ]
    )

    /// Opens Purge on the Overview, which shows the cleaning as it happens, and
    /// answers with one line, the form Spotlight keeps inside its panel.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AttributedString> & ProvidesDialog {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let outcome = await IntentRouter.shared.cleanSafeJunk(reduceMotion: reduceMotion)
        return .result(value: outcome.styledAnswer, dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

extension IntentRouter.CleanOutcome {
    /// "Moved 1.61 GB of junk to the Trash." with the size in bold.
    var styledAnswer: AttributedString {
        guard case .cleaned(let bytes, let failedCount) = self, bytes > 0 else { return AttributedString(dialog) }
        var size = AttributedString(formatBytes(bytes))
        size.inlinePresentationIntent = .stronglyEmphasized
        return AttributedString("Moved ") + size + AttributedString(" of junk to the Trash.")
            + AttributedString(Self.failureNote(failedCount))
    }

    var dialog: String {
        switch self {
        case .needsSetup:
            return "Finish setting up Purge first."
        case .busyCleaning:
            return "Purge is already cleaning."
        case .nothingToClean:
            return "No junk to clean right now."
        case .stopped:
            return "The scan stopped before it finished, so nothing was cleaned."
        case .cleaned(let bytes, let failedCount) where bytes > 0:
            return "Moved \(formatBytes(bytes)) of junk to the Trash." + Self.failureNote(failedCount)
        case .cleaned:
            return "Purge couldn't move the junk to the Trash. Open Purge to see why."
        }
    }

    private static func failureNote(_ failedCount: Int) -> String {
        switch failedCount {
        case 0: return ""
        case 1: return " 1 item couldn't be moved."
        default: return " \(failedCount) items couldn't be moved."
        }
    }
}
