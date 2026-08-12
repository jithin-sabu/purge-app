import Foundation
import Testing
@testable import Purge

@MainActor
@Suite("StartupPreferenceStore backs the Startup settings")
struct StartupPreferenceStoreTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "io.getpurge.tests.startup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private final class FakeLoginItem: LoginItemControlling {
        var isRegistered = false
        var registerSucceeds = true
        private(set) var unregisterCount = 0

        @discardableResult
        func register() -> Bool {
            guard registerSucceeds else { return false }
            isRegistered = true
            return true
        }

        func unregister() {
            unregisterCount += 1
            isRegistered = false
        }
    }

    private final class SpyDockPolicy: DockIconPolicyApplying {
        private(set) var applied: [Bool] = []
        func apply(hidesDockIcon: Bool) { applied.append(hidesDockIcon) }
    }

    /// Guards the promise that this feature changes nothing for anyone who does
    /// not go looking for it.
    @Test("A fresh install keeps the Dock icon")
    func defaultsToShowingTheDockIcon() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            dockPolicy: SpyDockPolicy()
        )

        #expect(!store.hidesDockIcon)
    }

    @Test("Hiding the Dock icon persists and applies in one step")
    func hidingPersistsAndApplies() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = SpyDockPolicy()

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            dockPolicy: policy
        )
        store.setHidesDockIcon(true)

        #expect(store.hidesDockIcon)
        #expect(defaults.bool(forKey: "startup.hideDockIcon"))
        #expect(policy.applied == [true])
    }

    @Test("The saved preference is read back at launch")
    func storedPreferenceIsRestored() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "startup.hideDockIcon")

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            dockPolicy: SpyDockPolicy()
        )

        #expect(store.hidesDockIcon)
        #expect(StartupPreferenceStore.persistedHidesDockIcon(userDefaults: defaults))
    }

    @Test("Login item state comes from the system, not from a stored copy")
    func loginItemMirrorsTheSystem() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let loginItem = FakeLoginItem()

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            dockPolicy: SpyDockPolicy()
        )
        #expect(!store.launchesAtLogin)

        // Stands in for the user switching Purge off in System Settings.
        loginItem.isRegistered = true
        store.refreshLoginItemStatus()

        #expect(store.launchesAtLogin)
    }

    /// A toggle that stays on after a failed registration is a lie the user acts on.
    @Test("A registration that fails leaves the toggle off")
    func failedRegistrationSnapsBack() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let loginItem = FakeLoginItem()
        loginItem.registerSucceeds = false

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            dockPolicy: SpyDockPolicy()
        )
        let succeeded = store.setLaunchesAtLogin(true)

        #expect(!succeeded)
        #expect(!store.launchesAtLogin)
    }

    @Test("Turning the login item off unregisters and re-reads the system")
    func disablingUnregisters() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let loginItem = FakeLoginItem()
        loginItem.isRegistered = true

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            dockPolicy: SpyDockPolicy()
        )
        let succeeded = store.setLaunchesAtLogin(false)

        #expect(succeeded)
        #expect(!store.launchesAtLogin)
        #expect(loginItem.unregisterCount == 1)
    }
}
