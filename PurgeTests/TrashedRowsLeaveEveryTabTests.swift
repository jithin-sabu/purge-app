import Foundation
import Testing
@testable import Purge

/// An uninstall took its leftovers off the Uninstaller only. The same folders
/// also show as App Caches rows, which stayed up after they went to the Trash
/// (#183). The leftover cleanup shares the same removal.
///
/// Everything lives in a temporary home, and the store cleans through a fake
/// Trash that moves nothing (#171).
@MainActor
@Suite("Trashed paths leave every tab")
struct TrashedRowsLeaveEveryTabTests {
    private let fm = FileManager.default

    private func cacheRow(_ path: URL) -> CacheItem {
        CacheItem(
            definitionKey: nil,
            location: CacheLocation(path: path, sizeBytes: 1_000, lastModified: .distantPast, folderName: path.lastPathComponent),
            appName: path.lastPathComponent,
            safetyInfo: SafetyInfo(level: .safe, headline: "Cache", explanation: "", recoverySteps: "", reinstallCommand: nil),
            gitStatus: .clean
        )
    }

    @Test func anUninstalledAppsCacheRowsGoToo() async throws {
        let home = fm.temporaryDirectory.appendingPathComponent("purgetest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let bundleID = "com.purgetest.uninstall-\(UUID().uuidString.lowercased())"
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let leftover = caches.appendingPathComponent(bundleID, isDirectory: true)
        let inside = leftover.appendingPathComponent("Code Cache", isDirectory: true)
        let other = caches.appendingPathComponent("com.purgetest.other", isDirectory: true)
        for folder in [inside, other] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(repeating: 0, count: 64).write(to: inside.appendingPathComponent("data"))

        let scans = FakeScans()
        defer { scans.cleanUp() }
        let trash = FakeTrash()
        let store = scans.makeStore(fileDeleter: FileDeleter(home: home, trash: trash.trash))
        store.cacheItems = [cacheRow(leftover), cacheRow(inside), cacheRow(other)]

        let app = InstalledApp(
            name: "Example",
            bundleURL: home.appendingPathComponent("Applications/Example.app", isDirectory: true),
            bundleID: bundleID,
            bundleSizeBytes: 1,
            isRunning: false
        )
        let item = UninstallItem(
            path: leftover,
            sizeBytes: 64,
            category: .caches,
            safetyInfo: SafetyInfo(level: .medium, headline: "Example", explanation: "", recoverySteps: "", reinstallCommand: nil),
            matchReason: .bundleID,
            isSelected: true
        )
        let plan = UninstallPlan(id: app.id, apps: [UninstallAppPlan(app: app, items: [item])])
        store.uninstallPlan = plan

        await store.confirmUninstallPlan(plan)

        try #require(trash.trashedPaths == [leftover.standardizedFileURL.path])
        #expect(store.cacheItems.map(\.path) == [other])
    }
}
