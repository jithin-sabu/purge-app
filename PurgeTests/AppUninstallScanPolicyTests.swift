import Foundation
import Testing
@testable import Purge

@Suite("App uninstall policy matches strictly and protects system apps")
struct AppUninstallScanPolicyTests {
    private var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private func makeApp(
        name: String = "Rectangle",
        bundlePath: String = "/Applications/Rectangle.app",
        bundleID: String? = "com.knollsoft.Rectangle"
    ) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            bundleID: bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )
    }

    // MARK: Protection

    @Test
    func systemAppsAreProtected() {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app", isDirectory: true)
        #expect(AppUninstallScanPolicy.isProtectedApp(bundleURL: calculator, bundleID: "com.apple.calculator"))
    }

    @Test
    func purgeItselfIsProtected() {
        let purge = URL(fileURLWithPath: "/Applications/Purge.app", isDirectory: true)
        #expect(AppUninstallScanPolicy.isProtectedApp(bundleURL: purge, bundleID: "io.getpurge.app"))
    }

    @Test
    func ordinaryAppIsNotProtected() {
        let rectangle = URL(fileURLWithPath: "/Applications/Rectangle.app", isDirectory: true)
        #expect(!AppUninstallScanPolicy.isProtectedApp(bundleURL: rectangle, bundleID: "com.knollsoft.Rectangle"))
    }

    @Test
    func appRootsExcludeSystemApplications() {
        let roots = AppUninstallScanPolicy.installedAppRoots().map(\.path)
        #expect(roots.contains("/Applications"))
        #expect(!roots.contains("/System/Applications"))
    }

    // MARK: Bundle-id anchored matches score safe

    @Test
    func preferencesPlistMatchesByBundleID() {
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "com.knollsoft.Rectangle.plist",
            category: .preferences,
            app: makeApp()
        )
        #expect(reason == .bundleID)
        #expect(reason?.isHighConfidence == true)
    }

    @Test
    func containerFolderMatchesByBundleID() {
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "com.knollsoft.Rectangle",
            category: .containers,
            app: makeApp()
        )
        #expect(reason == .bundleID)
    }

    @Test
    func helperLaunchAgentMatchesByBundleID() {
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "com.knollsoft.Rectangle.helper.plist",
            category: .launchAgents,
            app: makeApp()
        )
        #expect(reason == .bundleID)
    }

    @Test
    func savedStateMatchesByBundleID() {
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "com.knollsoft.Rectangle.savedState",
            category: .savedState,
            app: makeApp()
        )
        #expect(reason == .bundleID)
    }

    @Test
    func groupContainerMatchesByStem() {
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "9XXXXXXXXX.com.knollsoft.rectangle",
            category: .groupContainers,
            app: makeApp()
        )
        #expect(reason == .groupID)
    }

    // MARK: Name-only matches score medium

    @Test
    func applicationSupportFolderMatchesByName() {
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "Rectangle",
            category: .applicationSupport,
            app: makeApp()
        )
        #expect(reason == .appName)
        #expect(reason?.isHighConfidence == false)
    }

    // MARK: The false-positive guard

    /// Uninstalling one Google app must not sweep in a shared vendor folder.
    @Test
    func unrelatedVendorFolderDoesNotMatchByName() {
        let chrome = makeApp(
            name: "Google Chrome",
            bundlePath: "/Applications/Google Chrome.app",
            bundleID: "com.google.Chrome"
        )
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "Google",
            category: .applicationSupport,
            app: chrome
        )
        #expect(reason == nil)
    }

    /// A different app's bundle-id keyed cache is not the chosen app's.
    @Test
    func differentBundleIDDoesNotMatch() {
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "com.apple.Safari",
            category: .caches,
            app: makeApp()
        )
        #expect(reason == nil)
    }

    /// Preferences are only ever bundle-id keyed, so a name-equal plist folder is
    /// not treated as a name match.
    @Test
    func preferencesDoNotMatchByName() {
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "Rectangle",
            category: .preferences,
            app: makeApp()
        )
        #expect(reason == nil)
    }

    @Test
    func shortBundleIDStemDoesNotMatchGroupContainer() {
        // A two-letter final segment must not match a group container loosely.
        let app = makeApp(bundleID: "com.x.io")
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "TEAMID.some.other.io.thing",
            category: .groupContainers,
            app: app
        )
        #expect(reason == nil)
    }

    // MARK: Delete-boundary gate

    @Test
    func appBundleInApplicationsIsEligible() {
        let url = URL(fileURLWithPath: "/Applications/Rectangle.app", isDirectory: true)
        #expect(AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }

    @Test
    func leftoverUnderLibraryIsEligible() {
        let url = home.appendingPathComponent("Library/Preferences/com.knollsoft.Rectangle.plist")
        #expect(AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }

    @Test
    func libraryRootItselfIsNotEligible() {
        let url = home.appendingPathComponent("Library/Caches")
        #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }

    @Test
    func randomDocumentIsNotEligible() {
        let url = home.appendingPathComponent("Documents/notes.txt")
        #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }

    @Test
    func systemPathIsNotEligible() {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app", isDirectory: true)
        #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }

    @Test
    func bareAppBundleOutsideAppRootsIsNotEligible() {
        let url = home.appendingPathComponent("Downloads/Something.app")
        #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }
}
