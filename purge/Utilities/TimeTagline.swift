import Foundation

/// Formats the cleanup time on the completion screen's "done in [time]" line.
enum TimeTagline {
    static func timeText(for seconds: Double) -> String {
        if seconds < 1 {
            return String(format: NSLocalizedString("%.1f seconds", comment: "Cleanup duration"), max(0.1, seconds))
        }
        let whole = Int(seconds.rounded())
        if whole < 60 {
            return whole == 1 ? String(localized: "1 second") : String(localized: "\(whole) seconds")
        }
        return String(localized: "\(whole / 60)m \(whole % 60)s")
    }
}
