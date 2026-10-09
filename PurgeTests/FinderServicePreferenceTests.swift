import Foundation
import Testing
@testable import Purge

/// The Settings switch for Finder's "Uninstall with Purge" writes the entry
/// System Settings writes into the pbs preferences. These drive it against a
/// throwaway suite, never the real `pbs` domain.
@MainActor
@Suite("Finder service switch")
struct FinderServicePreferenceTests {
    private let suite = ThrowawayDefaults()
    private let key = FinderServicePreference.statusKey(bundleID: "io.getpurge.app")

    private final class FlushCounter {
        var count = 0
        var succeeds = true
    }

    private func makePreference(flushes: FlushCounter = FlushCounter()) -> FinderServicePreference {
        FinderServicePreference(defaults: suite.defaults, statusKey: key, flush: {
            flushes.count += 1
            return flushes.succeeds
        })
    }

    @Test("The entry is keyed the way pbs keys it")
    func statusKeyFormat() {
        #expect(key == "io.getpurge.app - Uninstall with Purge - uninstallWithPurge")
    }

    @Test("The constants match the service in Info.plist")
    func constantsMatchInfoPlist() throws {
        // The test host is Purge itself, so this is the shipped plist.
        let services = try #require(Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]])
        let service = try #require(services.first { $0["NSMessage"] as? String == FinderUninstallService.message })
        let item = try #require(service["NSMenuItem"] as? [String: Any])
        #expect(item["default"] as? String == FinderUninstallService.menuTitle)
        #expect(service["NSSendFileTypes"] as? [String] == ["com.apple.application-bundle"])
    }

    @Test("No entry means off, which is macOS's default for an app service")
    func noEntryIsOff() {
        #expect(!FinderServicePreference.isEnabled(in: nil, key: key))
        #expect(!FinderServicePreference.isEnabled(in: ["other - X - y": ["enabled_context_menu": true]], key: key))
        #expect(!makePreference().isEnabled)
    }

    @Test("An entry's context-menu flag decides")
    func entryFlagDecides() {
        #expect(FinderServicePreference.isEnabled(in: [key: ["enabled_context_menu": true]], key: key))
        #expect(!FinderServicePreference.isEnabled(in: [key: ["enabled_context_menu": false]], key: key))
        #expect(!FinderServicePreference.isEnabled(in: [key: [:]], key: key))
    }

    @Test("Turning it on writes both menus, flushes, and reads back on")
    func turnOn() async {
        let flushes = FlushCounter()
        let preference = makePreference(flushes: flushes)

        await preference.setEnabled(true)

        #expect(preference.isEnabled)
        #expect(flushes.count == 1)
        #expect(!preference.flushFailed)
        #expect(!preference.isApplying)
        let entry = suite.defaults.dictionary(forKey: "NSServicesStatus")?[key] as? [String: Any]
        #expect(entry?["enabled_context_menu"] as? Bool == true)
        #expect(entry?["enabled_services_menu"] as? Bool == true)
        let modes = entry?["presentation_modes"] as? [String: Bool]
        #expect(modes == ["ContextMenu": true, "ServicesMenu": true])
    }

    @Test("Turning it off writes false rather than removing the entry")
    func turnOff() async {
        let preference = makePreference()
        await preference.setEnabled(true)

        await preference.setEnabled(false)

        #expect(!preference.isEnabled)
        let entry = suite.defaults.dictionary(forKey: "NSServicesStatus")?[key] as? [String: Any]
        #expect(entry?["enabled_context_menu"] as? Bool == false)
        #expect(entry?["enabled_services_menu"] as? Bool == false)
    }

    @Test("Other services' entries are left as they were")
    func otherEntriesKept() async {
        let terminal = "com.apple.Terminal - New Terminal at Folder - newTerminalAtFolder"
        suite.defaults.set([terminal: ["enabled_context_menu": true, "enabled_services_menu": false]], forKey: "NSServicesStatus")
        let preference = makePreference()

        await preference.setEnabled(true)

        let status = suite.defaults.dictionary(forKey: "NSServicesStatus")
        #expect(status?.count == 2)
        let kept = status?[terminal] as? [String: Any]
        #expect(kept?["enabled_context_menu"] as? Bool == true)
        #expect(kept?["enabled_services_menu"] as? Bool == false)
    }

    @Test("A failed flush keeps the saved setting but says Finder may lag")
    func flushFailureIsReported() async {
        let flushes = FlushCounter()
        flushes.succeeds = false
        let preference = makePreference(flushes: flushes)

        await preference.setEnabled(true)

        #expect(preference.flushFailed)
        #expect(preference.isEnabled)
        let entry = suite.defaults.dictionary(forKey: "NSServicesStatus")?[key] as? [String: Any]
        #expect(entry?["enabled_context_menu"] as? Bool == true)

        // The next flush that works clears the warning.
        flushes.succeeds = true
        await preference.setEnabled(false)
        #expect(!preference.flushFailed)
        #expect(!preference.isEnabled)
    }

    @Test("A change made in System Settings shows after a refresh")
    func refreshPicksUpOutsideChange() {
        let preference = makePreference()
        #expect(!preference.isEnabled)

        suite.defaults.set([key: FinderServicePreference.entry(enabled: true)], forKey: "NSServicesStatus")
        preference.refresh()

        #expect(preference.isEnabled)
    }
}
