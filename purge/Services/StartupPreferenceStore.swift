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

@MainActor
protocol DockIconPolicyApplying {
    func apply(hidesDockIcon: Bool)
}

struct SystemDockIconPolicy: DockIconPolicyApplying {
    nonisolated init() {}

    func apply(hidesDockIcon: Bool) {
        DockIconPolicy.apply(hidesDockIcon: hidesDockIcon)
    }
}

/// Backs the Startup section of Settings: launch at login, and whether Purge
/// lives in the menu bar only.
@MainActor
final class StartupPreferenceStore: ObservableObject {
    static let shared = StartupPreferenceStore()

    private enum UDKeys {
        static let hideDockIcon = "startup.hideDockIcon"
    }

    private let ud: UserDefaults
    private let loginItem: LoginItemControlling
    private let dockPolicy: DockIconPolicyApplying

    @Published private(set) var hidesDockIcon: Bool

    /// Mirrors `SMAppService`, and is deliberately **not** persisted. The system
    /// owns this state — the user can turn Purge off in System Settings without
    /// telling us — so a stored copy would only be a second answer to disagree with.
    @Published private(set) var launchesAtLogin: Bool

    init(
        userDefaults: UserDefaults = .standard,
        loginItem: LoginItemControlling = SystemLoginItem(),
        dockPolicy: DockIconPolicyApplying = SystemDockIconPolicy()
    ) {
        ud = userDefaults
        self.loginItem = loginItem
        self.dockPolicy = dockPolicy

        ud.register(defaults: [UDKeys.hideDockIcon: false])
        hidesDockIcon = ud.bool(forKey: UDKeys.hideDockIcon)
        launchesAtLogin = loginItem.isRegistered
    }

    /// Re-reads the system's answer. Call when Settings appears and when the app
    /// becomes active, so a change made in System Settings shows up here.
    func refreshLoginItemStatus() {
        launchesAtLogin = loginItem.isRegistered
    }

    func setHidesDockIcon(_ hidden: Bool) {
        hidesDockIcon = hidden
        ud.set(hidden, forKey: UDKeys.hideDockIcon)
        dockPolicy.apply(hidesDockIcon: hidden)
    }

    /// Returns whether the login item ended up in the requested state.
    ///
    /// Registration can fail (a managed Mac, a damaged bundle), so the published
    /// value comes from re-reading the system rather than from what was asked for
    /// — a failed toggle snaps back instead of lying.
    @discardableResult
    func setLaunchesAtLogin(_ enabled: Bool) -> Bool {
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
}
