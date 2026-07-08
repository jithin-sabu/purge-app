//
//  PurgeUpdater.swift
//  purge
//
//  Wraps Sparkle for user-initiated "Check for updates" checks.
//

import AppKit
import Sparkle

@MainActor
final class PurgeUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        // Optional hook; Sparkle clears the session when the update driver finishes.
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
    }
}
