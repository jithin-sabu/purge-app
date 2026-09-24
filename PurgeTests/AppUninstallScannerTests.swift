import Foundation
import Testing
@testable import Purge

/// Exercises the leftover scan against real `~/Library` locations, using a unique
/// fake bundle id so it never collides with a real app's files and always cleans
/// up after itself.
///
/// Like `ScannerOffMainTests`, this does not assert the scanner's `nonisolated`
/// property directly (only observable from inside the awaited callee, and not
/// enforced at runtime in Swift 5 mode). It pins the observable behaviour: what
/// the scan matches, how it scores it, and what it leaves alone.
@Suite("App uninstall leftover scanning")
struct AppUninstallScannerTests {
    private let fm = FileManager.default

    private func collect(_ stream: AsyncStream<UninstallItem>) async -> [UninstallItem] {
        var items: [UninstallItem] = []
        for await item in stream { items.append(item) }
        return items
    }

    @Test
    func findsBundleIDAndNameLeftoversAndScoresThem() async throws {
        let token = UUID().uuidString.prefix(8).lowercased()
        let bundleID = "com.purgetest.\(token)"
        let appName = "PurgeTest\(token)"
        let home = fm.homeDirectoryForCurrentUser
        let prefs = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)

        let plist = prefs.appendingPathComponent("\(bundleID).plist")
        let supportByID = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        let supportByName = appSupport.appendingPathComponent(appName, isDirectory: true)
        // A same-vendor folder that must NOT be matched: different bundle id, and
        // a name that only shares the vendor stem.
        let unrelated = appSupport.appendingPathComponent("com.purgetest.other\(token)", isDirectory: true)

        fm.createFile(atPath: plist.path, contents: Data([0x00]))
        try fm.createDirectory(at: supportByID, withIntermediateDirectories: true)
        try fm.createDirectory(at: supportByName, withIntermediateDirectories: true)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: plist)
            try? fm.removeItem(at: supportByID)
            try? fm.removeItem(at: supportByName)
            try? fm.removeItem(at: unrelated)
        }

        // A temp .app bundle so the bundle row has a real path to size.
        let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(appName).app", isDirectory: true)
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bundleURL) }

        let app = InstalledApp(
            name: appName,
            bundleURL: bundleURL,
            bundleID: bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )

        let items = await collect(AppUninstallScanner().leftoverStream(for: app))
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path.standardizedFileURL.path, $0) })

        // Bundle row is present and comes through as the app itself.
        #expect(items.contains { $0.category == .bundle && $0.matchReason == .appBundle })

        // Bundle-id anchored: matched, safe, preselected.
        let plistItem = byPath[plist.standardizedFileURL.path]
        #expect(plistItem?.matchReason == .bundleID)
        #expect(plistItem?.safetyInfo.level == .safe)
        #expect(plistItem?.isSelected == true)

        let supportIDItem = byPath[supportByID.standardizedFileURL.path]
        #expect(supportIDItem?.matchReason == .bundleID)

        // Name anchored: still matched and still flagged medium in the data, but
        // uninstall takes the app's files with it, so every match starts ticked.
        let nameItem = byPath[supportByName.standardizedFileURL.path]
        #expect(nameItem?.matchReason == .appName)
        #expect(nameItem?.safetyInfo.level == .medium)
        #expect(nameItem?.isSelected == true)

        // The false-positive guard: the unrelated vendor folder is left alone.
        #expect(byPath[unrelated.standardizedFileURL.path] == nil)
    }

    @Test
    func installedAppsScanExcludesSystemAppsAndPurge() async {
        var apps: [InstalledApp] = []
        for await app in AppUninstallScanner().installedAppsStream() {
            apps.append(app)
        }
        // Whatever this machine has installed, the scan must never surface a
        // system bundle or Purge itself.
        #expect(apps.allSatisfy { !$0.bundleURL.path.hasPrefix("/System/") })
        #expect(apps.allSatisfy { $0.bundleID != "io.getpurge.app" })
    }

    @Test
    func spotlightLogicalSizeIgnoresMissingPaths() {
        let missing = URL(fileURLWithPath: "/tmp/purge-missing-\(UUID().uuidString).app")
        #expect(InstalledAppBundleSizing.spotlightLogicalSize(at: missing) == nil)
        #expect(InstalledAppBundleSizing.spotlightLastOpened(at: missing) == nil)
    }
}

@Suite("Uninstaller sort options")
struct AppSortOptionTests {
    @Test
    func sizeSortsWaitForFullMeasurement() {
        #expect(AppSortOption.largest.needsFullMeasurement)
        #expect(AppSortOption.smallest.needsFullMeasurement)
        #expect(!AppSortOption.nameAZ.needsFullMeasurement)
        #expect(!AppSortOption.recentlyUsed.needsFullMeasurement)
    }

    @Test
    func menuOffersNoInstallDateSort() {
        #expect(AppSortOption.allCases == [.largest, .smallest, .nameAZ, .recentlyUsed])
    }

    @Test
    func lastUsedSortOrdersKnownOpensAndKeepsUnknownAppsInTheList() {
        let stale = app(name: "Zoom", opened: Date(timeIntervalSince1970: 1_000))
        let alsoStale = app(name: "arc", opened: Date(timeIntervalSince1970: 1_000))
        let fresh = app(name: "Slack", opened: Date(timeIntervalSince1970: 2_000))
        let unknown = app(name: "Mystery", opened: nil)

        let newestFirst = AppSortOption.recentlyUsed.sorted([stale, unknown, fresh, alsoStale])
        #expect(newestFirst.map(\.name) == ["Slack", "arc", "Zoom", "Mystery"])
    }

    @Test
    func missingOpenDateIsLabeledNotOpened() {
        let now = Date(timeIntervalSince1970: 10_000)
        let unknown = app(name: "Mystery", opened: nil)
        let opened = app(name: "Known", opened: Date(timeIntervalSince1970: 5_000))
        #expect(AppSortOption.recentlyUsed.activityLabel(for: unknown, now: now) == "Not opened")
        let openedLabel = AppSortOption.recentlyUsed.activityLabel(for: opened, now: now)
        #expect(openedLabel?.hasPrefix("Opened ") == true)
        #expect(AppSortOption.nameAZ.activityLabel(for: opened, now: now) == nil)
    }

    private func app(name: String, opened: Date?) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            bundleID: nil,
            bundleSizeBytes: 1,
            isRunning: false,
            lastOpened: opened
        )
    }

    @Test
    func nameSortIsAlphabeticalIgnoringCase() {
        let older = InstalledApp(
            name: "zoom",
            bundleURL: URL(fileURLWithPath: "/Applications/zoom.app"),
            bundleID: "us.zoom.xos",
            bundleSizeBytes: 9,
            isRunning: false
        )
        let newer = InstalledApp(
            name: "Arc",
            bundleURL: URL(fileURLWithPath: "/Applications/Arc.app"),
            bundleID: "company.thebrowser.Browser",
            bundleSizeBytes: 1,
            isRunning: false
        )
        let sorted = AppSortOption.nameAZ.sorted([older, newer])
        #expect(sorted.map(\.name) == ["Arc", "zoom"])
    }
}
