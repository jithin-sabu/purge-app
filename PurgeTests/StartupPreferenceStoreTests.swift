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
        var unregisterSucceeds = true
        private(set) var unregisterCount = 0

        @discardableResult
        func register() -> Bool {
            guard registerSucceeds else { return false }
            isRegistered = true
            return true
        }

        func unregister() {
            unregisterCount += 1
            guard unregisterSucceeds else { return }
            isRegistered = false
        }
    }

    /// Collects what the store asked the dock policy to do.
    private final class DockPolicySpy {
        private(set) var applied: [Bool] = []
        func record(_ hidden: Bool) { applied.append(hidden) }
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
            applyDockPolicy: { _ in }
        )

        #expect(!store.hidesDockIcon)
    }

    @Test("Hiding the Dock icon persists and applies in one step")
    func hidingPersistsAndApplies() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        let policy = DockPolicySpy()

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { policy.record($0) }
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
            applyDockPolicy: { _ in }
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
            applyDockPolicy: { _ in }
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
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        let loginItem = FakeLoginItem()
        loginItem.registerSucceeds = false

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            applyDockPolicy: { _ in }
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
            applyDockPolicy: { _ in }
        )
        let succeeded = store.setLaunchesAtLogin(false)

        #expect(succeeded)
        #expect(!store.launchesAtLogin)
        #expect(loginItem.unregisterCount == 1)
    }

    // MARK: Menu bar mode

    @Test("A new install starts on demand, an update keeps the menu bar")
    func firstLaunchPicksTheMode() {
        let (fresh, freshName) = makeDefaults()
        defer { fresh.removePersistentDomain(forName: freshName) }
        StartupPreferenceStore.resolvePersistedModes(isFreshInstall: true, userDefaults: fresh)
        #expect(fresh.object(forKey: "startup.showMenuBarIcon") as? Bool == false)

        let (updated, updatedName) = makeDefaults()
        defer { updated.removePersistentDomain(forName: updatedName) }
        StartupPreferenceStore.resolvePersistedModes(isFreshInstall: false, userDefaults: updated)
        #expect(updated.object(forKey: "startup.showMenuBarIcon") as? Bool == true)
    }

    /// Runs on every launch, so it must never undo the user's choice.
    @Test("A chosen mode survives later launches")
    func resolutionKeepsTheChoice() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "startup.showMenuBarIcon")

        StartupPreferenceStore.resolvePersistedModes(isFreshInstall: false, userDefaults: defaults)

        #expect(!StartupPreferenceStore.persistedShowsMenuBarIcon(userDefaults: defaults))
    }

    @Test("A hidden Dock icon without the menu bar icon is repaired at launch")
    func resolutionRepairsAnUnreachableApp() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "startup.showMenuBarIcon")
        defaults.set(true, forKey: "startup.hideDockIcon")

        StartupPreferenceStore.resolvePersistedModes(isFreshInstall: false, userDefaults: defaults)

        #expect(!StartupPreferenceStore.persistedHidesDockIcon(userDefaults: defaults))
    }

    /// Also the path a ⌘-drag out of the menu bar takes.
    @Test("Leaving the menu bar turns off the login item and brings the Dock icon back")
    func leavingTheMenuBarCleansUp() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        defaults.set(true, forKey: "startup.hideDockIcon")
        let loginItem = FakeLoginItem()
        loginItem.isRegistered = true
        let policy = DockPolicySpy()

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            applyDockPolicy: { policy.record($0) }
        )
        store.setShowsMenuBarIcon(false)

        #expect(!store.showsMenuBarIcon)
        #expect(!StartupPreferenceStore.persistedShowsMenuBarIcon(userDefaults: defaults))
        #expect(!store.hidesDockIcon)
        #expect(policy.applied == [false])
        #expect(!store.launchesAtLogin)
        #expect(loginItem.unregisterCount == 1)
    }

    /// Picks up a login item added in System Settings since the store last looked.
    @Test("Leaving the menu bar re-reads the login item before deciding")
    func leavingTheMenuBarRereadsTheSystem() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        let loginItem = FakeLoginItem()

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            applyDockPolicy: { _ in }
        )
        loginItem.isRegistered = true
        store.setShowsMenuBarIcon(false)

        #expect(!loginItem.isRegistered)
    }

    @Test("Joining the menu bar leaves the other settings alone")
    func joiningTheMenuBarChangesNothingElse() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let loginItem = FakeLoginItem()
        let policy = DockPolicySpy()

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            applyDockPolicy: { policy.record($0) }
        )
        store.setShowsMenuBarIcon(true)

        #expect(store.showsMenuBarIcon)
        #expect(!store.hidesDockIcon)
        #expect(!store.launchesAtLogin)
        #expect(policy.applied.isEmpty)
        #expect(loginItem.unregisterCount == 0)
    }

    @Test("On demand, the Dock icon cannot be hidden and the login item cannot be turned on")
    func onDemandRefusesUnreachableSettings() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "startup.showMenuBarIcon")
        let loginItem = FakeLoginItem()
        let policy = DockPolicySpy()

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            applyDockPolicy: { policy.record($0) }
        )
        store.setHidesDockIcon(true)
        let registered = store.setLaunchesAtLogin(true)

        #expect(!store.hidesDockIcon)
        #expect(policy.applied.isEmpty)
        #expect(!registered)
        #expect(!loginItem.isRegistered)
    }

    @Test("Leaving the menu bar changes nothing when the login item will not come off")
    func failedUnregisterKeepsTheMenuBar() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        defaults.set(true, forKey: "startup.hideDockIcon")
        let loginItem = FakeLoginItem()
        loginItem.isRegistered = true
        loginItem.unregisterSucceeds = false
        let policy = DockPolicySpy()

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            applyDockPolicy: { policy.record($0) }
        )
        let switched = store.setShowsMenuBarIcon(false)

        #expect(!switched)
        #expect(store.showsMenuBarIcon)
        #expect(StartupPreferenceStore.persistedShowsMenuBarIcon(userDefaults: defaults))
        #expect(store.hidesDockIcon)
        #expect(policy.applied.isEmpty)
        #expect(store.launchesAtLogin)
    }
}
