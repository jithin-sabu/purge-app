import Foundation
import Testing
@testable import Purge

/// The uninstaller's Homebrew pass (#254), with the manager faked and the
/// Caskroom built in a temporary prefix. The bundle lives in a temporary folder
/// no scan policy covers, so when the Trash route is tried it is skipped for
/// safety and nothing reaches the user's Trash (#171).
@MainActor
@Suite("Homebrew cask apps in the uninstaller")
struct HomebrewCaskUninstallStoreTests {
    private let fm = FileManager.default

    private struct Fixture {
        let root: URL
        let prefix: URL
        let bundle: URL
        let cask: HomebrewCask
        var app: InstalledApp {
            InstalledApp(
                name: "Example",
                bundleURL: bundle,
                bundleID: nil,
                bundleSizeBytes: 12_345,
                isRunning: false,
                homebrewCask: cask
            )
        }
        var bundleItem: UninstallItem {
            UninstallItem(
                path: bundle, sizeBytes: 12_345, category: .bundle,
                safetyInfo: SafetyInfo(level: .medium, headline: "Example", explanation: "", recoverySteps: "", reinstallCommand: nil),
                matchReason: .appBundle, isSelected: true
            )
        }
        func plan(removesThroughHomebrew: Bool? = nil) -> UninstallPlan {
            UninstallPlan(id: app.id, apps: [
                UninstallAppPlan(app: app, items: [bundleItem], removesThroughHomebrew: removesThroughHomebrew)
            ])
        }
    }

    private func makeFixture(linked: Bool = true) throws -> Fixture {
        let root = fm.temporaryDirectory
            .appendingPathComponent("HomebrewCaskUninstallStoreTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let prefix = root.appendingPathComponent("homebrew", isDirectory: true)
        let brew = prefix.appendingPathComponent("bin/brew")
        try fm.createDirectory(at: brew.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: brew)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        let bundle = root.appendingPathComponent("Applications/Example.app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
        let version = prefix.appendingPathComponent("Caskroom/example/1.0", isDirectory: true)
        try fm.createDirectory(at: version, withIntermediateDirectories: true)
        if linked {
            try fm.createSymbolicLink(atPath: version.appendingPathComponent("Example.app").path, withDestinationPath: bundle.path)
        }
        return Fixture(root: root, prefix: prefix, bundle: bundle, cask: HomebrewCask(token: "example", prefix: prefix))
    }

    /// A store whose Homebrew pass reads the fixture's Caskroom and runs `fake`
    /// instead of brew. The watcher's hand-off files go to the fixture too.
    private func makeStore(_ fixture: Fixture, scans: FakeScans, runs: Runs,
                           fake: @escaping (PackageManagerTool) -> PackageManagerUninstaller.Outcome) -> PurgeStore {
        let store = scans.makeStore()
        store.homebrewPrefixes = [fixture.prefix]
        store.packageManagerUninstall = { tool in
            runs.tools.append(tool)
            return fake(tool)
        }
        store.homebrewCleanup = { cask in runs.cleanups.append(cask) }
        store.installedApps = [fixture.app]
        return store
    }

    private final class Runs {
        var tools: [PackageManagerTool] = []
        var cleanups: [HomebrewCask] = []
    }

    private func withHandoffRoot<T>(_ root: URL, _ body: () async throws -> T) async rethrows -> T {
        let previous = RemovedAppHandoff.root
        RemovedAppHandoff.root = root.appendingPathComponent("handoff", isDirectory: true)
        defer { RemovedAppHandoff.root = previous }
        return try await body()
    }

    @Test
    func homebrewRemovesTheAppAndHistorySaysPermanently() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let runs = Runs()
        let store = makeStore(fixture, scans: scans, runs: runs) { tool in
            try? FileManager.default.removeItem(at: tool.locations[0])
            return .removed
        }

        let watcherTold = await withHandoffRoot(fixture.root) {
            await store.confirmUninstallPlan(fixture.plan())
            return RemovedAppHandoff.isIgnored(path: fixture.bundle.path)
        }

        let tool = try #require(runs.tools.first)
        #expect(runs.tools.count == 1)
        #expect(tool.manager == .homebrewCask)
        #expect(tool.executable?.path == fixture.prefix.appendingPathComponent("bin/brew").path)
        #expect(tool.arguments == ["uninstall", "--cask", "example"])
        #expect(tool.locations.map(\.path) == [fixture.bundle.path])
        #expect(!fm.fileExists(atPath: fixture.bundle.path))
        // The cask's download is cleared only after Homebrew removed the app.
        #expect(runs.cleanups == [fixture.cask])

        let report = try #require(store.lastDeletionReport)
        #expect(report.bytesMovedToTrash == 0)
        #expect(report.bytesRemovedDirectly == 12_345)
        #expect(report.deletedItems.map(\.path) == [fixture.bundle.path])
        #expect(report.deletedItems.first?.movedToTrash == false)
        #expect(report.failedItems.isEmpty)
        #expect(store.installedApps.isEmpty)
        #expect(store.manualDeletionSession?.notes.isEmpty == true)
        #expect(store.manualDeletionSession?.finalBytesMovedToTrash == 12_345)
        // The watcher was told, so the deleted-apps review does not open on
        // Purge's own removal.
        #expect(watcherTold)
    }

    /// Move All to Trash hands back the plan with the Homebrew flag off, so
    /// Homebrew never runs and the app takes the Trash route, which the safety
    /// gate declines for a bundle outside the app folders.
    @Test
    func moveAllToTrashNeverRunsHomebrew() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let runs = Runs()
        let store = makeStore(fixture, scans: scans, runs: runs) { _ in .removed }

        await withHandoffRoot(fixture.root) { await store.confirmUninstallPlan(fixture.plan(removesThroughHomebrew: false)) }

        #expect(runs.tools.isEmpty)
        #expect(runs.cleanups.isEmpty)
        #expect(fm.fileExists(atPath: fixture.bundle.path))
        #expect(store.manualDeletionSession?.notes.isEmpty == true)
    }

    /// The gate re-reads the Caskroom at delete time: a cask whose link no
    /// longer points at the bundle runs nothing, and the app falls back to the
    /// Trash route with a note saying so.
    @Test
    func aCaskThatNoLongerPointsAtTheAppFallsBackToTheTrash() async throws {
        let fixture = try makeFixture(linked: false)
        defer { try? fm.removeItem(at: fixture.root) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let runs = Runs()
        let store = makeStore(fixture, scans: scans, runs: runs) { _ in .removed }

        await withHandoffRoot(fixture.root) { await store.confirmUninstallPlan(fixture.plan()) }

        #expect(runs.tools.isEmpty)
        #expect(fm.fileExists(atPath: fixture.bundle.path))
        let note = try #require(store.manualDeletionSession?.notes.first)
        #expect(note.contains("Homebrew no longer lists Example"))
        #expect(store.lastDeletionReport?.deletedItems.isEmpty == true)
    }

    /// Homebrew refusing leaves the app in place; Purge shows Homebrew's words
    /// and moves on to the Trash route, which trashes it or holds it, never
    /// counts it as removed.
    @Test
    func aHomebrewRefusalFallsBackToTheTrashWithItsMessage() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let runs = Runs()
        let store = makeStore(fixture, scans: scans, runs: runs) { _ in
            .failed("Error: Cask 'example' requires sudo to uninstall its pkg.")
        }

        await withHandoffRoot(fixture.root) { await store.confirmUninstallPlan(fixture.plan()) }

        #expect(runs.tools.count == 1)
        #expect(runs.cleanups.isEmpty)
        #expect(fm.fileExists(atPath: fixture.bundle.path))
        let note = try #require(store.manualDeletionSession?.notes.first)
        #expect(note.contains("Homebrew couldn't remove Example"))
        #expect(note.contains("requires sudo"))
        #expect(store.lastDeletionReport?.bytesRemovedDirectly == 0)
        #expect(store.lastDeletionReport?.deletedItems.isEmpty == true)
    }

    /// Homebrew can delete the app and still exit with an error, for a later
    /// step it could not do. The app is gone, so it counts as removed, and the
    /// note carries the message.
    @Test
    func anErrorAfterTheAppIsGoneStillCountsAsRemoved() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let runs = Runs()
        let store = makeStore(fixture, scans: scans, runs: runs) { tool in
            try? FileManager.default.removeItem(at: tool.locations[0])
            return .failed("Error: Failure while executing; `/usr/bin/sudo -E -- /usr/sbin/pkgutil --forget com.example.pkg` exited with 1.")
        }

        await withHandoffRoot(fixture.root) { await store.confirmUninstallPlan(fixture.plan()) }

        #expect(runs.tools.count == 1)
        #expect(runs.cleanups == [fixture.cask])
        let report = try #require(store.lastDeletionReport)
        #expect(report.bytesRemovedDirectly == 12_345)
        #expect(report.deletedItems.first?.movedToTrash == false)
        #expect(store.installedApps.isEmpty)
        let note = try #require(store.manualDeletionSession?.notes.first)
        #expect(note.contains("Homebrew removed Example but reported a problem"))
        #expect(note.contains("pkgutil"))
    }
}
