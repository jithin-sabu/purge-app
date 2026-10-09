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

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
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
        "Restart to Update to Purge \(version)"
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        // Optional hook; Sparkle clears the session when the update driver finishes.
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
    }
}
