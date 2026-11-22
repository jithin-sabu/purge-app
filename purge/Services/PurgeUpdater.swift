//
//  PurgeUpdater.swift
//  purge
//
//  Wraps Sparkle for scheduled background checks and user-initiated
//  "Check for updates" checks.
//

import AppKit
import Combine
import Sparkle

@MainActor
final class PurgeUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!

    /// Mirrors Sparkle's own setting so SwiftUI can observe it. Sparkle persists the real
    /// value in user defaults under `SUEnableAutomaticChecks`, which takes precedence over
    /// the Info.plist default.
    @Published private(set) var automaticallyChecksForUpdates = false

    /// Sparkle's `SUAutomaticallyUpdate`: download updates in the background and
    /// install them when Purge quits. Off unless the user turns it on, here or with
    /// the checkbox in Sparkle's update window, which is why it is observed rather
    /// than only set from Settings.
    @Published private(set) var automaticallyDownloadsUpdates = false

    /// False while automatic checks are off: Sparkle only downloads in the
    /// background when it is also checking in the background.
    @Published private(set) var allowsAutomaticUpdates = false

    /// False while Sparkle can't start a check, such as when one is already
    /// running. Drives the enabled state of the Check for Updates menu item.
    @Published private(set) var canCheckForUpdates = false

    /// The version of a downloaded update waiting to install on quit. While set,
    /// the Check for Updates items become Restart to Update.
    @Published private(set) var readyUpdateVersion: String?

    /// Sparkle's handler that quits Purge, installs the waiting update and
    /// relaunches. It can run again if the quit is cancelled.
    private var installReadyUpdate: (() -> Void)?

    /// True once Sparkle has loaded and parsed the appcast in the running update
    /// cycle. A download error before that is the feed failing; after it, it is
    /// the update itself.
    private var appcastLoadedThisCycle = false

    override init() {
        super.init()
        // Not started in the unit-test host (#181): a started updater reads and
        // writes the real Sparkle defaults and can check for updates on the
        // developer's Mac in the middle of a test run. Unstarted, Sparkle leaves
        // `canCheckForUpdates` false, so the menu items stay disabled there.
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.startsUpdater(environment: ProcessInfo.processInfo.environment),
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            .assign(to: &$automaticallyDownloadsUpdates)
        controller.updater.publisher(for: \.allowsAutomaticUpdates)
            .assign(to: &$allowsAutomaticUpdates)
    }

    /// False only in the unit-test host. A build run from Xcode checks for
    /// updates like an installed one.
    nonisolated static func startsUpdater(environment: [String: String]) -> Bool {
        !TestHost.isActive(environment: environment)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdates()
    }

    /// Quits through the normal path, so `CleaningQuitGuard` can still stop it
    /// mid-clean. Sparkle installs the update and relaunches Purge.
    func restartToUpdate() {
        installReadyUpdate?()
    }

    /// The title for the Restart to Update menu items and About row.
    static func restartTitle(forVersion version: String) -> String {
        String(localized: "Restart to Update to Purge \(version)")
    }

    // MARK: - SPUUpdaterDelegate

    /// nil keeps `SUFeedURL` from Info.plist. After a check that couldn't load
    /// that feed, the next one reads it from GitHub instead (`UpdateFeed`).
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateFeed.feedURLString(fallbackPending: UpdateFeed.isFallbackPending(in: .standard))
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        appcastLoadedThisCycle = true
    }

    /// Sparkle downloaded an update in the background and will install it when
    /// Purge quits. Taking it over stops Sparkle from opening its update window
    /// later on its own, which in menu bar mode could come weeks after the
    /// download; the Restart to Update items replace that.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Sparkle shows a critical update straight away; keep that.
        guard !item.isCriticalUpdate else { return false }
        installReadyUpdate = immediateInstallHandler
        readyUpdateVersion = item.displayVersionString
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Sparkle already ends the session when the update driver aborts.
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        // Session is fully complete; safe to start another user-initiated check.
        // A waiting update's handler belongs to the cycle that just ended, so it
        // can no longer install anything.
        installReadyUpdate = nil
        readyUpdateVersion = nil
        UpdateFeed.recordFinishedCheck(appcastLoaded: appcastLoadedThisCycle, error: error, in: .standard)
        appcastLoadedThisCycle = false
    }
}

/// Where Sparkle looks for updates.
///
/// `SUFeedURL` in Info.plist is updates.purgemac.com, a small server that passes
/// on this repo's appcast.xml and counts checks in aggregate. Sparkle has no
/// fallback feed of its own, so when a check can't load that feed, the next
/// check reads the same file straight from GitHub, once. Then it goes back to
/// updates.purgemac.com, whatever the GitHub check did. Either feed's updates
/// must carry the EdDSA signature `SUPublicEDKey` checks, so the fallback trusts
/// GitHub with nothing new.
///
/// "No update found" is a normal result, never a failure: Sparkle reports it as
/// `SUNoUpdateError` after the appcast has loaded.
nonisolated enum UpdateFeed {
    static let gitHubFallbackURL = "https://raw.githubusercontent.com/jithin-sabu/purge-app/main/appcast.xml"

    /// True while the next check should use `gitHubFallbackURL`.
    static let fallbackPendingKey = "updates.useGitHubFeedForNextCheck"

    // `SUSparkleErrorDomain` and its codes, from Sparkle's SUErrors.h. Kept as
    // values here so the rule can be tested without Sparkle.
    static let sparkleErrorDomain = "SUSparkleErrorDomain"
    static let appcastParseErrorCode = 1000
    static let noUpdateErrorCode = 1001
    static let appcastErrorCode = 1002
    /// Sparkle reports a failed appcast download with this code too, wrapping
    /// the NSURLError, as well as a failed update download.
    static let downloadErrorCode = 2001

    /// nil keeps Info.plist's feed.
    static func feedURLString(fallbackPending: Bool) -> String? {
        fallbackPending ? gitHubFallbackURL : nil
    }

    /// True when the update cycle ended because the appcast couldn't be fetched
    /// or read: a network or server error, or a reply that isn't an appcast. An
    /// error after the appcast loaded, such as no update, a failed update
    /// download or a bad signature, is not the feed's fault. A cancelled request
    /// isn't either.
    static func isFeedLoadFailure(_ error: (any Error)?, appcastLoaded: Bool) -> Bool {
        guard let error, !appcastLoaded else { return false }
        let nsError = error as NSError
        if isCancellation(nsError) { return false }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, isCancellation(underlying) {
            return false
        }
        switch nsError.domain {
        case NSURLErrorDomain:
            return true
        case sparkleErrorDomain:
            return [appcastParseErrorCode, appcastErrorCode, downloadErrorCode].contains(nsError.code)
        default:
            return false
        }
    }

    /// Whether the check after this one should use GitHub. The flag only changes
    /// when a cycle ends, so the value it had then is the feed this check used.
    static func fallbackPendingAfterCheck(usedFallback: Bool, appcastLoaded: Bool, error: (any Error)?) -> Bool {
        !usedFallback && isFeedLoadFailure(error, appcastLoaded: appcastLoaded)
    }

    static func isFallbackPending(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: fallbackPendingKey)
    }

    static func recordFinishedCheck(appcastLoaded: Bool, error: (any Error)?, in defaults: UserDefaults) {
        let pending = fallbackPendingAfterCheck(
            usedFallback: isFallbackPending(in: defaults),
            appcastLoaded: appcastLoaded,
            error: error
        )
        if pending {
            defaults.set(true, forKey: fallbackPendingKey)
        } else {
            defaults.removeObject(forKey: fallbackPendingKey)
        }
    }

    private static func isCancellation(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
