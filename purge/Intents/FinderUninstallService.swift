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

    static func handle(urls: [URL]) {
        let outcome = ExternalUninstallRequest.resolve(urls: urls)
        switch outcome {
        case .uninstall(let appID, let name):
            Task { await IntentRouter.shared.showUninstaller(appID: appID, name: name) }
        default:
            guard let refusal = outcome.refusal else { return }
            // Purge may be hidden, or launched just now for this request, so
            // the alert has to bring it forward or it would show behind Finder.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = refusal.title
            alert.informativeText = refusal.detail
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
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
