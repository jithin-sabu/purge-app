import AppKit
import Foundation

/// Keeps the uninstaller's list in step with the folders it reads (#99): a drive
/// plugged in or ejected while Purge runs, and folders added or removed in
/// Settings.
extension PurgeStore {
    /// Watches drives come and go. Called once at launch, never in the test host.
    func startWatchingAppFolderDrives() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.driveMountsChanged() }
            }
        }
        Task { [weak self] in
            let roots = await Task.detached(priority: .utility) { AppFolders.roots() }.value
            self?.lastAppFolderRoots = roots.map(\.path)
        }
    }

    /// An installer disk image mounts and unmounts often and brings no folder of
    /// its own, so the list is scanned again only when one of the folders came
    /// or went: a drive's `Applications` folder, or a folder the user added on
    /// a drive.
    private func driveMountsChanged() {
        Task { [weak self] in
            let roots = await Task.detached(priority: .utility) { AppFolders.roots() }.value
            guard let self else { return }
            let paths = roots.map(\.path)
            guard paths != lastAppFolderRoots else { return }
            lastAppFolderRoots = paths
            rescanAppsForNewFolders()
        }
    }

    /// Called after Settings adds or removes a folder. The watch agent reads the
    /// same list and starts again on it.
    func appFoldersChanged() {
        Task { [weak self] in
            let roots = await Task.detached(priority: .utility) { AppFolders.roots() }.value
            self?.lastAppFolderRoots = roots.map(\.path)
        }
        DistributedNotificationCenter.default().postNotificationName(
            RemovedAppHandoff.appFoldersChangedNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        rescanAppsForNewFolders()
    }

    /// Only when the list was read before: a list nobody opened is read when it
    /// is first shown anyway.
    private func rescanAppsForNewFolders() {
        guard hasCompletedInstalledAppsScan || isScanningInstalledApps else { return }
        requestScan(.apps)
    }
}
