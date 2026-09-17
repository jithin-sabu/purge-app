import Foundation
import Testing
@testable import Purge

@Suite("Orphan leftover detection biases toward keeping data and never flags system paths")
struct OrphanLeftoverScanPolicyTests {

    private func index(_ ids: [String]) -> OrphanLeftoverScanPolicy.InstalledAppIndex {
        OrphanLeftoverScanPolicy.InstalledAppIndex(diskBundleIDs: Set(ids.map { $0.lowercased() }))
    }

    // MARK: Ownership

    /// An installed app owns its own container.
    @Test
    func installedAppOwnsItsBundleID() {
        let installed = index(["com.vendor.app", "com.foo.bar", "org.baz.qux", "a.b", "c.d"])
        #expect(installed.owns(bundleID: "com.vendor.App"))
        #expect(installed.owns(bundleID: "com.vendor.app"))
    }

    /// A helper or extension id is owned whenever its parent app is installed, so
    /// the app's own XPC containers are never mistaken for orphans.
    @Test
    func helperIsOwnedByItsParentApp() {
        let installed = index(["com.vendor.app", "one.two", "three.four", "five.six", "seven.eight"])
        #expect(installed.owns(bundleID: "com.vendor.App.Helper"))
        #expect(installed.owns(bundleID: "com.vendor.App.QuickLook.Extension"))
    }

    /// Sharing only a vendor stem is not ownership: a genuinely removed
    /// `com.vendor.Other` is still orphaned while `com.vendor.App` stays.
    @Test
    func siblingUnderSameVendorIsNotOwned() {
        let installed = index(["com.vendor.app", "one.two", "three.four", "five.six", "seven.eight"])
        #expect(!installed.owns(bundleID: "com.vendor.Other"))
    }

    // MARK: Orphan test guards

    @Test
    func absentOwnerIsOrphan() {
        let installed = index(["com.keep.this", "one.two", "three.four", "five.six", "seven.eight"])
        #expect(OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.gone.App", installed: installed))
    }

    @Test
    func installedOwnerIsNotOrphan() {
        let installed = index(["com.keep.this", "one.two", "three.four", "five.six", "seven.eight"])
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.keep.this", installed: installed))
    }

    /// Apple's own identifiers are never orphaned: macOS keeps system-service
    /// containers whose app never appears in /Applications.
    @Test
    func appleIdentifiersAreNeverOrphaned() {
        let installed = index(["one.two", "three.four", "five.six", "seven.eight", "nine.ten"])
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.apple.Safari", installed: installed))
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.apple.dt.Xcode", installed: installed))
    }

    @Test
    func protectedContainerIdentifiersAreNeverOrphaned() {
        let installed = index(["one.two", "three.four", "five.six", "seven.eight", "nine.ten"])
        // A protected container id (accounts/passkit family) must never surface.
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.apple.Accounts", installed: installed))
    }

    @Test
    func purgeIsNeverItsOwnOrphan() {
        let installed = index(["one.two", "three.four", "five.six", "seven.eight", "nine.ten"])
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "io.getpurge.app", installed: installed))
    }

    @Test
    func emptyBundleIDIsNotOrphan() {
        let installed = index(["one.two", "three.four", "five.six", "seven.eight", "nine.ten"])
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "", installed: installed))
    }

    // MARK: Completeness gate

    @Test
    func tooFewInstalledAppsLooksIncomplete() {
        #expect(!index(["a.b", "c.d"]).looksComplete)
    }

    @Test
    func enoughInstalledAppsLooksComplete() {
        #expect(index(["a.b", "c.d", "e.f", "g.h", "i.j"]).looksComplete)
    }

    /// A root that existed but failed to enumerate leaves the view degraded, so
    /// the scan must not run even with enough apps counted elsewhere.
    @Test
    func unreadableRootLooksIncomplete() {
        let degraded = OrphanLeftoverScanPolicy.InstalledAppIndex(
            diskBundleIDs: Set(["a.b", "c.d", "e.f", "g.h", "i.j"]),
            rootsReadable: false
        )
        #expect(!degraded.looksComplete)
    }

    // MARK: Bundle-id extraction

    @Test
    func bundleIDNamedContainerResolvesToItself() {
        let url = URL(fileURLWithPath: "/tmp/Containers/com.vendor.App", isDirectory: true)
        #expect(OrphanLeftoverScanPolicy.owningBundleIDForContainer(
            at: url, directoryName: "com.vendor.App"
        ) == "com.vendor.App")
    }

    @Test
    func bundleIDNamedApplicationSupportFolderResolvesToItself() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("com.docker.install", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(OrphanLeftoverScanPolicy.applicationSupportBundleID(
            from: "com.docker.install",
            url: url
        ) == "com.docker.install")
    }

    @Test
    func applicationSupportRejectsHumanNamedFolders() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Docker", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(OrphanLeftoverScanPolicy.applicationSupportBundleID(
            from: "Docker",
            url: url
        ) == nil)
    }

    @Test
    func applicationSupportRejectsBundleIDNamedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("com.vendor.App")
        try Data().write(to: url)
        #expect(OrphanLeftoverScanPolicy.applicationSupportBundleID(
            from: "com.vendor.App",
            url: url
        ) == nil)
    }

    /// A UUID-named container is not attributed by name; ownership must come from
    /// metadata (unavailable in a unit test), so this returns nil rather than
    /// treating the UUID as a bundle id.
    @Test
    func uuidNamedContainerIsNotAttributedByName() {
        let uuid = "3654A0C6-DBF7-4FCD-9CC3-3E42F9A94A5D"
        let url = URL(fileURLWithPath: "/tmp/Containers/\(uuid)", isDirectory: true)
        #expect(OrphanLeftoverScanPolicy.owningBundleIDForContainer(
            at: url, directoryName: uuid
        ) == nil)
    }

    @Test
    func groupContainerStripsTeamIdentifier() {
        #expect(OrphanLeftoverScanPolicy.groupContainerBundleID(
            from: "6N38VWS5BX.com.vendor.App"
        ) == "com.vendor.App")
    }

    /// The `group.<name>` form is an app-group identifier shared with installed
    /// apps and their extensions, not an app bundle id, so it is not attributed
    /// by name (it would flag a group an installed app still uses).
    @Test
    func groupContainerRejectsAppGroupPrefix() {
        #expect(OrphanLeftoverScanPolicy.groupContainerBundleID(from: "group.com.vendor.App") == nil)
    }

    @Test
    func groupContainerRejectsUnkeyedName() {
        #expect(OrphanLeftoverScanPolicy.groupContainerBundleID(from: "randomfolder") == nil)
    }

    @Test
    func savedStateStripsSuffix() {
        #expect(OrphanLeftoverScanPolicy.savedStateBundleID(
            from: "com.vendor.App.savedState"
        ) == "com.vendor.App")
        #expect(OrphanLeftoverScanPolicy.savedStateBundleID(from: "com.vendor.App") == nil)
    }

    @Test
    func httpStorageStripsBinaryCookiesSuffix() {
        #expect(OrphanLeftoverScanPolicy.httpStorageBundleID(
            from: "com.vendor.App.binarycookies"
        ) == "com.vendor.App")
        #expect(OrphanLeftoverScanPolicy.httpStorageBundleID(
            from: "com.vendor.App"
        ) == "com.vendor.App")
    }

    // MARK: looksLikeBundleID

    @Test
    func looksLikeBundleIDAcceptsReverseDNS() {
        #expect(OrphanLeftoverScanPolicy.looksLikeBundleID("com.vendor.App"))
        #expect(OrphanLeftoverScanPolicy.looksLikeBundleID("org.mozilla.firefox"))
    }

    @Test
    func looksLikeBundleIDRejectsUUIDAndSingleWordAndLeadingDigit() {
        #expect(!OrphanLeftoverScanPolicy.looksLikeBundleID("3654A0C6-DBF7-4FCD-9CC3-3E42F9A94A5D"))
        #expect(!OrphanLeftoverScanPolicy.looksLikeBundleID("Rectangle"))
        #expect(!OrphanLeftoverScanPolicy.looksLikeBundleID("9to5.mac"))
        #expect(!OrphanLeftoverScanPolicy.looksLikeBundleID("com..App"))
    }

    // MARK: Staleness

    @Test
    func showAllKeepsMinimumSafetyWindow() {
        let defaults = UserDefaults(suiteName: "orphan.tests.showall")!
        defaults.removePersistentDomain(forName: "orphan.tests.showall")
        defaults.set(DevToolsStalenessOption.showAll.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)
        let days = OrphanLeftoverScanPolicy.effectiveStaleDays(userDefaults: defaults)
        #expect(days == OrphanLeftoverScanPolicy.minimumStaleDaysFloor)
    }

    @Test
    func configuredWindowIsRespectedAboveFloor() {
        let defaults = UserDefaults(suiteName: "orphan.tests.window")!
        defaults.removePersistentDomain(forName: "orphan.tests.window")
        defaults.set(DevToolsStalenessOption.twelveMonths.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)
        #expect(OrphanLeftoverScanPolicy.effectiveStaleDays(userDefaults: defaults) == 365)
    }

    @Test
    func recentlyTouchedIsNotStale() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-24 * 60 * 60)
        #expect(!OrphanLeftoverScanPolicy.isStale(modifiedAt: yesterday, staleDays: 180, now: now))
    }

    @Test
    func longUntouchedIsStale() {
        let now = Date()
        let old = now.addingTimeInterval(-200 * 24 * 60 * 60)
        #expect(OrphanLeftoverScanPolicy.isStale(modifiedAt: old, staleDays: 180, now: now))
    }

    /// An undeterminable date reads as not stale, so an entry Purge cannot date is
    /// left alone rather than offered for removal.
    @Test
    func undeterminableDateIsNotStale() {
        #expect(!OrphanLeftoverScanPolicy.isStale(modifiedAt: .distantPast, staleDays: 180))
    }

    // MARK: Safety mapping

    @Test
    func orphanSafetyIsAlwaysCheckFirst() {
        for category in UninstallCategory.allCases {
            let info = OrphanLeftoverScanPolicy.safetyInfo(appName: "Docker", category: category)
            #expect(info.level == .medium)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrphanLeftoverScanPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
