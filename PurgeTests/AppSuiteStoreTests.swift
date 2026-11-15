import Foundation
import Testing
@testable import Purge

/// The store side of #155: groups follow the app list, a group ticks and clears
/// as one, and the review plan notes a suite taken only in part. The apps live in
/// a temporary folder with made-up names, so no real app or leftover is touched.
@MainActor
@Suite("Vendor app groups in the store")
struct AppSuiteStoreTests {
    private let fm = FileManager.default

    private struct Fixture {
        let root: URL
        let apps: [InstalledApp]
        var applications: URL { root.appendingPathComponent("Applications") }
        var suiteIDs: [String] { Array(apps.prefix(3).map(\.id)) }
        var uninstaller: InstalledApp { apps[2] }
        var loner: InstalledApp { apps[3] }
    }

    private func makeFixture() throws -> Fixture {
        let root = fm.temporaryDirectory
            .appendingPathComponent("AppSuiteStoreTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let tag = UUID().uuidString.prefix(8)
        let paths = [
            "Applications/Zqx Suite \(tag)/Zqx Editor \(tag).app",
            "Applications/Zqx Suite \(tag)/Helpers/Zqx Helper \(tag).app",
            "Applications/Zqx Suite \(tag)/Uninstall Zqx \(tag).app",
            "Applications/Zqx Lone \(tag).app"
        ]
        let apps = try paths.map { relative -> InstalledApp in
            let url = root.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            return InstalledApp(
                name: url.deletingPathExtension().lastPathComponent,
                bundleURL: url,
                bundleID: nil,
                bundleSizeBytes: 1_000,
                isRunning: false
            )
        }
        return Fixture(root: root, apps: apps)
    }

    /// A signature reader that holds its first read until the test lets it go,
    /// and records how many reads ran at once.
    private final class HeldReader: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var paths: [String] = []
        private var active = 0
        private(set) var maxActive = 0

        func read(_ url: URL) -> String? {
            lock.lock()
            paths.append(url.path)
            active += 1
            maxActive = max(maxActive, active)
            let isFirst = paths.count == 1
            lock.unlock()
            if isFirst { release.wait() }
            lock.lock(); active -= 1; lock.unlock()
            return "ABCDE12345"
        }

        func letGo() { release.signal() }
        var readPaths: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
    }

    private func makeStore(_ scans: FakeScans, _ fixture: Fixture, calls: Calls = Calls()) -> PurgeStore {
        let store = scans.makeStore()
        store.appTeamIDReader = { url in
            calls.record(url.path)
            return "ABCDE12345"
        }
        store.appFolderPaths = AppFolderPaths(roots: [fixture.applications.path])
        store.installedApps = fixture.apps
        return store
    }

    @Test
    func groupsFollowTheListAndLeaveItWhole() async throws {
        let scans = FakeScans()
        let fixture = try makeFixture()
        defer { scans.cleanUp(); try? fm.removeItem(at: fixture.root) }
        let store = makeStore(scans, fixture)

        #expect(await eventually { store.appSuiteGroups.count == 1 })
        let group = try #require(store.appSuiteGroups.first)
        #expect(Set(group.appIDs) == Set(fixture.suiteIDs))
        #expect(group.uninstallerID == fixture.uninstaller.id)
        // Grouping is display only: the survivor list still holds every bundle.
        #expect(store.installedApps.map(\.id) == fixture.apps.map(\.id))

        let entries = store.appListEntries(fixture.apps)
        #expect(entries.count == 2)
        #expect(entries.flatMap(\.apps).count == fixture.apps.count)
    }

    @Test
    func sizeUpdatesDoNotReadSignaturesAgain() async throws {
        let scans = FakeScans()
        let fixture = try makeFixture()
        defer { scans.cleanUp(); try? fm.removeItem(at: fixture.root) }
        let calls = Calls()
        let store = makeStore(scans, fixture, calls: calls)
        #expect(await eventually { store.appSuiteGroups.count == 1 })
        let readsAfterFirstBuild = calls.count
        #expect(readsAfterFirstBuild == 3)

        store.installedApps[0].bundleSizeBytes = 99_999
        store.installedApps[0].lastOpened = Date()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.count == readsAfterFirstBuild)

        // A removed member drops the group once only one app is left in its folder.
        store.installedApps.removeAll { fixture.suiteIDs.prefix(2).contains($0.id) }
        #expect(await eventually { store.appSuiteGroups.isEmpty })
        #expect(calls.count == readsAfterFirstBuild)
    }

    /// Review of #337: a scan lists apps a few at a time. The rebuilds it sets
    /// off fold into one, so each signature is read once, and off the main thread.
    @Test
    func aScanBurstReadsEachSignatureOnceOffTheMainThread() async throws {
        let scans = FakeScans()
        let fixture = try makeFixture()
        defer { scans.cleanUp(); try? fm.removeItem(at: fixture.root) }
        let calls = Calls()
        let readOnMain = Calls()
        let store = scans.makeStore()
        store.appTeamIDReader = { url in
            calls.record(url.path)
            if Thread.isMainThread { readOnMain.record(url.path) }
            return "ABCDE12345"
        }
        store.appFolderPaths = AppFolderPaths(roots: [fixture.applications.path])
        for app in fixture.apps { store.installedApps.append(app) }

        #expect(await eventually { store.appSuiteGroups.count == 1 })
        #expect(calls.count == 3)
        #expect(readOnMain.count == 0)
    }

    /// Review of #337: the list changes while a build is stuck on a signature
    /// read. The next build waits for it, so reads never overlap, no path is
    /// read twice, and the groups for the final list still land.
    @Test
    func aChangeDuringABuildWaitsForItAndStillPublishes() async throws {
        let scans = FakeScans()
        let fixture = try makeFixture()
        defer { scans.cleanUp(); try? fm.removeItem(at: fixture.root) }
        let reader = HeldReader()
        let store = scans.makeStore()
        store.appTeamIDReader = { reader.read($0) }
        store.appFolderPaths = AppFolderPaths(roots: [fixture.applications.path])
        store.installedApps = [fixture.apps[0], fixture.apps[1]]

        #expect(await eventually { reader.readPaths.count == 1 })
        store.installedApps = fixture.apps
        try await Task.sleep(for: .milliseconds(400))
        reader.letGo()

        #expect(await eventually { store.appSuiteGroups.count == 1 })
        #expect(store.appSuiteGroups.first?.appIDs.count == 3)
        #expect(reader.maxActive == 1)
        #expect(reader.readPaths.count == Set(reader.readPaths).count)
    }

    @Test
    func groupTicksOnlyListedAppsAndClearsAll() throws {
        let scans = FakeScans()
        let fixture = try makeFixture()
        defer { scans.cleanUp(); try? fm.removeItem(at: fixture.root) }
        let store = makeStore(scans, fixture)

        store.setAppsSelected(fixture.suiteIDs + ["/Applications/Not Listed.app"], true)
        #expect(store.selectedAppIDs == Set(fixture.suiteIDs))

        store.toggleAppSelected(id: fixture.loner.id)
        store.setAppsSelected(fixture.suiteIDs, false)
        #expect(store.selectedAppIDs == [fixture.loner.id])
    }

    /// The plan gets the groups its apps belong to and their members. Checked
    /// on the store's helper, not through a plan build, which scans the real
    /// home folder for leftovers.
    @Test
    func suiteContextHoldsOnlyTheGroupsOfThePickedApps() async throws {
        let scans = FakeScans()
        let fixture = try makeFixture()
        defer { scans.cleanUp(); try? fm.removeItem(at: fixture.root) }
        let store = makeStore(scans, fixture)
        #expect(await eventually { store.appSuiteGroups.count == 1 })

        let picked = store.suiteContext(for: [fixture.apps[0].id])
        #expect(picked.groups.map(\.id) == store.appSuiteGroups.map(\.id))
        #expect(Set(picked.apps.map(\.id)) == Set(fixture.suiteIDs))

        let lone = store.suiteContext(for: [fixture.loner.id])
        #expect(lone.groups.isEmpty)
        #expect(lone.apps.isEmpty)
    }

    @Test
    func openingTheUninstallerClosesThePlanAndLaunchesIt() throws {
        let scans = FakeScans()
        let fixture = try makeFixture()
        defer { scans.cleanUp(); try? fm.removeItem(at: fixture.root) }
        let store = makeStore(scans, fixture)
        var launched: [URL] = []
        store.appLauncher = { launched.append($0) }
        store.uninstallPlan = UninstallPlan(id: "p", apps: [UninstallAppPlan(app: fixture.apps[0], items: [])])

        store.openSuiteUninstaller(at: fixture.uninstaller.bundleURL)
        #expect(store.uninstallPlan == nil)
        #expect(launched == [fixture.uninstaller.bundleURL])
    }
}
