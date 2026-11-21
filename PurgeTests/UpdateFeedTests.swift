import Foundation
import Testing
@testable import Purge

/// Sparkle reads the appcast from updates.purgemac.com. When a check can't load
/// it, the next check reads the same file from GitHub, once.
@MainActor
@Suite("The update feed falls back to GitHub for one check")
struct UpdateFeedTests {
    private let suite = ThrowawayDefaults()

    private func sparkleError(_ code: Int, underlying: NSError? = nil) -> NSError {
        var userInfo: [String: Any] = [:]
        if let underlying { userInfo[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: UpdateFeed.sparkleErrorDomain, code: code, userInfo: userInfo)
    }

    private let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    private let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

    // MARK: - The shipped settings

    @Test
    func infoPlistPointsAtUpdatesPurgemacWithProfilingOff() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://updates.purgemac.com/appcast.xml")
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
    }

    @Test
    func fallbackIsTheRepoAppcastOverHTTPS() {
        let url = URL(string: UpdateFeed.gitHubFallbackURL)
        #expect(url?.scheme == "https")
        #expect(url?.host == "raw.githubusercontent.com")
        #expect(url?.path == "/jithin-sabu/purge-app/main/appcast.xml")
    }

    @Test
    func feedChoice() {
        #expect(UpdateFeed.feedURLString(fallbackPending: false) == nil)
        #expect(UpdateFeed.feedURLString(fallbackPending: true) == UpdateFeed.gitHubFallbackURL)
    }

    // MARK: - What counts as the feed failing

    @Test
    func networkAndServerErrorsBeforeTheAppcastLoadedAreFailures() {
        for error in [
            offline,
            sparkleError(UpdateFeed.downloadErrorCode, underlying: offline),
            sparkleError(UpdateFeed.appcastErrorCode),
            sparkleError(UpdateFeed.appcastParseErrorCode),
        ] {
            #expect(UpdateFeed.isFeedLoadFailure(error, appcastLoaded: false))
        }
    }

    /// No update found is the usual result of a check, not an outage.
    @Test
    func noUpdateFoundIsNeverAFailure() {
        let noUpdate = sparkleError(UpdateFeed.noUpdateErrorCode)
        #expect(!UpdateFeed.isFeedLoadFailure(noUpdate, appcastLoaded: true))
        #expect(!UpdateFeed.isFeedLoadFailure(noUpdate, appcastLoaded: false))
    }

    @Test
    func noErrorIsNotAFailure() {
        #expect(!UpdateFeed.isFeedLoadFailure(nil, appcastLoaded: true))
        #expect(!UpdateFeed.isFeedLoadFailure(nil, appcastLoaded: false))
    }

    /// Once the appcast loaded, a failed DMG download or a bad signature is the
    /// update's problem, so switching feeds would not help.
    @Test
    func errorsAfterTheAppcastLoadedAreNotFeedFailures() {
        #expect(!UpdateFeed.isFeedLoadFailure(
            sparkleError(UpdateFeed.downloadErrorCode, underlying: offline), appcastLoaded: true
        ))
        #expect(!UpdateFeed.isFeedLoadFailure(offline, appcastLoaded: true))
    }

    @Test
    func cancelledRequestsAndOtherErrorsAreNotFailures() {
        #expect(!UpdateFeed.isFeedLoadFailure(cancelled, appcastLoaded: false))
        #expect(!UpdateFeed.isFeedLoadFailure(
            sparkleError(UpdateFeed.downloadErrorCode, underlying: cancelled), appcastLoaded: false
        ))
        // SUInstallationCanceledError, and an error from somewhere else.
        #expect(!UpdateFeed.isFeedLoadFailure(sparkleError(4007), appcastLoaded: false))
        #expect(!UpdateFeed.isFeedLoadFailure(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError), appcastLoaded: false
        ))
    }

    // MARK: - One check on GitHub, then back

    @Test
    func aPrimaryFailureSendsOnlyTheNextCheckToGitHub() {
        #expect(UpdateFeed.fallbackPendingAfterCheck(usedFallback: false, appcastLoaded: false, error: offline))
        // The GitHub check goes back to the primary feed whether it worked or not.
        #expect(!UpdateFeed.fallbackPendingAfterCheck(usedFallback: true, appcastLoaded: false, error: offline))
        #expect(!UpdateFeed.fallbackPendingAfterCheck(usedFallback: true, appcastLoaded: true, error: nil))
        #expect(!UpdateFeed.fallbackPendingAfterCheck(
            usedFallback: false, appcastLoaded: true, error: sparkleError(UpdateFeed.noUpdateErrorCode)
        ))
    }

    @Test
    func theFlagRoundTripsThroughDefaults() {
        let defaults = suite.defaults
        #expect(!UpdateFeed.isFallbackPending(in: defaults))

        // The primary feed is down.
        UpdateFeed.recordFinishedCheck(appcastLoaded: false, error: offline, in: defaults)
        #expect(UpdateFeed.isFallbackPending(in: defaults))
        #expect(defaults.bool(forKey: UpdateFeed.fallbackPendingKey))

        // The GitHub check finds nothing new; the next check is back on the primary.
        UpdateFeed.recordFinishedCheck(
            appcastLoaded: true, error: sparkleError(UpdateFeed.noUpdateErrorCode), in: defaults
        )
        #expect(!UpdateFeed.isFallbackPending(in: defaults))
        #expect(defaults.object(forKey: UpdateFeed.fallbackPendingKey) == nil)

        // A check on the primary that loads leaves the flag off.
        UpdateFeed.recordFinishedCheck(appcastLoaded: true, error: nil, in: defaults)
        #expect(!UpdateFeed.isFallbackPending(in: defaults))
    }

    @Test
    func aFailedGitHubCheckStillGoesBackToThePrimary() {
        let defaults = suite.defaults
        UpdateFeed.recordFinishedCheck(appcastLoaded: false, error: offline, in: defaults)
        UpdateFeed.recordFinishedCheck(appcastLoaded: false, error: offline, in: defaults)
        #expect(!UpdateFeed.isFallbackPending(in: defaults))
    }
}
