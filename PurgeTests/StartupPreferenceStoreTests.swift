import Foundation
import ServiceManagement
import Testing
@testable import Purge

@MainActor
@Suite("StartupPreferenceStore backs the Startup settings")
struct StartupPreferenceStoreTests {

    private let suite = ThrowawayDefaults()

    /// The switch keeps showing what macOS will do: only an enabled item launches
    /// Purge at login. The check that leaving the menu bar runs counts an item
    /// still awaiting approval as well, since that one is removable (#177).
    @Test("A login item awaiting approval is a login item, though not an enabled one")
    func loginItemAwaitingApprovalStillCounts() {
        #expect(LoginItemRegistrar.hasLoginItem(status: .enabled))
        #expect(LoginItemRegistrar.hasLoginItem(status: .requiresApproval))
        #expect(!LoginItemRegistrar.hasLoginItem(status: .notRegistered))
        #expect(!LoginItemRegistrar.hasLoginItem(status: .notFound))
    }

    private final class FakeLoginItem: LoginItemControlling {
        var isRegistered = false
        /// Registered, but macOS is still waiting for the user to approve it.
        var awaitsApproval = false
        var registerSucceeds = true
        var unregisterSucceeds = true
        private(set) var unregisterCount = 0

        var isRegisteredOrAwaitingApproval: Bool { isRegistered || awaitsApproval }

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
            awaitsApproval = false
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
        let defaults = suite.defaults

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { _ in }
        )

        #expect(!store.hidesDockIcon)
    }

    @Test("Hiding the Dock icon persists and applies in one step")
    func hidingPersistsAndApplies() {
        let defaults = suite.defaults
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
        let defaults = suite.defaults
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
        let defaults = suite.defaults
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
        let defaults = suite.defaults
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
        let defaults = suite.defaults
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
        let fresh = suite.defaults
        StartupPreferenceStore.resolvePersistedModes(isFreshInstall: true, userDefaults: fresh)
        #expect(fresh.object(forKey: "startup.showMenuBarIcon") as? Bool == false)

        let updatedSuite = ThrowawayDefaults()
        defer { updatedSuite.remove() }
        let updated = updatedSuite.defaults
        StartupPreferenceStore.resolvePersistedModes(isFreshInstall: false, userDefaults: updated)
        #expect(updated.object(forKey: "startup.showMenuBarIcon") as? Bool == true)
    }

    /// Runs on every launch, so it must never undo the user's choice.
    @Test("A chosen mode survives later launches")
    func resolutionKeepsTheChoice() {
        let defaults = suite.defaults
        defaults.set(false, forKey: "startup.showMenuBarIcon")

        StartupPreferenceStore.resolvePersistedModes(isFreshInstall: false, userDefaults: defaults)

        #expect(!StartupPreferenceStore.persistedShowsMenuBarIcon(userDefaults: defaults))
    }

    @Test("A hidden Dock icon without the menu bar icon is repaired at launch")
    func resolutionRepairsAnUnreachableApp() {
        let defaults = suite.defaults
        defaults.set(false, forKey: "startup.showMenuBarIcon")
        defaults.set(true, forKey: "startup.hideDockIcon")

        StartupPreferenceStore.resolvePersistedModes(isFreshInstall: false, userDefaults: defaults)

        #expect(!StartupPreferenceStore.persistedHidesDockIcon(userDefaults: defaults))
    }

    /// Also the path a ⌘-drag out of the menu bar takes.
    @Test("Leaving the menu bar turns off the login item and brings the Dock icon back")
    func leavingTheMenuBarCleansUp() {
        let defaults = suite.defaults
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

    /// An item macOS is still waiting to approve launches nothing, so the switch
    /// shows Off, but it is a login item all the same: left behind on leaving the
    /// menu bar, it would open a window at every login once approved (#177).
    @Test("Leaving the menu bar also removes a login item awaiting approval")
    func leavingTheMenuBarRemovesAnItemAwaitingApproval() {
        let defaults = suite.defaults
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        let loginItem = FakeLoginItem()
        loginItem.awaitsApproval = true

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: loginItem,
            applyDockPolicy: { _ in }
        )
        #expect(!store.launchesAtLogin)

        store.setShowsMenuBarIcon(false)

        #expect(!store.showsMenuBarIcon)
        #expect(loginItem.unregisterCount == 1)
        #expect(!loginItem.isRegisteredOrAwaitingApproval)
    }

    /// Picks up a login item added in System Settings since the store last looked.
    @Test("Leaving the menu bar re-reads the login item before deciding")
    func leavingTheMenuBarRereadsTheSystem() {
        let defaults = suite.defaults
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
        let defaults = suite.defaults
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
        let defaults = suite.defaults
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
        let defaults = suite.defaults
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

    /// macOS can report the new status item as gone in the same update that
    /// inserts it, when it keeps the item hidden. Leaving the mode then made the
    /// Settings switch snap back off on every click.
    @Test("A removal right after joining the menu bar keeps the mode")
    func removalRightAfterJoiningIsIgnored() {
        let defaults = suite.defaults
        defaults.set(false, forKey: "startup.showMenuBarIcon")
        let clock = Date(timeIntervalSinceReferenceDate: 0)

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { _ in },
            now: { clock }
        )
        store.setShowsMenuBarIcon(true)
        store.statusItemWasRemoved(at: clock + 0.2)

        #expect(store.showsMenuBarIcon)
        #expect(StartupPreferenceStore.persistedShowsMenuBarIcon(userDefaults: defaults))
    }

    @Test("Dragging the icon out later leaves the menu bar")
    func laterRemovalLeavesTheMenuBar() {
        let defaults = suite.defaults
        defaults.set(false, forKey: "startup.showMenuBarIcon")
        let clock = Date(timeIntervalSinceReferenceDate: 0)

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { _ in },
            now: { clock }
        )
        store.setShowsMenuBarIcon(true)
        store.statusItemWasRemoved(at: clock + StartupPreferenceStore.statusItemSettleInterval + 1)

        #expect(!store.showsMenuBarIcon)
        #expect(!StartupPreferenceStore.persistedShowsMenuBarIcon(userDefaults: defaults))
    }

    @Test("A removal right after launch, with the mode saved from before, is ignored")
    func removalRightAfterLaunchIsIgnored() {
        let defaults = suite.defaults
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        defaults.set(true, forKey: "startup.hideDockIcon")
        let launchedAt = Date(timeIntervalSinceReferenceDate: 0)
        var appliedPolicies: [Bool] = []

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { appliedPolicies.append($0) },
            launchedAt: launchedAt
        )
        store.statusItemWasRemoved(at: launchedAt + 3)

        #expect(store.showsMenuBarIcon)
        #expect(store.statusItemIsHidden)
        #expect(appliedPolicies == [false])
        // The Dock comes back for now, but the user's choice is kept.
        #expect(store.hidesDockIcon)
        #expect(StartupPreferenceStore.persistedHidesDockIcon(userDefaults: defaults))
    }

    @Test("Hide Dock icon applies again when the hidden icon is inserted again")
    func reinsertionReappliesTheSavedDockChoice() {
        let defaults = suite.defaults
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        defaults.set(true, forKey: "startup.hideDockIcon")
        let launchedAt = Date(timeIntervalSinceReferenceDate: 0)
        var appliedPolicies: [Bool] = []

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { appliedPolicies.append($0) },
            launchedAt: launchedAt
        )
        store.statusItemWasRemoved(at: launchedAt + 3)
        // A second echo while the item is already hidden changes nothing.
        store.statusItemWasRemoved(at: launchedAt + 3.5)
        store.statusItemWasInserted(at: launchedAt + 20)

        #expect(!store.statusItemIsHidden)
        #expect(store.hidesDockIcon)
        #expect(appliedPolicies == [false, true])
    }

    @Test("A removal long after launch, with the mode saved from before, leaves the menu bar")
    func laterRemovalAfterLaunchLeavesTheMenuBar() {
        let defaults = suite.defaults
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        let launchedAt = Date(timeIntervalSinceReferenceDate: 0)

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { _ in },
            launchedAt: launchedAt
        )
        store.statusItemWasRemoved(at: launchedAt + StartupPreferenceStore.launchSettleInterval + 1)

        #expect(!store.showsMenuBarIcon)
    }

    @Test("Hiding right after the item is inserted again keeps the mode")
    func removalRightAfterReinsertionIsIgnored() {
        let defaults = suite.defaults
        defaults.set(false, forKey: "startup.showMenuBarIcon")
        let clock = Date(timeIntervalSinceReferenceDate: 0)

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { _ in },
            now: { clock }
        )
        store.setShowsMenuBarIcon(true)
        let reinsertedAt = clock + 60
        store.statusItemWasInserted(at: reinsertedAt)
        store.statusItemWasRemoved(at: reinsertedAt + 0.2)

        #expect(store.showsMenuBarIcon)
        #expect(store.statusItemIsHidden)
    }

    @Test("A removal reported before the item last joined is dropped")
    func removalFromBeforeTheLastJoinIsDropped() {
        let defaults = suite.defaults
        defaults.set(false, forKey: "startup.showMenuBarIcon")
        let clock = Date(timeIntervalSinceReferenceDate: 100)

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { _ in },
            now: { clock }
        )
        store.setShowsMenuBarIcon(true)
        store.statusItemWasRemoved(at: clock - 5)

        #expect(store.showsMenuBarIcon)
        #expect(!store.statusItemIsHidden)
    }

    @Test("An insertion handled after the mode was turned off doesn't turn it back on")
    func staleInsertionDoesNotRejoin() {
        let defaults = suite.defaults
        defaults.set(true, forKey: "startup.showMenuBarIcon")

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { _ in }
        )
        store.setShowsMenuBarIcon(false)
        store.statusItemWasInserted(at: Date())

        #expect(!store.showsMenuBarIcon)
        #expect(!StartupPreferenceStore.persistedShowsMenuBarIcon(userDefaults: defaults))
    }

    @Test("A removal reported early but handled late still counts as the insertion echo")
    func lateHandledEchoIsStillIgnored() {
        let defaults = suite.defaults
        defaults.set(false, forKey: "startup.showMenuBarIcon")
        var clock = Date(timeIntervalSinceReferenceDate: 0)

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { _ in },
            now: { clock }
        )
        store.setShowsMenuBarIcon(true)
        let reportedAt = clock + 0.1
        clock += StartupPreferenceStore.statusItemSettleInterval + 5
        store.statusItemWasRemoved(at: reportedAt)

        #expect(store.showsMenuBarIcon)
    }

    @Test("A hidden new icon brings the Dock back and keeps it")
    func hiddenIconKeepsTheDock() {
        let defaults = suite.defaults
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        defaults.set(true, forKey: "startup.hideDockIcon")
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        var appliedPolicies: [Bool] = []

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { appliedPolicies.append($0) },
            now: { clock }
        )
        store.setShowsMenuBarIcon(false)
        store.setShowsMenuBarIcon(true)
        store.statusItemWasRemoved(at: clock + 0.2)
        store.setHidesDockIcon(true)

        #expect(store.showsMenuBarIcon)
        #expect(store.statusItemIsHidden)
        #expect(!store.hidesDockIcon)
        #expect(appliedPolicies.last == false)

        clock += 10
        store.statusItemWasInserted(at: clock)
        store.setHidesDockIcon(true)

        #expect(!store.statusItemIsHidden)
        #expect(store.hidesDockIcon)
    }

    @Test("An echo with the Dock icon hidden shows the Dock again but keeps the choice")
    func echoWithHiddenDockShowsTheDock() {
        let defaults = suite.defaults
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        var appliedPolicies: [Bool] = []

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { appliedPolicies.append($0) },
            now: { clock }
        )
        store.setShowsMenuBarIcon(false)
        store.setShowsMenuBarIcon(true)
        store.setHidesDockIcon(true)
        clock += 0.1
        store.statusItemWasRemoved(at: clock)

        #expect(store.showsMenuBarIcon)
        #expect(appliedPolicies.last == false)
        #expect(store.hidesDockIcon)
        #expect(StartupPreferenceStore.persistedHidesDockIcon(userDefaults: defaults))
    }

    @Test("Leaving the menu bar while the icon is hidden still clears Hide Dock icon")
    func leavingWhileHiddenClearsTheDockChoice() {
        let defaults = suite.defaults
        defaults.set(true, forKey: "startup.showMenuBarIcon")
        defaults.set(true, forKey: "startup.hideDockIcon")
        let launchedAt = Date(timeIntervalSinceReferenceDate: 0)

        let store = StartupPreferenceStore(
            userDefaults: defaults,
            loginItem: FakeLoginItem(),
            applyDockPolicy: { _ in },
            launchedAt: launchedAt
        )
        store.statusItemWasRemoved(at: launchedAt + 3)
        store.setShowsMenuBarIcon(false)

        #expect(!store.showsMenuBarIcon)
        #expect(!store.statusItemIsHidden)
        #expect(!store.hidesDockIcon)
        #expect(!StartupPreferenceStore.persistedHidesDockIcon(userDefaults: defaults))
    }
}
