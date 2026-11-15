import AppKit
import Foundation

/// Adding a folder the uninstaller lists apps from (#99), the same way from
/// every place that offers it: Settings, the hint under the app list, and the
/// Finder service's refusal for an app outside the folders.
@MainActor
enum AppFolderAdding {
    /// Asks for one folder, so a refusal names the folder it is about.
    /// `startingAt` is where the panel opens; it defaults to `/Volumes`.
    static func chooseFolder(startingAt directory: URL? = nil, then add: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory ?? URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose a folder that holds apps. Purge lists every app inside it in the App Uninstaller.")
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            add(folder)
        }
    }

    /// Saves `folder` and tells the store and the watch agent. Returns what to
    /// tell the person when it could not be added, or nil once it is.
    static func add(_ folder: URL, store: PurgeStore) async -> String? {
        let result = await Task.detached(priority: .userInitiated) { AppFolders.add(folder) }.value
        if let refusal = result.refusal { return AppFolderListing.message(for: refusal) }
        if result.saveFailed { return saveFailedMessage }
        store.appFoldersChanged()
        return nil
    }

    static var saveFailedMessage: String {
        String(localized: "Purge couldn\u{2019}t save the folder list. Try again.")
    }

    static var refusalTitle: String {
        String(localized: "Purge can\u{2019}t add that folder")
    }
}
