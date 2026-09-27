import Combine
import Foundation

/// Seam over `SMAppService` so the store can be tested without touching the
/// real login-item database.
@MainActor
protocol LoginItemControlling {
    var isRegistered: Bool { get }
    @discardableResult func register() -> Bool
    func unregister()
}

struct SystemLoginItem: LoginItemControlling {
    /// `nonisolated` so it can be a default argument, which Swift evaluates
    /// outside the caller's actor.
    nonisolated init() {}

    var isRegistered: Bool { LoginItemRegistrar.isRegistered }

    @discardableResult
    func register() -> Bool { LoginItemRegistrar.register() }

    func unregister() { LoginItemRegistrar.unregister() }
}

/// Backs the Startup section of Settings: whether Purge stays in the menu bar,
/// and, when it does, launch at login and hiding the Dock icon.
///
/// Purge runs in one of two modes. On demand (the default for new installs), it
/// is a normal app: no menu bar icon, and closing the window quits it. In the
/// menu bar, it keeps running after the window closes, and can start at login
/// and drop its Dock icon. The two sub-settings only exist in the second mode;
/// with no menu bar icon, a hidden Dock icon or a login launch would leave a
/// running app the user has no way to reach.
@MainActor
final class StartupPreferenceStore: ObservableObject {
    static let shared = StartupPreferenceStore()

    private enum UDKeys {
        static let hideDockIcon = "startup.hideDockIcon"
        static let showMenuBarIcon = "startup.showMenuBarIcon"
    }

    /// For `@AppStorage` in the scene, which inserts the status item from it.
    static let showMenuBarIconKey = UDKeys.showMenuBarIcon

    private let ud: UserDefaults
    private let loginItem: LoginItemControlling
    /// A closure rather than a protocol: one call, one argument, no state — a
    /// protocol plus a wrapper struct would be more names than behaviour.
    private let applyDockPolicy: @MainActor (Bool) -> Void

    @Published private(set) var hidesDockIcon: Bool

    /// Persisted. Written once at launch by `resolvePersistedModes` for any
    /// install that has not seen this setting, so it is never missing here.
    @Published private(set) var showsMenuBarIcon: Bool

    /// Mirrors `SMAppService`, and is deliberately **not** persisted. The system
    /// owns this state — the user can turn Purge off in System Settings without
    /// telling us — so a stored copy would only be a second answer to disagree with.
    @Published private(set) var launchesAtLogin: Bool

    init(
        userDefaults: UserDefaults = .standard,
        loginItem: LoginItemControlling = SystemLoginItem(),
        applyDockPolicy: @escaping @MainActor (Bool) -> Void = { DockIconPolicy.apply(hidesDockIcon: $0) }
    ) {
        ud = userDefaults
        self.loginItem = loginItem
        self.applyDockPolicy = applyDockPolicy

        ud.register(defaults: [UDKeys.hideDockIcon: false])
        hidesDockIcon = ud.bool(forKey: UDKeys.hideDockIcon)
        showsMenuBarIcon = ud.bool(forKey: UDKeys.showMenuBarIcon)
        launchesAtLogin = loginItem.isRegistered
    }

    /// Re-reads the system's answer. Call when Settings appears and when the app
    /// becomes active, so a change made in System Settings shows up here.
    /// Guarded against re-publishing an unchanged value: this runs on every app
    /// activation while Settings is open, and `@Published` fires `objectWillChange`
    /// even when the value is identical — which would re-evaluate the whole
    /// settings body for nothing.
    func refreshLoginItemStatus() {
        let current = loginItem.isRegistered
        guard current != launchesAtLogin else { return }
        launchesAtLogin = current
    }

    /// Switches between the two modes.
    ///
    /// Also the landing point when the user ⌘-drags the icon out of the menu bar:
    /// the status item's `isInserted` binding writes here, so that route gets the
    /// same clean-up as the Settings switch. Leaving the menu bar turns off the
    /// login item and brings the Dock icon back, since both only make sense with
    /// an icon to click.
    ///
    /// Returns whether the mode changed. Leaving the menu bar fails, and changes
    /// nothing, when the login item will not come off: on demand with a login item
    /// still registered opens a window at every login, and Settings no longer
    /// shows the row that would fix it.
    @discardableResult
    func setShowsMenuBarIcon(_ shown: Bool) -> Bool {
        guard shown != showsMenuBarIcon else { return true }
        if !shown {
            // Re-read rather than trusting `launchesAtLogin`: the user may have
            // added Purge in System Settings since Settings last refreshed.
            if loginItem.isRegistered, !setLaunchesAtLogin(false) {
                return false
            }
            if hidesDockIcon {
                setHidesDockIcon(false)
            }
        }
        showsMenuBarIcon = shown
        ud.set(shown, forKey: UDKeys.showMenuBarIcon)
        return true
    }

    func setHidesDockIcon(_ hidden: Bool) {
        // No menu bar icon and no Dock icon is an app nobody can reach.
        guard !hidden || showsMenuBarIcon else { return }
        hidesDockIcon = hidden
        ud.set(hidden, forKey: UDKeys.hideDockIcon)
        applyDockPolicy(hidden)
    }

    /// Returns whether the login item ended up in the requested state.
    ///
    /// Registration can fail (a managed Mac, a damaged bundle), so the published
    /// value comes from re-reading the system rather than from what was asked for
    /// — a failed toggle snaps back instead of lying.
    @discardableResult
    func setLaunchesAtLogin(_ enabled: Bool) -> Bool {
        // A login launch in on-demand mode would open a window at every login,
        // which is the opposite of what someone who picked that mode wants.
        guard !enabled || showsMenuBarIcon else { return false }
        if enabled {
            loginItem.register()
        } else {
            loginItem.unregister()
        }
        launchesAtLogin = loginItem.isRegistered
        return launchesAtLogin == enabled
    }

    /// The persisted preference, readable before any store exists.
    ///
    /// The launch path needs this in `PurgeApp.init()`, early enough that the app
    /// never flashes into the Dock before hiding itself again.
    static func persistedHidesDockIcon(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: UDKeys.hideDockIcon)
    }

    /// The persisted mode, readable before any store exists. Building the store
    /// asks `SMAppService` for its status, an out-of-process call the launch path
    /// and the window-close check have no use for.
    static func persistedShowsMenuBarIcon(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: UDKeys.showMenuBarIcon)
    }

    /// Settles the mode once per launch, before anything reads it.
    ///
    /// The first launch of a build with this setting has to pick a mode.
    /// A new install starts on demand. Anyone updating already had the menu bar
    /// icon, and possibly a login item and a hidden Dock icon that depend on it,
    /// so they keep the menu bar. `isFreshInstall` comes from `FirstRunGate`,
    /// which is the one place that can tell those two apart.
    ///
    /// Also repairs a hidden Dock icon without the menu bar icon, whatever wrote
    /// it, so the launch never applies an unreachable combination.
    static func resolvePersistedModes(isFreshInstall: Bool, userDefaults: UserDefaults = .standard) {
        if userDefaults.object(forKey: UDKeys.showMenuBarIcon) == nil {
            userDefaults.set(!isFreshInstall, forKey: UDKeys.showMenuBarIcon)
        }
        if !userDefaults.bool(forKey: UDKeys.showMenuBarIcon),
           userDefaults.bool(forKey: UDKeys.hideDockIcon) {
            userDefaults.set(false, forKey: UDKeys.hideDockIcon)
        }
    }
}
