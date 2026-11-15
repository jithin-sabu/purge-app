import Foundation
import Testing
@testable import Purge

/// Before a leftover is retried from the completion screen, Purge asks again
/// whether an installed app claims it (#174). The clean asked once, before
/// anything moved; the app can be back by the time Retry is pressed.
@Suite("Leftover ownership on retry")
struct LeftoverRetryClaimTests {
    private let home = URL(fileURLWithPath: "/Users/purgetest", isDirectory: true)

    private func app(_ bundleID: String, name: String) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true),
            bundleID: bundleID,
            bundleSizeBytes: 1,
            isRunning: false
        )
    }

    @Test("A preferences file is claimed once its app is installed again")
    func reinstalledAppClaimsItsPreferences() {
        let plist = home.appendingPathComponent("Library/Preferences/com.example.purge-tests.plist")
        let example = app("com.example.purge-tests", name: "Example")
        let other = app("com.other.purge-tests", name: "Other")

        #expect(PurgeStore.appClaimingLeftover(at: plist, among: [other], appGroupClaims: AppGroupClaims(), home: home) == nil)
        #expect(PurgeStore.appClaimingLeftover(at: plist, among: [other, example], appGroupClaims: AppGroupClaims(), home: home)?.id == example.id)
    }

    @Test("A support folder named after an installed app is claimed by it")
    func installedAppClaimsSupportFolderByName() {
        let support = home.appendingPathComponent("Library/Application Support/Example", isDirectory: true)
        let example = app("com.example.purge-tests", name: "Example")

        #expect(PurgeStore.appClaimingLeftover(at: support, among: [example], appGroupClaims: AppGroupClaims(), home: home)?.id == example.id)
    }

    @Test("A Large Files row is never a leftover, whatever is installed")
    func downloadsFileHasNoClaimant() {
        let iso = home.appendingPathComponent("Downloads/Example.iso")
        let example = app("com.example.purge-tests", name: "Example")

        #expect(AppUninstallScanPolicy.leftoverCategory(for: iso, home: home) == nil)
        #expect(PurgeStore.appClaimingLeftover(at: iso, among: [example], appGroupClaims: AppGroupClaims(), home: home) == nil)
    }

    @Test("Leftover roots map to their category, and a root itself to none")
    func leftoverCategoryFollowsTheRoot() {
        let prefs = home.appendingPathComponent("Library/Preferences/com.example.purge-tests.plist")
        let group = home.appendingPathComponent("Library/Group Containers/ABC123.group.example", isDirectory: true)
        let root = home.appendingPathComponent("Library/Preferences", isDirectory: true)

        #expect(AppUninstallScanPolicy.leftoverCategory(for: prefs, home: home) == .preferences)
        #expect(AppUninstallScanPolicy.leftoverCategory(for: group, home: home) == .groupContainers)
        #expect(AppUninstallScanPolicy.leftoverCategory(for: root, home: home) == nil)
    }

    @Test("The bundle id a leftover is named after")
    func bundleIDNaming() {
        let prefs = home.appendingPathComponent("Library/Preferences/com.example.purge-tests.plist")
        let container = home.appendingPathComponent("Library/Containers/com.example.purge-tests", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support/Example", isDirectory: true)
        let group = home.appendingPathComponent("Library/Group Containers/ABC123.group.example", isDirectory: true)

        #expect(PurgeStore.bundleIDNaming(prefs, category: .preferences) == "com.example.purge-tests")
        #expect(PurgeStore.bundleIDNaming(container, category: .containers) == "com.example.purge-tests")
        #expect(PurgeStore.bundleIDNaming(support, category: .applicationSupport) == nil)
        #expect(PurgeStore.bundleIDNaming(group, category: .groupContainers) == nil)
    }
}
