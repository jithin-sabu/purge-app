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

    /// The scanner walks every folder inside an app root, so the gate takes an
    /// app at any depth that is not inside another bundle.
    @Test
    func appBundleDeepInsideAppRootIsEligible() {
        let url = URL(fileURLWithPath: "/Applications/A/B/C/Foo.app", isDirectory: true)
        #expect(AppUninstallScanPolicy.isEligibleForUninstallDeletion(url))
    }

    /// An app nested in another bundle or package is that bundle's internals, at
    /// any depth. A hidden folder is one the walk never enters.
    @Test
    func appBundleInsideAnotherBundleIsNotEligible() {
        for path in [
            "/Applications/Host.app/Inner.app",
            "/Applications/Host.app/Contents/Inner.app",
            "/Applications/Vendor/Kit.framework/Inner.app",
            "/Applications/Vendor/Pane.prefPane/Contents/Inner.app",
            "/Applications/.Hidden/Inner.app",
        ] {
            #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(URL(fileURLWithPath: path, isDirectory: true)))
        }
    }

    @Test
    func folderDepthCountsFoldersBelowTheRoot() {
        let roots = ["/Applications", "/Users/x/Applications"]
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/A.app", roots: roots) == 0)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/Utilities/A.app", roots: roots) == 1)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Users/x/Applications/V/P/A.app", roots: roots) == 2)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/V/P/Q/A.app", roots: roots) == 3)
        // A version number in a folder name is not a bundle extension.
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/Tool 1.2/A.app", roots: roots) == 1)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications Old/A.app", roots: roots) == nil)
        #expect(AppBundleReach.folderDepth(ofAppAtPath: "/Applications/Notes.txt", roots: roots) == nil)
        // The runaway guard.
        let deep = "/Applications/" + String(repeating: "f/", count: AppBundleReach.maxFolderDepth + 1) + "A.app"
        #expect(AppBundleReach.folderDepth(ofAppAtPath: deep, roots: roots) == nil)
    }

    // MARK: App bundle walk

    /// Builds a throwaway app root shaped like the layouts seen on real Macs, and
    /// checks the walk lists exactly the apps the uninstaller should offer, and
    /// that the delete gate's rule agrees with the walk in both directions.
    @Test
    func walkListsAppsAtAnyDepthAndNothingInsidePackages() throws {
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
        try makeBundle("Autodesk/AutoCAD 2026/AutoCAD 2026.app")
        // Background parts of a suite are listed too, so the shared-leftover
        // checks can see them.
        try makeBundle("Vendor/Suite/Helper.app", info: ["LSUIElement": true])
        try makeBundle("Utilities/Adobe Sync/CoreSync/Core Sync.app", info: ["LSUIElement": true])
        // Packages, hidden folders, and symlinks are never entered.
        try makeBundle("Vendor/Kit.framework/Inner.app")
        try makeBundle("Docs/Notes.rtfd/Inner.app")
        try makeBundle(".Hidden/Secret.app")
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("Linked", isDirectory: true),
            withDestinationURL: root.appendingPathComponent("Autodesk", isDirectory: true)
        )

        let rootPath = root.standardizedFileURL.path
        func relative(_ path: String) -> String { String(path.dropFirst(rootPath.count + 1)) }

        let listed = Set((AppBundleReach.appBundleURLs(in: root) ?? []).map { relative($0.standardizedFileURL.path) })
        #expect(listed == [
            "Top.app",
            "Utilities/Tool.app",
            "Autodesk/AutoCAD 2026/AutoCAD 2026.app",
            "Vendor/Suite/Helper.app",
            "Utilities/Adobe Sync/CoreSync/Core Sync.app",
        ])

        // Every `.app` on disk, found without the walk's rules: the gate's rule
        // must accept exactly the listed ones.
        let everyApp = [
            "Top.app", "Top.app/Contents/Library/LoginItems/Login.app", "Utilities/Tool.app",
            "Autodesk/AutoCAD 2026/AutoCAD 2026.app", "Vendor/Suite/Helper.app",
            "Utilities/Adobe Sync/CoreSync/Core Sync.app", "Vendor/Kit.framework/Inner.app",
            "Docs/Notes.rtfd/Inner.app", ".Hidden/Secret.app", "Linked/AutoCAD 2026/AutoCAD 2026.app",
        ]
        for path in everyApp {
            let accepted = AppBundleReach.folderDepth(ofAppAtPath: rootPath + "/" + path, roots: [rootPath]) != nil
            #expect(accepted == listed.contains(path), "\(path)")
        }
    }

    /// The review on #154: a suite's background part must stay in the installed
    /// list, because that list is also who still claims a leftover. Uninstalling
    /// `Main` must not take the launch agent of the `Helper` sitting next to it,
    /// even though the agent's name starts with Main's bundle id.
    @Test
    func backgroundPartKeepsItsLaunchAgentWhenItsSiblingIsUninstalled() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-survivor-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        for (name, info) in [
            ("Main", ["CFBundleIdentifier": "com.v.app"]),
            ("Helper", ["CFBundleIdentifier": "com.v.app.helper", "LSUIElement": true] as [String: Any]),
        ] {
            let contents = root.appendingPathComponent("V/P/\(name).app/Contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        }

        let installed = (AppBundleReach.appBundleURLs(in: root) ?? []).map { url in
            makeApp(
                name: url.deletingPathExtension().lastPathComponent,
                bundlePath: url.path,
                bundleID: AppBundleReach.readInfoPlist(at: url)["CFBundleIdentifier"] as? String
            )
        }
        let main = try #require(installed.first { $0.bundleID == "com.v.app" })
        let helper = try #require(installed.first { $0.bundleID == "com.v.app.helper" })

        let agent = "com.v.app.helper.plist"
        // Main's prefix rule matches the agent, so only a survivor claim keeps it.
        #expect(AppUninstallScanPolicy.matchReason(forLeftoverName: agent, category: .launchAgents, app: main) == .bundleID)
        let claimant = AppUninstallScanPolicy.claimant(
            forLeftoverName: agent,
            category: .launchAgents,
            ownerID: main.id,
            among: installed.filter { $0.id != main.id },
            appGroupClaims: AppGroupClaims()
        )
        #expect(claimant?.id == helper.id)
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
            among: [secondCopy],
            appGroupClaims: AppGroupClaims()
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
            among: [owner],
            appGroupClaims: AppGroupClaims()
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
            among: [safari],
            appGroupClaims: AppGroupClaims()
        )
        #expect(claimant == nil)
    }

    // MARK: Group containers a kept app lists (#200)

    private let editor = InstalledApp(
        name: "Editor",
        bundleURL: URL(fileURLWithPath: "/nonexistent-purge-tests/Editor.app", isDirectory: true),
        bundleID: "com.vendor.Editor",
        bundleSizeBytes: 0,
        isRunning: false
    )
    private let viewer = InstalledApp(
        name: "Viewer",
        bundleURL: URL(fileURLWithPath: "/nonexistent-purge-tests/Viewer.app", isDirectory: true),
        bundleID: "org.other.Viewer",
        bundleSizeBytes: 0,
        isRunning: false
    )
    private let editorGroup = "ABCDE12345.com.vendor.Editor"

    private func leftover(_ name: String, category: UninstallCategory, reason: MatchReason) -> UninstallItem {
        UninstallItem(
            path: home.appendingPathComponent("Library/Group Containers/\(name)"),
            sizeBytes: 10,
            category: category,
            safetyInfo: SafetyInfo(level: .safe, headline: "", explanation: "", recoverySteps: "", reinstallCommand: nil),
            matchReason: reason,
            isSelected: true
        )
    }

    /// Claims as `AppGroupClaims.gather` builds them, from fake signatures in
    /// which each app's own bundle lists `groups[app]` and is signed by `team`.
    /// The bundles are not on disk, so no nested code is found.
    private func claims(_ groups: [InstalledApp: [String]], team: String) -> AppGroupClaims {
        var byPath: [String: [String]] = [:]
        for (app, list) in groups { byPath[app.bundleURL.standardizedFileURL.path] = list }
        return AppGroupClaims.gather(
            for: Array(groups.keys),
            leftovers: [leftover(editorGroup, category: .groupContainers, reason: .groupID)]
        ) { url in
            CodeSignature(identifier: nil, teamID: team, appGroups: byPath[url.standardizedFileURL.path] ?? [])
        }
    }

    /// Editor's group is named after Editor, so only Editor matches it by name.
    /// Viewer lists it in its entitlements under another id and another signing
    /// team. That listing alone holds the group back.
    @Test
    func keptAppListingTheGroupHoldsItBack() {
        #expect(AppUninstallScanPolicy.matchReason(forLeftoverName: editorGroup, category: .groupContainers, app: editor) == .groupID)
        #expect(AppUninstallScanPolicy.matchReason(forLeftoverName: editorGroup, category: .groupContainers, app: viewer) == nil)

        let claimant = AppUninstallScanPolicy.claimant(
            forLeftoverName: editorGroup,
            category: .groupContainers,
            ownerID: editor.id,
            among: [viewer],
            appGroupClaims: claims([viewer: [editorGroup]], team: "ZZZZZ99999")
        )
        #expect(claimant?.id == viewer.id)
    }

    /// A kept app from the same developer that lists only its own group leaves
    /// Editor's group to Editor. A shared signing team is not a claim, or most
    /// uninstalls would leave their own group behind.
    @Test
    func groupNoKeptAppListsIsStillRemoved() {
        let sketch = InstalledApp(
            name: "Sketch",
            bundleURL: URL(fileURLWithPath: "/nonexistent-purge-tests/Sketch.app", isDirectory: true),
            bundleID: "com.vendor.Sketch",
            bundleSizeBytes: 0,
            isRunning: false
        )
        let claimant = AppUninstallScanPolicy.claimant(
            forLeftoverName: editorGroup,
            category: .groupContainers,
            ownerID: editor.id,
            among: [sketch, viewer],
            appGroupClaims: claims([sketch: ["ABCDE12345.com.vendor.Sketch"], viewer: []], team: "ABCDE12345")
        )
        #expect(claimant == nil)
    }

    /// Entitlements list app groups, so a listing never claims a leftover in
    /// any other category, even one with the same name.
    @Test
    func entitlementClaimsOnlyApplyToGroupContainers() {
        let groupClaims = claims([viewer: ["com.vendor.Editor"]], team: "ZZZZZ99999")
        for category in [UninstallCategory.caches, .containers, .applicationSupport] {
            let claimant = AppUninstallScanPolicy.claimant(
                forLeftoverName: "com.vendor.Editor",
                category: category,
                ownerID: editor.id,
                among: [viewer],
                appGroupClaims: groupClaims
            )
            #expect(claimant == nil, "\(category)")
        }
    }

    /// The review sheet shows a group a kept app lists as "Kept, still used by
    /// Viewer" and unticks it, and leaves a group no kept app lists ticked.
    @Test
    func sheetMarksAGroupAKeptAppListsAsKept() {
        let ownGroup = "group.com.vendor.Editor"
        #expect(AppUninstallScanPolicy.matchReason(forLeftoverName: ownGroup, category: .groupContainers, app: editor) == .groupID)
        var plans = [UninstallAppPlan(app: editor, items: [
            leftover("Editor.app", category: .bundle, reason: .appBundle),
            leftover(editorGroup, category: .groupContainers, reason: .groupID),
            leftover(ownGroup, category: .groupContainers, reason: .groupID)
        ])]

        PurgeStore.markSharedWithSurvivors(
            in: &plans,
            survivors: [viewer],
            appGroupClaims: claims([viewer: [editorGroup]], team: "ZZZZZ99999")
        )

        let items = Dictionary(uniqueKeysWithValues: plans[0].items.map { ($0.path.lastPathComponent, $0) })
        #expect(items[editorGroup]?.keptForApp == "Viewer")
        #expect(items[editorGroup]?.isSelected == false)
        #expect(items[ownGroup]?.keptForApp == nil)
        #expect(items[ownGroup]?.isSelected == true)
        #expect(items["Editor.app"]?.isSelected == true)
    }
}
