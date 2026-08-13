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
    /// A closure rather than a protocol: one call, one argument, no state — a
    /// protocol plus a wrapper struct would be more names than behaviour.
    private let applyDockPolicy: @MainActor (Bool) -> Void

    @Published private(set) var hidesDockIcon: Bool

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

    func setHidesDockIcon(_ hidden: Bool) {
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
