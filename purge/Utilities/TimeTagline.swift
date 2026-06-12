import Foundation

/// Builds the completion tagline shown on the cleanup overlay:
/// "done in [time] · [quip]".
enum TimeTagline {
    struct Selection: Equatable {
        let line: String
        let quip: String
    }

    private static let lastShownQuipKey = "cleanCompletion.lastShownTimeQuip"

    /// One-shot convenience: picks a non-repeating quip and records it as last shown.
    static func line(for seconds: Double, defaults: UserDefaults = .standard) -> String {
        let selection = select(for: seconds, defaults: defaults)
        store(selection, defaults: defaults)
        return selection.line
    }

    /// Pure pick (no UserDefaults write) so callers can choose in `init` and
    /// persist in `onAppear`, mirroring the previous encouragement picker.
    static func select(for seconds: Double, defaults: UserDefaults = .standard) -> Selection {
        let options = quips(for: seconds)
        let lastShown = defaults.string(forKey: lastShownQuipKey)
        var pick = options.randomElement() ?? options[0]
        if pick == lastShown, let reroll = options.randomElement() {
            pick = reroll
        }
        return Selection(line: "done in \(timeText(for: seconds)) · \(pick)", quip: pick)
    }

    static func store(_ selection: Selection, defaults: UserDefaults = .standard) {
        defaults.set(selection.quip, forKey: lastShownQuipKey)
    }

    static func timeText(for seconds: Double) -> String {
        if seconds < 1 {
            return String(format: "%.1f seconds", max(0.1, seconds))
        }
        let whole = Int(seconds.rounded())
        if whole < 60 {
            return whole == 1 ? "1 second" : "\(whole) seconds"
        }
        return "\(whole / 60)m \(whole % 60)s"
    }

    static func quips(for seconds: Double) -> [String] {
        switch seconds {
        case ..<3:
            return [
                "blink and you missed it",
                "that was quick",
                "barely broke a sweat",
                "faster than your coffee order"
            ]
        case ..<15:
            return [
                "nice and snappy",
                "smooth operator",
                "in and out"
            ]
        case ..<60:
            return [
                "worth the wait",
                "that was a proper clean",
                "deep clean, done"
            ]
        default:
            return [
                "that was a big one",
                "heavy lifting, handled",
                "your mac says thanks"
            ]
        }
    }
}
