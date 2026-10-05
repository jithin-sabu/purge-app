import AppIntents
import Foundation

/// Answers from the last scan, without scanning and without opening Purge.
struct HowMuchCanPurgeFreeIntent: AppIntent {
    static let title: LocalizedStringResource = "How Much Can Purge Free?"
    static let description = IntentDescription(
        "Says how much junk Purge's last scan found safe to clean in App Caches and Dev Tools, and when that scan ran. Purge stays closed.",
        searchKeywords: ["how much", "free", "free up", "junk", "space", "storage", "disk space", "clean"]
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AttributedString> & ProvidesDialog {
        let answer = IntentRouter.shared.spaceToFree()
        return .result(value: answer.styledText(), dialog: IntentDialog(stringLiteral: answer.text()))
    }
}

/// For Shortcuts automations ("if more than 5 GB, notify me"): the same figure
/// as a file size a shortcut can compare. Spotlight lists it too; macOS has no
/// way to keep an action in Shortcuts only.
struct GetJunkSizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Junk Size"
    static let description = IntentDescription(
        "Returns the size of the junk Purge's last scan found safe to clean, as a file size your shortcuts can compare. Nothing if Purge hasn't scanned yet.",
        searchKeywords: ["junk", "size", "space", "storage"]
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitInformationStorage>?> & ProvidesDialog {
        let answer = IntentRouter.shared.spaceToFree()
        return .result(value: answer.size, dialog: IntentDialog(stringLiteral: answer.text()))
    }
}

extension IntentRouter.SpaceAnswer {
    var size: Measurement<UnitInformationStorage>? {
        guard case .known(let bytes, _) = self else { return nil }
        return IntentFileSize.measurement(bytes)
    }

    func text(now: Date = Date()) -> String {
        String(styledText(now: now).characters)
    }

    /// "About 1.61 GB of junk is safe to clean, as of 5 minutes ago." with the
    /// size in bold, like Scan for Junk's answer.
    func styledText(now: Date = Date()) -> AttributedString {
        switch self {
        case .neverScanned:
            return AttributedString("Purge hasn't scanned for junk yet. Run Scan for Junk first.")
        case .known(let bytes, let scannedAt):
            let age = Self.age(of: scannedAt, now: now)
            guard bytes > 0 else { return AttributedString("No junk to clean, as of \(age).") }
            var size = AttributedString(formatBytes(bytes))
            size.inlinePresentationIntent = .stronglyEmphasized
            return AttributedString("About ") + size
                + AttributedString(" of junk is safe to clean, as of \(age).")
        }
    }

    /// "just now", "5 minutes ago", "yesterday".
    static func age(of date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
