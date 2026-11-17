import AppKit
import Foundation

/// Adding a folder Large Files and Developer Projects walk too (#318), from Settings.
@MainActor
enum ScanFolderAdding {
    /// Asks for one folder, so a refusal names the folder it is about. Opens
    /// at `/Volumes`, where most of these folders are.
    static func chooseFolder(then add: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose a drive or folder to scan too.")
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            add(folder)
        }
    }

    /// Saves `folder` and tells the store. Returns what to tell the person when
    /// it could not be added, or nil once it is.
    static func add(_ folder: URL, store: PurgeStore) async -> String? {
        let result = await Task.detached(priority: .userInitiated) { ScanFolders.add(folder) }.value
        if let refusal = result.refusal { return message(for: refusal) }
        if result.saveFailed { return AppFolderAdding.saveFailedMessage }
        store.scanFoldersChanged()
        return nil
    }

    /// What Settings says when a folder can't be added, or why a saved one is
    /// not walked now.
    nonisolated static func message(for refusal: AppFolders.Refusal) -> String {
        switch refusal {
        case .notAFolder:
            String(localized: "That folder can\u{2019}t be found. If it\u{2019}s on a drive, connect the drive.")
        case .outsideHomeAndDrives:
            String(localized: "Choose a folder in your home folder or on a drive.")
        case .tooBroad:
            String(localized: "Choose a folder or a drive, not your home folder.")
        case .insideLibraryOrBundle:
            String(localized: "Purge doesn\u{2019}t scan Library, hidden folders, or the inside of apps and packages.")
        case .throughLink:
            String(localized: "That folder is reached through an alias or link. Choose the folder it leads to.")
        case .notOnWritableLocalDisk:
            String(localized: "Purge only scans drives attached to this Mac that it can move files on, not network, cloud or read-only drives.")
        case .holdsWholeDisk:
            String(localized: "That folder holds a copy of a Mac, a home folder or a Time Machine backup, or is inside one.")
        case .syncs:
            String(localized: "That folder syncs with iCloud Drive or another service, so moving a file from it to the Trash would remove it from your other devices too.")
        case .alreadyIncluded:
            String(localized: "Purge already scans that folder.")
        case .holdsAnotherFolder:
            String(localized: "That folder holds one Purge already scans.")
        }
    }
}
