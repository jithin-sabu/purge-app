import AppKit
import Foundation
import ServiceManagement
import UserNotifications

// The real parts behind Uninstall Purge (#330). Each reads its state from macOS,
// never from a saved setting, because the user can change any of them in System
// Settings without telling Purge.

@MainActor
struct DeletedAppsWatcherPart: SelfUninstallPartControl {
    let part = SelfUninstallPart.deletedAppsWatcher

    func isOn(thorough: Bool) async -> Bool {
        let monitor = RemovedAppMonitor.shared
        if monitor.isEnabled || monitor.isAgentRegistered { return true }
        // Unregistered, but launchd may not have stopped the running copy yet.
        return thorough ? await monitor.ownAgentAnswers(within: .seconds(3)) : false
    }

    func turnOff() async {
        await RemovedAppMonitor.shared.turnOffForUninstall()
    }
}

@MainActor
struct AdminHelperPart: SelfUninstallPartControl {
    let part = SelfUninstallPart.adminHelper

    func isOn(thorough: Bool) async -> Bool {
        switch await PrivilegedHelperManager.shared.statusOffMain() {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        @unknown default: return true
        }
    }

    func turnOff() async {
        await PrivilegedHelperPreferenceStore.shared.turnOffForUninstall()
    }
}

@MainActor
struct FinderServicePart: SelfUninstallPartControl {
    let part = SelfUninstallPart.finderService

    func isOn(thorough: Bool) async -> Bool {
        let preference = FinderServicePreference.shared
        preference.refresh()
        return preference.isEnabled
    }

    /// A Settings toggle may still be writing and flushing (up to about five
    /// seconds), and `setEnabled` ignores a call made meanwhile.
    func turnOff() async {
        let preference = FinderServicePreference.shared
        for _ in 0..<40 where preference.isApplying {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await preference.setEnabled(false)
    }
}

@MainActor
struct CleanupReminderPart: SelfUninstallPartControl {
    let part = SelfUninstallPart.cleanupReminder

    /// The notification center applies a removal a moment later, so the check
    /// after turning it off looks a few times before it counts as still there.
    func isOn(thorough: Bool) async -> Bool {
        for attempt in 0..<(thorough ? 5 : 1) {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            if !pending.contains(where: { $0.identifier == ScheduledCleaningRegistrar.repeatingReminderIdentifier }) {
                return false
            }
        }
        return true
    }

    /// Cancels the reminder only. Clean automatically stays as the user set it,
    /// and arms the reminder again if Purge is opened later.
    func turnOff() async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [ScheduledCleaningRegistrar.repeatingReminderIdentifier]
        )
    }
}

@MainActor
struct LoginItemPart: SelfUninstallPartControl {
    let part = SelfUninstallPart.loginItem

    func isOn(thorough: Bool) async -> Bool {
        LoginItemRegistrar.isRegisteredOrAwaitingApproval
    }

    func turnOff() async {
        StartupPreferenceStore.shared.setLaunchesAtLogin(false)
    }
}

/// Moves Purge's files through `SelfUninstallPolicy`, off the main thread.
@MainActor
struct LiveSelfUninstallFileMover: SelfUninstallFileMover {
    var bundleURL = Bundle.main.bundleURL
    var bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
    var home = FileManager.default.homeDirectoryForCurrentUser

    func moveData() async -> SelfUninstallDataMove {
        // Checked again here, right before the move, as well as by the run.
        guard SelfUninstallPolicy.otherCopies(of: bundleURL, bundleIdentifier: bundleIdentifier).isEmpty else {
            return .keptForOtherCopy
        }
        let home = home
        let identifier = bundleIdentifier
        let result = await Task.detached(priority: .userInitiated) { () -> SelfUninstallDataMove in
            let files = FileManager.default
            let folders = SelfUninstallPolicy.dataFolders(home: home, bundleIdentifier: identifier)
                .filter { files.fileExists(atPath: $0.path) }
            // Every folder is checked before any moves.
            guard folders.allSatisfy({
                SelfUninstallPolicy.isOwnDataFolder($0, home: home, bundleIdentifier: identifier)
                    && files.isDeletableFile(atPath: $0.path)
            }) else { return .failed }
            var items = folders.map { SelfUninstallPolicy.DataItem.folder($0) }
            // A copy of the preferences, last, so it can be put back. The domain
            // itself is cleared at quit.
            let preferences = SelfUninstallPolicy.preferencesFile(home: home, bundleIdentifier: identifier)
            if files.fileExists(atPath: preferences.path) { items.append(.copyOf(preferences)) }
            return SelfUninstallPolicy.moveAllOrNothing(
                items,
                trash: { url in
                    var resulting: NSURL?
                    try files.trashItem(at: url, resultingItemURL: &resulting)
                    return resulting as URL?
                },
                copy: { source in
                    let staging = files.temporaryDirectory
                        .appendingPathComponent("purge-uninstall-\(UUID().uuidString)", isDirectory: true)
                    try files.createDirectory(at: staging, withIntermediateDirectories: true)
                    let copy = staging.appendingPathComponent(source.lastPathComponent)
                    try files.copyItem(at: source, to: copy)
                    return copy
                },
                putBack: { trashed, original in try files.moveItem(at: trashed, to: original) }
            )
        }.value
        if result == .moved { SelfUninstallState.defaultsDomainToClear = identifier }
        return result
    }

    func appRefusal() async -> SelfUninstallPolicy.Refusal? {
        let url = bundleURL
        let identifier = bundleIdentifier
        return await Task.detached(priority: .userInitiated) {
            SelfUninstallPolicy.evaluateApp(SelfUninstallPolicy.readFacts(of: url), runningBundleIdentifier: identifier)
        }.value
    }

    func moveApp() async -> SelfUninstallAppMove {
        let url = bundleURL
        let identifier = bundleIdentifier
        return await Task.detached(priority: .userInitiated) { () -> SelfUninstallAppMove in
            let facts = SelfUninstallPolicy.readFacts(of: url)
            if let refusal = SelfUninstallPolicy.evaluateApp(facts, runningBundleIdentifier: identifier) {
                return .refused(refusal)
            }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return .moved
            } catch {
                return .failed
            }
        }.value
    }
}

/// Moves nothing: stands in for the live mover in the unit-test host, which
/// shares the real user's files.
@MainActor
private struct InertSelfUninstallFileMover: SelfUninstallFileMover {
    func moveData() async -> SelfUninstallDataMove { .failed }
    func appRefusal() async -> SelfUninstallPolicy.Refusal? { .notThisApp }
    func moveApp() async -> SelfUninstallAppMove { .refused(.notThisApp) }
}

/// What the quit after Uninstall Purge still has to do.
@MainActor
enum SelfUninstallState {
    /// Set once the data folders went to the Trash, to the bundle ID read before
    /// the app moved. The domain is cleared at quit rather than then: clearing it
    /// while Purge runs would put the window back into onboarding under the sheet.
    static var defaultsDomainToClear: String?

    static var clearsDefaultsOnQuit: Bool { defaultsDomainToClear != nil }

    /// Called from `applicationWillTerminate`. The menu bar icon writes its
    /// state while AppKit tears it down, after this runs, so the domain is
    /// cleared once more at process exit.
    static func finishQuit() {
        guard let identifier = defaultsDomainToClear else { return }
        clearDefaults(identifier)
        domainToClearAtExit = identifier
        atexit {
            guard let identifier = SelfUninstallState.domainToClearAtExit else { return }
            SelfUninstallState.clearDefaults(identifier)
        }
    }

    nonisolated(unsafe) private static var domainToClearAtExit: String?

    nonisolated private static func clearDefaults(_ identifier: String) {
        UserDefaults.standard.removePersistentDomain(forName: identifier)
        CFPreferencesAppSynchronize(identifier as CFString)
    }

    /// AppKit won't quit while a sheet is open: it logs "App termination blocked
    /// by modal sheet" and aborts. So the sheet closes first, and the quit
    /// follows once no window still has one attached (at most two seconds).
    static func quitClosingSheet(_ close: () -> Void) {
        close()
        Task { @MainActor in
            for _ in 0..<40 where NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            NSApp.terminate(nil)
        }
    }
}

extension SelfUninstaller {
    /// The real parts and mover, or none of them in the unit-test host.
    static func live(store: PurgeStore) -> SelfUninstaller {
        let setRunning: (Bool) -> Void = { [weak store] running in
            store?.isUninstallingPurge = running
            if running {
                store?.stopScans()
                store?.holdLastScanWrites()
            } else {
                // Back to normal running: steps asked for meanwhile, and any
                // launch step with no results yet, start now.
                store?.startLaunchScans()
            }
        }
        guard !TestHost.isActive() else {
            return SelfUninstaller(parts: [], mover: InertSelfUninstallFileMover(), setRunning: setRunning)
        }
        return SelfUninstaller(
            parts: [
                DeletedAppsWatcherPart(),
                AdminHelperPart(),
                FinderServicePart(),
                CleanupReminderPart(),
                LoginItemPart()
            ],
            mover: LiveSelfUninstallFileMover(),
            setRunning: setRunning,
            otherCopies: { SelfUninstallPolicy.otherCopies(of: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier ?? "") }
        )
    }
}
