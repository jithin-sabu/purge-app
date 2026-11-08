import Foundation
import Testing
@testable import Purge

/// #155: apps from one vendor that share a folder show as one group. Grouping is
/// display only, so these also check no app is ever dropped from the list.
struct AppSuiteGroupingTests {
    private let roots = ["/Applications", "/Users/me/Applications", "/Volumes/SSD/Applications"]

    private func app(_ path: String, id bundleID: String? = nil) -> InstalledApp {
        let url = URL(fileURLWithPath: path)
        return InstalledApp(
            name: url.deletingPathExtension().lastPathComponent,
            bundleURL: url,
            bundleID: bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )
    }

    private func teams(_ map: [String: String]) -> (URL) -> String? {
        { map[$0.path] }
    }

    // MARK: Key

    @Test
    func keyIsTheFirstFolderUnderTheRoot() {
        #expect(AppSuiteGrouping.groupKey(appPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app", roots: roots)
            == "/Applications/DaVinci Resolve")
        #expect(AppSuiteGrouping.groupKey(appPath: "/Applications/Vendor/Suite/Deep/Helper.app", roots: roots)
            == "/Applications/Vendor")
    }

    @Test
    func keyInsideUtilitiesIsTheSecondFolder() {
        #expect(AppSuiteGrouping.groupKey(
            appPath: "/Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Installer.app",
            roots: roots
        ) == "/Applications/Utilities/Adobe Creative Cloud")
    }

    @Test
    func appsDirectlyInARootOrInUtilitiesHaveNoKey() {
        #expect(AppSuiteGrouping.groupKey(appPath: "/Applications/Xcode.app", roots: roots) == nil)
        #expect(AppSuiteGrouping.groupKey(appPath: "/Applications/Utilities/Rectangle.app", roots: roots) == nil)
        #expect(AppSuiteGrouping.groupKey(appPath: "/Users/me/Applications/Tool.app", roots: roots) == nil)
    }

    @Test
    func appOutsideEveryRootHasNoKey() {
        #expect(AppSuiteGrouping.groupKey(appPath: "/Applicationsish/Vendor/A.app", roots: roots) == nil)
        #expect(AppSuiteGrouping.groupKey(appPath: "/opt/Vendor/A.app", roots: roots) == nil)
    }

    @Test
    func driveAndHomeRootsGroupTheSameWay() {
        #expect(AppSuiteGrouping.groupKey(appPath: "/Volumes/SSD/Applications/Suite/A.app", roots: roots)
            == "/Volumes/SSD/Applications/Suite")
        #expect(AppSuiteGrouping.groupKey(appPath: "/Users/me/Applications/Suite/A.app", roots: roots)
            == "/Users/me/Applications/Suite")
    }

    @Test
    func longestRootWins() {
        let nested = roots + ["/Volumes/SSD/Applications/Mine"]
        #expect(AppSuiteGrouping.groupKey(appPath: "/Volumes/SSD/Applications/Mine/Suite/A.app", roots: nested)
            == "/Volumes/SSD/Applications/Mine/Suite")
        #expect(AppSuiteGrouping.groupKey(appPath: "/Volumes/SSD/Applications/Mine/A.app", roots: nested) == nil)
    }

    // MARK: Groups

    private var resolve: [InstalledApp] {
        [
            app("/Applications/DaVinci Resolve/DaVinci Resolve.app", id: "com.blackmagic-design.DaVinciResolve"),
            app("/Applications/DaVinci Resolve/Blackmagic Remote Monitor.app"),
            app("/Applications/DaVinci Resolve/DaVinci Control Panels Setup.app"),
            app("/Applications/DaVinci Resolve/Uninstall Resolve.app", id: "com.blackmagic-design.UninstallDaVinciResolve")
        ]
    }

    private var raw: [InstalledApp] {
        [
            app("/Applications/Blackmagic RAW/Blackmagic RAW Player.app"),
            app("/Applications/Blackmagic RAW/Blackmagic RAW Speed Test.app")
        ]
    }

    private func sameTeam(_ apps: [InstalledApp], _ team: String = "9ZGFBWLSYP") -> [String: String] {
        Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleURL.path, team) })
    }

    @Test
    func sameTeamInOneFolderIsOneGroupWithItsUninstaller() {
        let groups = AppSuiteGrouping.groups(apps: resolve, roots: roots, teamID: teams(sameTeam(resolve)))
        #expect(groups.count == 1)
        #expect(groups.first?.name == "DaVinci Resolve")
        #expect(groups.first?.appIDs.count == 4)
        #expect(groups.first?.uninstallerID == "/Applications/DaVinci Resolve/Uninstall Resolve.app")
    }

    @Test
    func oneTeamNeverJoinsTwoFolders() {
        let apps = resolve + raw
        let groups = AppSuiteGrouping.groups(apps: apps, roots: roots, teamID: teams(sameTeam(apps)))
        #expect(groups.map(\.name) == ["Blackmagic RAW", "DaVinci Resolve"])
        #expect(groups.first?.uninstallerID == nil)
    }

    @Test
    func oneAppInAFolderIsNoGroup() {
        let lone = [app("/Applications/Utilities/Adobe Sync/CoreSync/Core Sync.app")]
        #expect(AppSuiteGrouping.groups(apps: lone, roots: roots, teamID: teams(sameTeam(lone))).isEmpty)
    }

    @Test
    func mixedTeamsStayFlat() {
        let games = [app("/Applications/Games/Alpha.app"), app("/Applications/Games/Beta.app")]
        let map = [games[0].bundleURL.path: "AAAAAAAAAA", games[1].bundleURL.path: "BBBBBBBBBB"]
        #expect(AppSuiteGrouping.groups(apps: games, roots: roots, teamID: teams(map)).isEmpty)
    }

    @Test
    func anUnsignedMemberKeepsTheFolderFlat() {
        var map = sameTeam(resolve)
        map[resolve[1].bundleURL.path] = nil
        #expect(AppSuiteGrouping.groups(apps: resolve, roots: roots, teamID: teams(map)).isEmpty)
        let allUnsigned = AppSuiteGrouping.groups(apps: resolve, roots: roots, teamID: { _ in nil })
        #expect(allUnsigned.isEmpty)
        let empty = AppSuiteGrouping.groups(apps: resolve, roots: roots, teamID: { _ in "" })
        #expect(empty.isEmpty)
    }

    @Test
    func teamCaseDoesNotSplitAGroup() {
        var map = sameTeam(resolve)
        map[resolve[0].bundleURL.path] = "9zgfbwlsyp"
        #expect(AppSuiteGrouping.groups(apps: resolve, roots: roots, teamID: teams(map)).count == 1)
    }

    @Test
    func teamIsAskedOnlyForAppsWithAKey() {
        var asked: [String] = []
        let apps = [app("/Applications/Xcode.app"), app("/Applications/Utilities/Rectangle.app")] + raw
        _ = AppSuiteGrouping.groups(apps: apps, roots: roots) { url in
            asked.append(url.path)
            return "T"
        }
        #expect(Set(asked) == Set(raw.map(\.bundleURL.path)))
    }

    @Test
    func adobeCreativeCloudGroupsInsideUtilities() {
        let cc = [
            app("/Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Desktop App.app"),
            app("/Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Installer.app"),
            app("/Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Uninstaller.app"),
            app("/Applications/Utilities/Adobe Creative Cloud/Diagnostics/Adobe Creative Cloud Diagnostics.app"),
            app("/Applications/Utilities/Adobe Creative Cloud Experience/CCXProcess/CCXProcess.app"),
            app("/Applications/Utilities/Adobe Sync/CoreSync/Core Sync.app")
        ]
        let groups = AppSuiteGrouping.groups(apps: cc, roots: roots, teamID: teams(sameTeam(cc, "JQ525L2MZD")))
        #expect(groups.count == 1)
        #expect(groups.first?.name == "Adobe Creative Cloud")
        #expect(groups.first?.appIDs.count == 4)
        #expect(groups.first?.uninstallerID?.hasSuffix("Creative Cloud Uninstaller.app") == true)
    }

    // MARK: Uninstaller

    @Test
    func uninstallerMatchesFileNameOrBundleID() {
        #expect(AppSuiteGrouping.uninstaller(in: [app("/A/Autodesk Uninstall Tool.app"), app("/A/Maya.app")])?.name
            == "Autodesk Uninstall Tool")
        #expect(AppSuiteGrouping.uninstaller(in: [app("/A/Remover.app", id: "com.vendor.Uninstaller"), app("/A/B.app")])?.name
            == "Remover")
        #expect(AppSuiteGrouping.uninstaller(in: [app("/A/Maya.app"), app("/A/Mudbox.app")]) == nil)
    }

    // MARK: Entries

    @Test
    func entriesFoldAGroupWhereItsFirstMemberWas() {
        let apps = [app("/Applications/Arc.app")] + resolve + [app("/Applications/Zoom.app")]
        let groups = AppSuiteGrouping.groups(apps: apps, roots: roots, teamID: teams(sameTeam(resolve)))
        let entries = AppSuiteGrouping.entries(apps: apps, groups: groups)
        #expect(entries.map(\.id) == ["/Applications/Arc.app", "group:/Applications/DaVinci Resolve", "/Applications/Zoom.app"])
    }

    @Test
    func aGroupWithOneMemberLeftShowsAPlainApp() {
        let groups = AppSuiteGrouping.groups(apps: resolve, roots: roots, teamID: teams(sameTeam(resolve)))
        let entries = AppSuiteGrouping.entries(apps: [resolve[0]], groups: groups)
        #expect(entries.map(\.id) == [resolve[0].id])
    }

    /// The safety property: grouping never hides an app from the list, for any
    /// mix of folders, teams and order.
    @Test(arguments: 0..<25)
    func entriesHoldEveryAppExactlyOnce(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed + 1))
        let folders = ["Suite", "Games", "Utilities/Vendor", "Utilities", ""]
        let apps: [InstalledApp] = (0..<Int.random(in: 0...18, using: &generator)).map { index in
            let folder = folders.randomElement(using: &generator)!
            let sub = Bool.random(using: &generator) ? "/Sub" : ""
            let path = folder.isEmpty ? "/Applications/App\(index).app" : "/Applications/\(folder)\(sub)/App\(index).app"
            return app(path)
        }.shuffled(using: &generator)
        let teamMap = Dictionary(uniqueKeysWithValues: apps.map {
            ($0.bundleURL.path, ["T1", "T1", "T2", ""].randomElement(using: &generator)!)
        })
        let groups = AppSuiteGrouping.groups(apps: apps, roots: roots, teamID: teams(teamMap))
        let shown = AppSuiteGrouping.entries(apps: apps, groups: groups).flatMap(\.apps).map(\.id)
        #expect(shown.count == apps.count)
        #expect(Set(shown) == Set(apps.map(\.id)))
    }

    // MARK: Fan order

    @Test
    func fanLeadsWithTheAppNamedLikeTheFolderAndPutsTheUninstallerLast() {
        var apps = resolve
        apps[1].bundleSizeBytes = 9_000 // the largest, but not named like the folder
        let order = AppGroupFan.ordered(apps, groupName: "DaVinci Resolve").map(\.name)
        #expect(order.first == "DaVinci Resolve")
        #expect(order.last == "Uninstall Resolve")
    }

    @Test
    func fanLeadsWithTheLargestAppWhenNoneIsNamedLikeTheFolder() {
        var apps = raw
        apps[1].bundleSizeBytes = 500
        #expect(AppGroupFan.ordered(apps, groupName: "Blackmagic RAW").first?.name == "Blackmagic RAW Speed Test")
    }

    // MARK: Search

    @Test
    func searchingTheFolderNameListsEveryAppInTheGroup() {
        let apps = resolve + raw + [app("/Applications/Xcode.app")]
        let groups = AppSuiteGrouping.groups(apps: apps, roots: roots, teamID: teams(sameTeam(resolve + raw)))
        let found = UninstallView.matchingApps(apps, query: "davinci", focus: nil, groups: groups)
        #expect(Set(found.map(\.id)) == Set(resolve.map(\.id)))
        // Without groups, only names and bundle ids match, as before.
        let plain = UninstallView.matchingApps(apps, query: "davinci", focus: nil)
        #expect(Set(plain.map(\.id)) == Set([resolve[0].id, resolve[2].id, resolve[3].id]))
    }

    // MARK: Partial suites

    private var suiteSetup: (apps: [InstalledApp], groups: [AppSuiteGroup]) {
        let apps = resolve + raw
        return (apps, AppSuiteGrouping.groups(apps: apps, roots: roots, teamID: teams(sameTeam(apps))))
    }

    @Test
    func somePartsWarnAndCountOnlyTheAppsBesideTheUninstaller() {
        let (apps, groups) = suiteSetup
        let one = AppSuiteGrouping.partialSuites(removingIDs: [resolve[0].id], groups: groups, apps: apps)
        #expect(one == [PartialSuite(
            kind: .someParts,
            groupName: "DaVinci Resolve",
            uninstallerName: "Uninstall Resolve",
            uninstallerURL: resolve[3].bundleURL,
            pickedCount: 1,
            totalCount: 3
        )])
        // Every app but the uninstaller: the uninstaller can still run, so no note.
        let parts = Set(resolve.prefix(3).map(\.id))
        #expect(AppSuiteGrouping.partialSuites(removingIDs: parts, groups: groups, apps: apps).isEmpty)
        #expect(AppSuiteGrouping.partialSuites(removingIDs: [], groups: groups, apps: apps).isEmpty)
        // Blackmagic RAW has no uninstaller, so a partial pick there gets no note.
        #expect(AppSuiteGrouping.partialSuites(removingIDs: [raw[0].id], groups: groups, apps: apps).isEmpty)
    }

    /// Review of #337: removing the uninstaller is the case that leaves the
    /// vendor's other files behind, alone or with every other app.
    @Test
    func removingTheUninstallerAlwaysWarns() {
        let (apps, groups) = suiteSetup
        let alone = AppSuiteGrouping.partialSuites(removingIDs: [resolve[3].id], groups: groups, apps: apps)
        #expect(alone.map(\.kind) == [.uninstallerRemoved])
        #expect(alone.first?.pickedCount == 0)

        let all = AppSuiteGrouping.partialSuites(removingIDs: Set(resolve.map(\.id)), groups: groups, apps: apps)
        #expect(all.map(\.kind) == [.uninstallerRemoved])
        #expect(all.first?.pickedCount == 3)
    }

    /// Review of #337: a saved row from the last scan can't be ticked, so it
    /// never turns a full pick of the listed apps into a partial one.
    @Test
    func savedMembersDoNotCountTowardAPartialPick() {
        let (_, groups) = suiteSetup
        let listed = [resolve[0], resolve[1], resolve[3]] // resolve[2] is a saved row only
        let picked = Set([resolve[0].id, resolve[1].id])
        #expect(AppSuiteGrouping.partialSuites(removingIDs: picked, groups: groups, apps: listed).isEmpty)
        let some = AppSuiteGrouping.partialSuites(removingIDs: [resolve[0].id], groups: groups, apps: listed)
        #expect(some.first?.totalCount == 2)
    }

    private func appPlan(_ app: InstalledApp, bundleTicked: Bool = true) -> UninstallAppPlan {
        UninstallAppPlan(app: app, items: [UninstallItem(
            path: app.bundleURL, sizeBytes: 1, category: .bundle,
            safetyInfo: SafetyInfo(level: .medium, headline: app.name, explanation: "", recoverySteps: "", reinstallCommand: nil),
            matchReason: .appBundle, isSelected: bundleTicked
        )])
    }

    /// Review of #337: the sheet lets the user untick a bundle, which keeps
    /// that app, so the warning follows the ticks rather than the first pick.
    @Test
    func planWarningFollowsTheTickedBundles() {
        let (apps, groups) = suiteSetup
        var plan = UninstallPlan(
            id: "p",
            apps: resolve.prefix(3).map { appPlan($0) },
            suiteGroups: groups,
            suiteApps: apps
        )
        #expect(plan.partialSuites.isEmpty)

        plan.apps[1].items[0].isSelected = false
        #expect(plan.partialSuites.map(\.kind) == [.someParts])
        #expect(plan.partialSuites.first?.pickedCount == 2)

        var one = UninstallPlan(id: "q", apps: [appPlan(resolve[0])], suiteGroups: groups, suiteApps: apps)
        #expect(one.partialSuites.count == 1)
        one.apps[0].items[0].isSelected = false
        #expect(one.partialSuites.isEmpty)
    }
}

/// A small deterministic generator so the property test fails the same way twice.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
