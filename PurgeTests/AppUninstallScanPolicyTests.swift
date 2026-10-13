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

    // MARK: Identity

    /// Xcode and Xcode-beta both carry com.apple.dt.Xcode. Identity keys on the
    /// bundle path so the two never collapse into one ForEach cell (the grid hole).
    @Test
    func appsSharingABundleIDHaveDistinctIdentity() {
        let xcode = makeApp(name: "Xcode", bundlePath: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode")
        let beta = makeApp(name: "Xcode-beta", bundlePath: "/Applications/Xcode-beta.app", bundleID: "com.apple.dt.Xcode")
        #expect(xcode.id != beta.id)
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

    /// The stem must be a whole component: an app whose id ends in `.note` must
    /// not claim a `…​.notes` group container by partial overlap.
    @Test
    func partialStemDoesNotMatchGroupContainer() {
        let app = makeApp(bundleID: "com.vendor.note")
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "TEAMID.com.vendor.notes",
            category: .groupContainers,
            app: app
        )
        #expect(reason == nil)
    }

    /// The full bundle id appearing as a dot-suffix still counts.
    @Test
    func groupContainerMatchesByFullBundleIDSuffix() {
        let reason = AppUninstallScanPolicy.matchReason(
            forLeftoverName: "9XXXXXXXXX.com.knollsoft.Rectangle",
            category: .groupContainers,
            app: makeApp()
        )
        #expect(reason == .groupID)
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

    /// The scanner walks one folder into an app root (vendors that group their
    /// apps, e.g. `/Applications/Utilities/…`), so the delete gate must accept the
    /// same one level. Otherwise a nested app is offered but skipped for safety
    /// when the user confirms.
    @Test
    func appBundleOneLevelInsideAppRootIsEligible() {
        let url = URL(fileURLWithPath: "/Applications/Utilities/Foo.app", isDirectory: true)
        #expect(AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }

    /// Autodesk installs into a vendor folder, then a product folder (#143). The
    /// scanner lists that, so the gate must take it.
    @Test
    func appBundleTwoLevelsInsideAppRootIsEligible() {
        let url = URL(fileURLWithPath: "/Applications/Autodesk/AutoCAD 2026/AutoCAD 2026.app", isDirectory: true)
        #expect(AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }

    /// Two levels only: three folders deep is beyond what the scanner offers and
    /// must stay out of the gate.
    @Test
    func appBundleThreeLevelsInsideAppRootIsNotEligible() {
        let url = URL(fileURLWithPath: "/Applications/A/B/C/Foo.app", isDirectory: true)
        #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }

    /// An app nested in another app's bundle is that app's internals, at any depth.
    @Test
    func appBundleInsideAnotherBundleIsNotEligible() {
        for path in [
            "/Applications/Host.app/Inner.app",
            "/Applications/Host.app/Contents/Inner.app",
            "/Applications/Vendor/Kit.framework/Inner.app",
        ] {
            #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(URL(fileURLWithPath: path, isDirectory: true)))
        }
    }

    @Test
    func appFolderDepthCountsFoldersBelowTheRoot() {
        let roots = ["/Applications", "/Users/x/Applications"]
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/A.app", roots: roots) == 0)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/Utilities/A.app", roots: roots) == 1)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Users/x/Applications/V/P/A.app", roots: roots) == 2)
        // A version number in a folder name is not a bundle extension.
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/Tool 1.2/A.app", roots: roots) == 1)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/V/P/Q/A.app", roots: roots) == nil)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications Old/A.app", roots: roots) == nil)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/Notes.txt", roots: roots) == nil)
    }

    @Test
    func backgroundHelpersAreLeftOutOnlyAtTheDeepestLevel() {
        let helper: [String: Any] = ["LSUIElement": true]
        let backgroundOnly: [String: Any] = ["LSBackgroundOnly": "YES"]
        let regular: [String: Any] = ["LSUIElement": false]
        #expect(AppBundleReach.isListedApp(depth: 0, info: helper))
        #expect(AppBundleReach.isListedApp(depth: 1, info: helper))
        #expect(!AppBundleReach.isListedApp(depth: 2, info: helper))
        #expect(!AppBundleReach.isListedApp(depth: 2, info: backgroundOnly))
        #expect(AppBundleReach.isListedApp(depth: 2, info: regular))
        #expect(AppBundleReach.isListedApp(depth: 2, info: [:]))
    }

    // MARK: App bundle walk

    /// Builds a throwaway app root shaped like the layouts seen on real Macs, and
    /// checks the walk lists exactly the apps the uninstaller should offer.
    @Test
    func walkListsAppsUpToTwoFoldersDownAndNothingInsideBundles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-walk-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func makeBundle(_ relative: String, info: [String: Any] = [:]) throws {
            let contents = root.appendingPathComponent(relative, isDirectory: true)
                .appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        }

        try makeBundle("Top.app")
        try makeBundle("Top.app/Contents/Library/LoginItems/Login.app")
        try makeBundle("Utilities/Tool.app")
        try makeBundle("Utilities/Menu.app", info: ["LSUIElement": true])
        try makeBundle("Autodesk/AutoCAD 2026/AutoCAD 2026.app")
        try makeBundle("Vendor/Suite/Helper.app", info: ["LSUIElement": true])
        try makeBundle("Utilities/Adobe Sync/CoreSync/Core Sync.app")
        try makeBundle("Vendor/Kit.framework/Inner.app")

        func relativePaths(_ urls: [URL]?) -> Set<String> {
            Set((urls ?? []).map { String($0.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)) })
        }

        #expect(relativePaths(AppBundleReach.appBundleURLs(in: root)) == [
            "Top.app",
            "Utilities/Tool.app",
            "Utilities/Menu.app",
            "Autodesk/AutoCAD 2026/AutoCAD 2026.app",
        ])
        // The orphan index also counts the helper, so its leftovers are kept.
        #expect(relativePaths(AppBundleReach.appBundleURLs(in: root, includingHelpers: true)) == [
            "Top.app",
            "Utilities/Tool.app",
            "Utilities/Menu.app",
            "Autodesk/AutoCAD 2026/AutoCAD 2026.app",
            "Vendor/Suite/Helper.app",
        ])
        // Every listed app passes the delete gate's depth rule.
        for url in AppBundleReach.appBundleURLs(in: root) ?? [] {
            #expect(AppBundleReach.folderDepth(
                ofAppAtPath: url.standardizedFileURL.path,
                roots: [root.standardizedFileURL.path]
            ) != nil)
        }
    }

    @Test
    func walkOfAMissingRootIsNil() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(AppBundleReach.appBundleURLs(in: root) == nil)
    }

    // MARK: Shared-leftover detection

    /// Two copies of the same app share bundle-id-keyed support. Removing one must
    /// see that the other copy still claims the shared preference.
    @Test
    func twoCopiesShareBundleIDLeftover() {
        let owner = makeApp(bundlePath: "/Applications/Rectangle.app")
        let secondCopy = makeApp(
            bundlePath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Rectangle.app").path
        )
        let claimant = AppUninstallScanPolicy.claimant(
            forLeftoverName: "com.knollsoft.Rectangle.plist",
            category: .preferences,
            ownerID: owner.id,
            among: [secondCopy]
        )
        #expect(claimant?.id == secondCopy.id)
    }

    /// The owner never counts as a claimant of its own leftover.
    @Test
    func ownerIsNotItsOwnClaimant() {
        let owner = makeApp()
        let claimant = AppUninstallScanPolicy.claimant(
            forLeftoverName: "com.knollsoft.Rectangle.plist",
            category: .preferences,
            ownerID: owner.id,
            among: [owner]
        )
        #expect(claimant == nil)
    }

    /// An unrelated surviving app does not claim the leftover, so it is not shared.
    @Test
    func unrelatedSurvivorDoesNotClaimLeftover() {
        let owner = makeApp()
        let safari = makeApp(
            name: "Safari",
            bundlePath: "/Applications/Safari.app",
            bundleID: "com.apple.Safari"
        )
        let claimant = AppUninstallScanPolicy.claimant(
            forLeftoverName: "com.knollsoft.Rectangle.plist",
            category: .preferences,
            ownerID: owner.id,
            among: [safari]
        )
        #expect(claimant == nil)
    }
}
