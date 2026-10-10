import Foundation

/// Decides how the cleanup completion screen mentions buy-me-a-coffee.
///
/// Two forms, never both on one screen. The card marks big lifetime milestones (100 GB,
/// then every 50 GB) moved to trash. It shows whenever one is reached, even twice in
/// a week, never on the first clean, and each milestone at most once. A quiet line
/// under Done covers big cleans in between, at most once a week, and the card
/// restarts that week too. Once either link has been opened, neither returns.
enum SupportNudge {
    static let url = URL(string: "https://buymeacoffee.com/jithinsabu")!

    /// Milestones in decimal gigabytes, matching how `formatBytes` reports sizes:
    /// 100 GB, then every 50 GB after it.
    static let firstMilestoneGB: Int64 = 100
    static let milestoneStepGB: Int64 = 50
    static let bytesPerGB: Int64 = 1_000_000_000

    static let lastShownMilestoneKey = "supportNudge.lastShownMilestoneGB"
    static let didOpenLinkKey = "supportNudge.didOpenLink"
    /// When the card or the line last appeared, for the line's cooldown.
    static let lastShownAtKey = "supportNudge.lastShownAt"

    /// The same size that sets off the completion confetti, so the line only joins
    /// screens that already celebrate.
    static let significantCleanBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let footerCooldown: TimeInterval = 7 * 24 * 60 * 60

    /// The milestone to mention, in bytes, or `nil` when the card should stay hidden.
    /// `lifetimeBytes` already includes `cleanBytes`; the store adds a run to the
    /// lifetime total before the completion screen appears.
    static func milestone(
        lifetimeBytes: Int64,
        cleanBytes: Int64,
        defaults: UserDefaults = .standard
    ) -> Int64? {
        // Nothing moved, or this clean is all there is: no history to point at yet.
        guard cleanBytes > 0, lifetimeBytes > cleanBytes else { return nil }
        guard !defaults.bool(forKey: didOpenLinkKey) else { return nil }
        let lifetimeGB = lifetimeBytes / bytesPerGB
        guard lifetimeGB >= firstMilestoneGB else { return nil }
        let reachedGB = lifetimeGB / milestoneStepGB * milestoneStepGB
        let lastShownGB = Int64(defaults.integer(forKey: lastShownMilestoneKey))
        guard reachedGB > lastShownGB else { return nil }
        return reachedGB * bytesPerGB
    }

    /// The quiet line under Done, for big cleans that did not reach a milestone,
    /// and only when neither the line nor the card showed in the past week.
    static func showsFooterLink(
        cleanBytes: Int64,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard cleanBytes >= significantCleanBytes, !defaults.bool(forKey: didOpenLinkKey) else {
            return false
        }
        guard let lastShownAt = defaults.object(forKey: lastShownAtKey) as? Date else { return true }
        return now.timeIntervalSince(lastShownAt) >= footerCooldown
    }

    static func recordShown(milestoneBytes: Int64, now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(Int(milestoneBytes / bytesPerGB), forKey: lastShownMilestoneKey)
        defaults.set(now, forKey: lastShownAtKey)
    }

    static func recordLinkOpened(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: didOpenLinkKey)
    }

    // MARK: - Footer line

    /// One footer line: plain text, then the link. The link text is capitalised only
    /// when it starts a sentence.
    struct Line: Equatable {
        let id: String
        let prefix: String
        let linkText: String
    }

    /// What the finished clean did. Size and time are already on screen above the
    /// line, so the lines lean on facts the screen does not show yet.
    struct CleanFacts {
        let bytes: Int64
        let itemCount: Int
        let lifetimeBytes: Int64
    }

    static let lastShownLineKey = "supportNudge.lastShownLine"
    private static let bigCleanBytes: Int64 = 10 * bytesPerGB

    static func lines(for facts: CleanFacts) -> [Line] {
        var lines = [
            Line(id: "free", prefix: String(localized: "Purge is free. "), linkText: String(localized: "Buy me a coffee")),
            Line(id: "noAds", prefix: String(localized: "No ads, no subscription. "), linkText: String(localized: "Buy me a coffee")),
        ]
        if facts.itemCount >= 2 {
            lines.append(Line(
                id: "items",
                prefix: String(localized: "\(facts.itemCount.formatted()) items cleaned up, on the house. "),
                linkText: String(localized: "Buy me a coffee")
            ))
        }
        // Only once there is history beyond this clean, or it just repeats the big number.
        if facts.lifetimeBytes > facts.bytes {
            lines.append(Line(
                id: "lifetime",
                prefix: String(localized: "\(formatBytesRoundedDown(facts.lifetimeBytes)) cleaned up with Purge so far. "),
                linkText: String(localized: "Buy me a coffee")
            ))
        }
        if facts.bytes >= bigCleanBytes {
            lines.append(Line(id: "big", prefix: String(localized: "That was a big one. If it helped, "), linkText: String(localized: "buy me a coffee")))
        }
        return lines
    }

    /// Picks a line for this clean, never the one shown last time when another fits,
    /// and records it.
    static func selectLine(
        for facts: CleanFacts,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Line {
        let options = lines(for: facts)
        let lastShown = defaults.string(forKey: lastShownLineKey)
        let fresh = options.filter { $0.id != lastShown }
        let pick = (fresh.isEmpty ? options : fresh).randomElement() ?? options[0]
        defaults.set(pick.id, forKey: lastShownLineKey)
        defaults.set(now, forKey: lastShownAtKey)
        return pick
    }
}
