import AppKit
import CoreServices

/// Tells a login launch apart from the user opening Purge themselves.
///
/// The distinction is the whole reason menu-bar-only mode is usable: someone
/// running Purge as a background cleaner does not want a window at every login,
/// but double-clicking the app and getting nothing back is worse.
@MainActor
enum LaunchContext {
    private static var cachedLoginItemLaunch: Bool?

    /// Reads the open-application Apple event.
    ///
    /// Must be called during launch — `currentAppleEvent` is only populated while
    /// the event is being dispatched and returns `nil` afterwards. Call it from
    /// both `applicationWillFinishLaunching` and `applicationDidFinishLaunching`
    /// and keep the first positive answer, since which one sees the event varies.
    static func captureLaunchKind() {
        guard cachedLoginItemLaunch != true else { return }
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return }
        cachedLoginItemLaunch = isLoginItemLaunch(event: event)
    }

    /// Defaults to `false` when nothing was captured, which shows the window.
    /// The wrong answer in that direction is a stray window; the wrong answer in
    /// the other direction is an app the user cannot open.
    static var launchedAsLoginItem: Bool {
        cachedLoginItemLaunch ?? false
    }

    /// The one in-process signal available.
    ///
    /// This flag predates `SMAppService` — it was built for the LaunchServices era
    /// of login items — and is not part of the modern contract. Under
    /// `SMAppService.mainApp` the app is started by `launchd`, and whether the
    /// flag rides along varies. Treat a miss as a normal launch.
    static func isLoginItemLaunch(event: NSAppleEventDescriptor?) -> Bool {
        guard let event else { return false }
        guard event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == AEKeyword(keyAELaunchedAsLogInItem)
    }

    /// Every term has to hold before the app starts windowless.
    ///
    /// `hasCompletedOnboarding` is not incidental: without it, a fresh install
    /// that somehow carried the preference would come up as a menu bar icon and
    /// never onboard, with no way to grant Full Disk Access.
    static func shouldSuppressInitialWindow(
        hidesDockIcon: Bool,
        launchedAsLoginItem: Bool,
        hasCompletedOnboarding: Bool
    ) -> Bool {
        hidesDockIcon && launchedAsLoginItem && hasCompletedOnboarding
    }
}
