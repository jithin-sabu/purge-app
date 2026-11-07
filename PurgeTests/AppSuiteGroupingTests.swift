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

    @Test
    func partialSuiteOnlyForSomeMembersOfAGroupWithAnUninstaller() {
        let apps = resolve + raw
        let groups = AppSuiteGrouping.groups(apps: apps, roots: roots, teamID: teams(sameTeam(apps)))

        let one = AppSuiteGrouping.partialSuites(pickedIDs: [resolve[0].id], groups: groups, apps: apps)
        #expect(one == [PartialSuite(
            groupName: "DaVinci Resolve",
            uninstallerName: "Uninstall Resolve",
            uninstallerURL: resolve[3].bundleURL,
            pickedCount: 1,
            totalCount: 4
        )])

        let all = Set(resolve.map(\.id))
        #expect(AppSuiteGrouping.partialSuites(pickedIDs: all, groups: groups, apps: apps).isEmpty)
        #expect(AppSuiteGrouping.partialSuites(pickedIDs: [], groups: groups, apps: apps).isEmpty)
        // Blackmagic RAW has no uninstaller, so a partial pick there gets no note.
        #expect(AppSuiteGrouping.partialSuites(pickedIDs: [raw[0].id], groups: groups, apps: apps).isEmpty)
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
