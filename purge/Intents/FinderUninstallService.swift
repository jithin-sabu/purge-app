import AppKit

/// The two ways an app reaches the uninstaller from outside Purge's window:
/// Finder's "Uninstall with Purge" item (a macOS Service, declared under
/// `NSServices` in Info.plist) and a bundle dropped on the Dock icon (the
/// `CFBundleDocumentTypes` entry there, delivered to `application(_:open:)`).
///
/// Both end at `IntentRouter.showUninstaller`, the same route Spotlight's
/// Uninstall an App takes, so the review sheet opens with the app and its
/// leftovers listed and nothing moves until the person confirms there. An app
/// the uninstaller would not list gets an alert instead of an empty list.
@MainActor
enum ExternalUninstallHandler {

    /// Counts requests, so only the newest one shows its result.
    private static var latestRequest = 0

    /// The folder list is read off the main thread: it asks each drive about
    /// its file system, and a drive that is asleep takes a moment to answer.
    /// A slow drive can make an earlier request finish after a later one, so
    /// a request that is no longer the newest is dropped.
    static func handle(urls: [URL]) {
        latestRequest += 1
        let request = latestRequest
        Task {
            let (outcome, canAddFolder) = await Task.detached(priority: .userInitiated) {
                let outcome = ExternalUninstallRequest.resolve(urls: urls)
                guard case .outsideApplications(_, let folder) = outcome else { return (outcome, false) }
                return (outcome, ExternalUninstallRequest.canOfferToAdd(folder: folder))
            }.value
            guard request == latestRequest else { return }
            show(outcome, canAddFolder: canAddFolder, urls: urls)
        }
    }

    private static func show(_ outcome: ExternalUninstallRequest.Outcome, canAddFolder: Bool, urls: [URL]) {
        switch outcome {
        case .uninstall(let appID, let name):
            Task { await IntentRouter.shared.showUninstaller(appID: appID, name: name) }
        case .outsideApplications(_, let folder):
            guard canAddFolder else {
                guard let refusal = outcome.refusalWithoutAddingFolder else { return }
                showRefusal(title: refusal.title, detail: refusal.detail)
                return
            }
            guard let refusal = outcome.refusal else { return }
            offerToAddFolder(folder, title: refusal.title, detail: refusal.detail, urls: urls)
        default:
            guard let refusal = outcome.refusal else { return }
            showRefusal(title: refusal.title, detail: refusal.detail)
        }
    }

    /// An app outside the folders Purge lists: rather than a dead end, the alert
    /// offers to add the folder it is in, and then goes on to the app (#99). A
    /// folder the rules refuse, like a whole drive, says why instead.
    static func offerToAddFolder(_ folder: String, title: String, detail: String, urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Add Folder"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
            if let message = await AppFolderAdding.add(folderURL, store: AppEnvironment.store) {
                showRefusal(title: AppFolderAdding.refusalTitle, detail: message)
                return
            }
            handle(urls: urls)
        }
    }

    /// Also the alert `IntentRouter` shows when the app is not in the list (#176).
    static func showRefusal(title: String, detail: String) {
        // Purge may be hidden, or launched just now for this request, so
        // the alert has to bring it forward or it would show behind Finder.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

/// `NSApp.servicesProvider`. The selector name is the `NSMessage` value in
/// Info.plist, and the system calls it on the main thread with the selection
/// on the pasteboard.
@MainActor
final class FinderUninstallService: NSObject {

    /// The `NSMenuItem` title and `NSMessage` in Info.plist. pbs keys the
    /// service's on/off entry on both (`FinderServicePreference`), so a change
    /// here must be made in the plist too; a test checks they agree.
    nonisolated static let menuTitle = "Uninstall with Purge"
    nonisolated static let message = "uninstallWithPurge"

    @objc func uninstallWithPurge(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        ExternalUninstallHandler.handle(urls: urls)
    }
}

/// macOS caches the Services menu and does not always notice a new service
/// in an app it has already seen, which is the case after a Sparkle update.
/// `NSUpdateDynamicServices()` makes it look again, but it is slow, so it runs
/// once per build rather than on every launch.
enum ServicesMenuRegistration {
    static let defaultsKey = "servicesRegisteredForBuild"

    static func refreshIfNeeded(
        defaults: UserDefaults = .standard,
        build: String = currentBuild
    ) {
        // The unit-test host runs this delegate against the real defaults
        // domain; it must neither rescan the Services menu nor record a build.
        guard !TestHost.isActive() else { return }
        guard shouldRefresh(recorded: defaults.string(forKey: defaultsKey), current: build) else { return }
        NSUpdateDynamicServices()
        defaults.set(build, forKey: defaultsKey)
    }

    nonisolated static func shouldRefresh(recorded: String?, current: String) -> Bool {
        recorded != current
    }

    /// Version and build together, so a rebuilt beta with the same version
    /// string still refreshes.
    static var currentBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
