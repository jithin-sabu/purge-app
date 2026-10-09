import Foundation
import Testing
@testable import Purge

@Suite("SupportNudge milestones")
struct SupportNudgeTests {
    private let gb = SupportNudge.bytesPerGB

    private let suite = ThrowawayDefaults()

    @Test func hiddenOnTheFirstClean() {
        let defaults = suite.defaults
        #expect(SupportNudge.milestone(lifetimeBytes: 30 * gb, cleanBytes: 30 * gb, defaults: defaults) == nil)
    }

    @Test func hiddenBelowTheFirstMilestone() {
        let defaults = suite.defaults
        #expect(SupportNudge.milestone(lifetimeBytes: 99 * gb, cleanBytes: 2 * gb, defaults: defaults) == nil)
    }

    @Test func hiddenWhenNothingMoved() {
        let defaults = suite.defaults
        #expect(SupportNudge.milestone(lifetimeBytes: 40 * gb, cleanBytes: 0, defaults: defaults) == nil)
    }

    @Test func picksTheHighestMilestoneReached() {
        let defaults = suite.defaults
        #expect(SupportNudge.milestone(lifetimeBytes: 101 * gb, cleanBytes: 3 * gb, defaults: defaults) == 100 * gb)
        #expect(SupportNudge.milestone(lifetimeBytes: 362 * gb, cleanBytes: 1 * gb, defaults: defaults) == 350 * gb)
        #expect(SupportNudge.milestone(lifetimeBytes: 1_210 * gb, cleanBytes: 1 * gb, defaults: defaults) == 1_200 * gb)
    }

    @Test func eachMilestoneShowsOnce() {
        let defaults = suite.defaults
        let first = SupportNudge.milestone(lifetimeBytes: 120 * gb, cleanBytes: 3 * gb, defaults: defaults)
        #expect(first == 100 * gb)
        SupportNudge.recordShown(milestoneBytes: 100 * gb, defaults: defaults)

        #expect(SupportNudge.milestone(lifetimeBytes: 140 * gb, cleanBytes: 20 * gb, defaults: defaults) == nil)
        #expect(SupportNudge.milestone(lifetimeBytes: 155 * gb, cleanBytes: 15 * gb, defaults: defaults) == 150 * gb)
    }

    @Test func milestonesIgnoreTheWeeklyLimit() {
        let defaults = suite.defaults
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        SupportNudge.recordShown(milestoneBytes: 100 * gb, now: start, defaults: defaults)
        // Two days later another 50 GB lands: the next milestone still shows.
        #expect(SupportNudge.milestone(lifetimeBytes: 152 * gb, cleanBytes: 52 * gb, defaults: defaults) == 150 * gb)
    }

    @Test func footerLinkNeedsABigClean() {
        let defaults = suite.defaults
        #expect(SupportNudge.showsFooterLink(cleanBytes: SupportNudge.significantCleanBytes, defaults: defaults))
        #expect(!SupportNudge.showsFooterLink(cleanBytes: SupportNudge.significantCleanBytes - 1, defaults: defaults))
        #expect(!SupportNudge.showsFooterLink(cleanBytes: 0, defaults: defaults))
    }

    @Test func footerLinkWaitsAWeekAfterEitherAsk() {
        let defaults = suite.defaults
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let facts = SupportNudge.CleanFacts(bytes: 3 * gb, itemCount: 20, lifetimeBytes: 40 * gb)

        _ = SupportNudge.selectLine(for: facts, now: start, defaults: defaults)
        #expect(!SupportNudge.showsFooterLink(cleanBytes: 3 * gb, now: start + 6 * day, defaults: defaults))
        #expect(SupportNudge.showsFooterLink(cleanBytes: 3 * gb, now: start + 7 * day, defaults: defaults))

        // A milestone card restarts the week as well.
        SupportNudge.recordShown(milestoneBytes: 50 * gb, now: start + 8 * day, defaults: defaults)
        #expect(!SupportNudge.showsFooterLink(cleanBytes: 3 * gb, now: start + 10 * day, defaults: defaults))
    }

    @Test func neverReturnsAfterTheLinkWasOpened() {
        let defaults = suite.defaults
        SupportNudge.recordLinkOpened(defaults: defaults)
        #expect(SupportNudge.milestone(lifetimeBytes: 600 * gb, cleanBytes: 5 * gb, defaults: defaults) == nil)
        #expect(!SupportNudge.showsFooterLink(cleanBytes: 5 * gb, defaults: defaults))
    }

    @Test func linesFollowWhatTheCleanDid() {
        let ids = { (facts: SupportNudge.CleanFacts) in Set(SupportNudge.lines(for: facts).map(\.id)) }

        let big = ids(.init(bytes: 12 * gb, itemCount: 40, lifetimeBytes: 80 * gb))
        #expect(big == ["free", "noAds", "items", "lifetime", "big"])

        let firstClean = ids(.init(bytes: 3 * gb, itemCount: 1, lifetimeBytes: 3 * gb))
        #expect(firstClean == ["free", "noAds"])
    }

    @Test func itemAndLifetimeLinesCarryTheNumbers() {
        let lines = SupportNudge.lines(for: .init(bytes: 3 * gb, itemCount: 128, lifetimeBytes: 362 * gb))
        #expect(lines.first { $0.id == "items" }?.prefix == "128 items cleaned up, on the house. ")
        #expect(lines.first { $0.id == "lifetime" }?.prefix.hasPrefix("362 GB cleaned up with Purge so far") == true)
    }

    @Test func selectedLineNeverRepeatsBackToBack() {
        let defaults = suite.defaults
        let facts = SupportNudge.CleanFacts(bytes: 3 * gb, itemCount: 20, lifetimeBytes: 40 * gb)
        var previous = SupportNudge.selectLine(for: facts, defaults: defaults)
        for _ in 0..<30 {
            let next = SupportNudge.selectLine(for: facts, defaults: defaults)
            #expect(next.id != previous.id)
            previous = next
        }
    }
}
