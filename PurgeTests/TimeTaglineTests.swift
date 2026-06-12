import Foundation
import Testing
@testable import purge

@Suite("TimeTagline time formatting")
struct TimeTaglineTimeTextTests {
    @Test(arguments: [
        (0.84, "0.8 seconds"),
        (0.04, "0.1 seconds"),
        (0.0, "0.1 seconds"),
        (1.0, "1 second"),
        (1.4, "1 second"),
        (2.4, "2 seconds"),
        (59.0, "59 seconds"),
        (59.8, "1m 0s"),
        (61.0, "1m 1s"),
        (134.0, "2m 14s"),
    ])
    func formatsElapsedTime(seconds: Double, expected: String) {
        #expect(TimeTagline.timeText(for: seconds) == expected)
    }
}

@Suite("TimeTagline quip tiers")
struct TimeTaglineQuipTests {
    @Test func quipComesFromTheMatchingTier() {
        #expect(TimeTagline.quips(for: 0.5).contains("blink and you missed it"))
        #expect(TimeTagline.quips(for: 5).contains("nice and snappy"))
        #expect(TimeTagline.quips(for: 30).contains("worth the wait"))
        #expect(TimeTagline.quips(for: 90).contains("that was a big one"))
    }

    @Test func lineCombinesTimeAndTierQuip() {
        let defaults = UserDefaults(suiteName: "TimeTaglineTests.line")!
        defaults.removePersistentDomain(forName: "TimeTaglineTests.line")

        let line = TimeTagline.line(for: 5, defaults: defaults)
        #expect(line.hasPrefix("done in 5 seconds · "))
        let quip = String(line.dropFirst("done in 5 seconds · ".count))
        #expect(TimeTagline.quips(for: 5).contains(quip))
    }

    @Test func rerollsOnceWhenMatchingLastShownQuip() {
        let suite = "TimeTaglineTests.reroll"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        var previousQuip: String?
        var immediateRepeatSurvivedRerollOdds = 0
        for _ in 0..<200 {
            let selection = TimeTagline.select(for: 5, defaults: defaults)
            if selection.quip == previousQuip {
                immediateRepeatSurvivedRerollOdds += 1
            }
            TimeTagline.store(selection, defaults: defaults)
            previousQuip = selection.quip
        }

        // A single reroll still allows repeats at ~1/9 for a 3-quip tier;
        // without it the repeat rate would be ~1/3. Verify it is clearly reduced.
        #expect(immediateRepeatSurvivedRerollOdds < 50)
    }
}
