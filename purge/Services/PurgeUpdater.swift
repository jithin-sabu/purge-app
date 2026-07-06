//
//  PurgeUpdater.swift
//  purge
//
//  Wraps Sparkle so a user-initiated "Check for updates" shows a custom
//  "up to date" message. Sparkle bakes its own wording into the framework
//  bundle, so instead of relying on its alert we run a silent probe: if no
//  update is found we present our own message, and if one is available we
//  hand off to Sparkle's standard update UI.
//

import AppKit
import Sparkle

@MainActor
final class PurgeUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var isUserInitiatedCheck = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        isUserInitiatedCheck = true
        controller.updater.checkForUpdateInformation()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard isUserInitiatedCheck else { return }
        isUserInitiatedCheck = false
        // Let Sparkle's standard driver present the real update flow
        // (release notes, download, install & relaunch).
        DispatchQueue.main.async {
            updater.checkForUpdates()
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        guard isUserInitiatedCheck else { return }
        isUserInitiatedCheck = false
        presentNoUpdateAlert(for: error as NSError, host: updater.hostBundle)
    }

    private func presentNoUpdateAlert(for error: NSError, host: Bundle) {
        let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? Int)
            .flatMap { SPUNoUpdateFoundReason(rawValue: OSStatus($0)) }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        switch reason {
        case .onLatestVersion, .onNewerThanLatestVersion, .none:
            let name = (host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (host.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? "Purge"
            let version = host.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            alert.messageText = "You're up to date!"
            alert.informativeText = "\(name) \(version) is currently the latest version available."
        default:
            // Update unavailable for another reason (OS too old/new, unsupported
            // hardware, network failure, …) — surface Sparkle's own description.
            alert.messageText = error.localizedDescription
            if let suggestion = error.localizedRecoverySuggestion, !suggestion.isEmpty {
                alert.informativeText = suggestion
            }
        }

        alert.runModal()
    }
}
