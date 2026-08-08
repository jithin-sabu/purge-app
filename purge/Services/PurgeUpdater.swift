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

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

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
