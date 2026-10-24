import Foundation

/// An app handed to Purge from outside its window: Finder's "Uninstall with
/// Purge" service, or a bundle dropped on the Dock icon. Works out whether the
/// uninstaller can take it, and if not, what to tell the person.
///
/// The checks mirror what the App Uninstaller lists: app bundles in
/// `/Applications` or `~/Applications` at any depth but never inside another
/// app or package, never Apple's apps under `/System`, and never Purge itself.
/// An app that passes here is one the uninstaller would list, but the list this
/// session holds may predate it, so `IntentRouter` looks again when the app is
/// missing and says so if it still cannot find it (#176).
nonisolated enum ExternalUninstallRequest {

    enum Outcome: Equatable {
        /// Open the uninstaller on this app. `appID` is `InstalledApp.id`.
        case uninstall(appID: String, name: String)
        /// Nothing in the selection was an app bundle.
        case noApp
        /// Finder sent several apps; the uninstaller takes one at a time from there.
        case severalApps(count: Int)
        /// Outside the folders the uninstaller lists.
        case outsideApplications(name: String)
        /// Inside an app folder, but within another app or package, so the
        /// uninstaller does not list it on its own.
        case insideAnotherApp(name: String)
        /// An Apple app under `/System`.
        case appleApp(name: String)
        /// Purge itself.
        case purgeItself

        /// What to show when the request is turned down. Nil for `uninstall`.
        var refusal: (title: String, detail: String)? {
            switch self {
            case .uninstall:
                return nil
            case .noApp:
                return (
                    String(localized: "Choose an app to uninstall"),
                    String(localized: "Purge uninstalls apps. Select an app in Finder and try again.")
                )
            case .severalApps:
                return (
                    String(localized: "Choose one app"),
                    String(localized: "Purge uninstalls one app at a time from Finder. To remove several at once, tick them in Purge's App Uninstaller.")
                )
            case .outsideApplications(let name):
                return (
                    String(localized: "\(name) is outside the Applications folder"),
                    String(localized: "Purge's App Uninstaller lists apps in /Applications and in the Applications folder of your home folder. Move \(name) there first, or drag it to the Trash yourself.")
                )
            case .insideAnotherApp(let name):
                return (
                    String(localized: "\(name) is part of another app"),
                    String(localized: "\(name) is inside another app or package, so Purge does not list it on its own. To remove it, uninstall the app it belongs to.")
                )
            case .appleApp(let name):
                return (
                    String(localized: "\(name) is part of macOS"),
                    String(localized: "Purge never removes Apple's built-in apps.")
                )
            case .purgeItself:
                return (
                    String(localized: "Purge cannot uninstall itself"),
                    String(localized: "To remove Purge, drag it from the Applications folder to the Trash.")
                )
            }
        }
    }

    /// Checks the dropped or selected items in order: there must be exactly
    /// one app bundle, it must not be protected, and it must live where the
    /// uninstaller looks. Non-app items in the selection are ignored, so an app
    /// picked together with a stray file still goes through.
    static func resolve(
        urls: [URL],
        roots: [URL] = AppUninstallScanPolicy.installedAppRoots(),
        purgeBundleIDs: Set<String> = AppUninstallScanPolicy.protectedBundleIDs,
        readInfo: (URL) -> [String: Any] = readInfoPlist
    ) -> Outcome {
        let apps = urls.filter { $0.isFileURL && $0.pathExtension == "app" }
        guard let bundleURL = apps.first else { return .noApp }
        guard apps.count == 1 else { return .severalApps(count: apps.count) }

        let info = readInfo(bundleURL)
        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = displayName(for: bundleURL, info: info)
        let path = bundleURL.standardizedFileURL.path

        if let bundleID, purgeBundleIDs.contains(bundleID) { return .purgeItself }
        // Also sees through `/Applications/Safari.app`, a symlink into the
        // system cryptex.
        if AppUninstallScanPolicy.isProtectedApp(bundleURL: bundleURL, bundleID: bundleID) {
            return .appleApp(name: name)
        }
        let rootPaths = roots.map { $0.standardizedFileURL.path }
        guard rootPaths.contains(where: { path.hasPrefix($0 + "/") }) else {
            return .outsideApplications(name: name)
        }
        // The same reach the uninstaller's list uses (`AppBundleReach`).
        guard AppBundleReach.folderDepth(ofAppAtPath: path, roots: rootPaths) != nil else {
            return .insideAnotherApp(name: name)
        }
        return .uninstall(appID: path, name: name)
    }

    /// The same uncached read `ApplicationsFolderWatcher` uses.
    static func readInfoPlist(at bundleURL: URL) -> [String: Any] {
        AppBundleReach.readInfoPlist(at: bundleURL)
    }

    private static func displayName(for bundleURL: URL, info: [String: Any]) -> String {
        [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
            ?? bundleURL.deletingPathExtension().lastPathComponent
    }
}
