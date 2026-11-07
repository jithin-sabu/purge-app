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

    @Test
    func planNotesASuiteTakenInPartAndOpensItsUninstaller() async throws {
        let scans = FakeScans()
        let fixture = try makeFixture()
        defer { scans.cleanUp(); try? fm.removeItem(at: fixture.root) }
        let store = makeStore(scans, fixture)
        var launched: [URL] = []
        store.appLauncher = { launched.append($0) }
        #expect(await eventually { store.appSuiteGroups.count == 1 })

        store.toggleAppSelected(id: fixture.apps[0].id)
        await store.requestUninstallSelectedApps()
        let plan = try #require(store.uninstallPlan)
        let suite = try #require(plan.partialSuites.first)
        #expect(plan.partialSuites.count == 1)
        #expect(suite.pickedCount == 1)
        #expect(suite.totalCount == 3)
        #expect(suite.uninstallerURL == fixture.uninstaller.bundleURL)

        store.openSuiteUninstaller(at: suite.uninstallerURL)
        #expect(store.uninstallPlan == nil)
        #expect(launched == [fixture.uninstaller.bundleURL])
    }

    @Test
    func planForAWholeSuiteHasNoNote() async throws {
        let scans = FakeScans()
        let fixture = try makeFixture()
        defer { scans.cleanUp(); try? fm.removeItem(at: fixture.root) }
        let store = makeStore(scans, fixture)
        #expect(await eventually { store.appSuiteGroups.count == 1 })

        store.setAppsSelected(fixture.suiteIDs, true)
        await store.requestUninstallSelectedApps()
        let plan = try #require(store.uninstallPlan)
        #expect(plan.apps.count == 3)
        #expect(plan.partialSuites.isEmpty)
    }
}
