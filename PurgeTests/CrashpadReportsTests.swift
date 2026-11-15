import Foundation
import Testing
@testable import Purge

/// Crashpad keeps finished crash reports in `pending` until it sends them, and
/// some apps pile up gigabytes there (#367). Purge offers `pending` only inside a
/// real Crashpad database, up to two folders below the app's Application Support
/// folder, on its own Check First row. Everything here runs in a temporary home.
@Suite("Crashpad crash reports")
struct CrashpadReportsTests {
    private struct FakeHome {
        let home: URL

        var support: URL {
            home.appendingPathComponent("Library/Application Support", isDirectory: true)
        }

        /// An app folder with `folders` inside and empty `files`.
        @discardableResult
        func app(_ name: String, folders: [String] = [], files: [String] = []) throws -> URL {
            let fm = FileManager.default
            let root = support.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for folder in folders {
                try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for file in files {
                try Data().write(to: root.appendingPathComponent(file))
            }
            return root
        }

        /// What Crashpad makes every time an app starts, at `crashpad` inside `appRoot`.
        func crashpadDatabase(in appRoot: URL, at crashpad: String = "Crashpad") throws {
            let fm = FileManager.default
            let folder = appRoot.appendingPathComponent(crashpad, isDirectory: true)
            for name in ["new", "pending", "completed", "attachments"] {
                try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try Data().write(to: folder.appendingPathComponent("settings.dat"))
        }

        func listed(_ appRoot: URL) -> [String] {
            let prefix = appRoot.standardizedFileURL.path + "/"
            return CacheDiscoveryPaths.applicationSupportCacheURLs(in: appRoot, access: .full)
                .map { String($0.path.dropFirst(prefix.count)) }
                .sorted()
        }

        func allowed(_ appRoot: URL, _ relative: String) -> Bool {
            let path = appRoot.standardizedFileURL.path + "/" + relative
            return DeletionSafetyPolicy.isWhitelistedApplicationSupportCachePath(path, home: home.standardizedFileURL.path)
        }
    }

    private func makeHome() throws -> FakeHome {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-crashpad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FakeHome(home: url)
    }

    /// `pending` needs Crashpad's own `settings.dat` and `new` next to it. Before
    /// they exist only `completed` is offered, by its name, as before.
    @Test
    func pendingNeedsACrashpadDatabase() throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("Codex", folders: ["Crashpad/completed", "Crashpad/pending"])
        #expect(fake.listed(root) == ["Crashpad/completed"])
        #expect(!fake.allowed(root, "Crashpad/pending"))

        try Data().write(to: root.appendingPathComponent("Crashpad/settings.dat"))
        #expect(!fake.allowed(root, "Crashpad/pending"), "settings.dat without new")

        try fake.crashpadDatabase(in: root)
        #expect(fake.listed(root) == ["Crashpad/completed", "Crashpad/pending"])
        #expect(fake.allowed(root, "Crashpad/pending"))
    }

    /// A `settings.dat` that is a folder is not Crashpad's.
    @Test
    func settingsMustBeAFile() throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("SomeApp", folders: ["Crashpad/new", "Crashpad/pending", "Crashpad/settings.dat"])
        #expect(fake.listed(root).isEmpty)
        #expect(!fake.allowed(root, "Crashpad/pending"))
    }

    /// Codex keeps its database in `com.openai.codex/web/Crashpad`, Figma in
    /// `Figma/DesktopProfile/v43/Crashpad`. Both report folders are offered there,
    /// and only with Crashpad's layout: a name that deep is not enough by itself.
    @Test(arguments: [("com.openai.codex", "web"), ("Figma", "DesktopProfile/v43")])
    func deeperDatabasesAreFound(app: String, between: String) throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app(app, folders: ["\(between)/Crashpad/completed", "\(between)/Crashpad/pending"])
        #expect(fake.listed(root).isEmpty)
        #expect(!fake.allowed(root, "\(between)/Crashpad/completed"))
        #expect(!fake.allowed(root, "\(between)/Crashpad/pending"))

        try fake.crashpadDatabase(in: root, at: "\(between)/Crashpad")
        #expect(fake.listed(root) == ["\(between)/Crashpad/completed", "\(between)/Crashpad/pending"])
        #expect(fake.allowed(root, "\(between)/Crashpad/completed"))
        #expect(fake.allowed(root, "\(between)/Crashpad/pending"))
    }

    /// Three folders down is past the walk, so it is neither listed nor allowed.
    @Test
    func threeFoldersDownIsTooDeep() throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("Deep")
        try fake.crashpadDatabase(in: root, at: "a/b/c/Crashpad")
        #expect(fake.listed(root).isEmpty)
        #expect(!fake.allowed(root, "a/b/c/Crashpad/pending"))
        #expect(!fake.allowed(root, "a/b/c/Crashpad/completed"))
    }

    /// Only the two finished-report folders. `new` holds reports still being
    /// written, and the database itself holds the app's crash upload settings.
    @Test(arguments: ["Crashpad", "Crashpad/new", "Crashpad/attachments", "Crashpad/settings.dat",
                      "Crashpad/pending/report.dmp", "web/Crashpad/new"])
    func nothingElseInTheDatabaseIsAllowed(relative: String) throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("Codex")
        try fake.crashpadDatabase(in: root)
        try fake.crashpadDatabase(in: root, at: "web/Crashpad")
        try Data().write(to: root.appendingPathComponent("Crashpad/pending/report.dmp"))
        #expect(!fake.allowed(root, relative))
    }

    /// A link on the way down, a hidden folder, or a `pending` that is itself a
    /// link is never listed or allowed: discovery never follows one.
    @Test
    func linksAndHiddenFoldersAreLeftOut() throws {
        let fm = FileManager.default
        let fake = try makeHome()
        defer { try? fm.removeItem(at: fake.home) }
        let elsewhere = fake.home.appendingPathComponent("Elsewhere", isDirectory: true)
        try fake.crashpadDatabase(in: elsewhere, at: "web/Crashpad")

        let root = try fake.app("Linked")
        try fm.createSymbolicLink(at: root.appendingPathComponent("web"),
                                  withDestinationURL: elsewhere.appendingPathComponent("web"))
        try fake.crashpadDatabase(in: root, at: ".hidden/Crashpad")
        try fake.crashpadDatabase(in: root)
        try fm.removeItem(at: root.appendingPathComponent("Crashpad/pending"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Crashpad/pending"),
                                  withDestinationURL: elsewhere.appendingPathComponent("web/Crashpad/pending"))

        #expect(fake.listed(root) == ["Crashpad/completed"])
        for relative in ["web/Crashpad/pending", "web/Crashpad/completed", ".hidden/Crashpad/pending",
                         "Crashpad/pending"] {
            #expect(!fake.allowed(root, relative), "\(relative)")
        }
    }

    /// The app folder itself must be a real, visible folder. Through a link the
    /// move would reach a `pending` folder outside Application Support.
    @Test
    func appFolderMustBeRealAndVisible() throws {
        let fm = FileManager.default
        let fake = try makeHome()
        defer { try? fm.removeItem(at: fake.home) }
        let elsewhere = fake.home.appendingPathComponent("Elsewhere", isDirectory: true)
        try fake.crashpadDatabase(in: elsewhere)
        try fake.crashpadDatabase(in: elsewhere, at: "web/Crashpad")

        try fm.createDirectory(at: fake.support, withIntermediateDirectories: true)
        let linked = fake.support.appendingPathComponent("Linked", isDirectory: true)
        try fm.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
        let dotted = try fake.app(".Dotted")
        try fake.crashpadDatabase(in: dotted)
        let flagged = try fake.app("Flagged")
        try fake.crashpadDatabase(in: flagged)
        try setHidden(flagged)

        for relative in ["Crashpad/pending", "web/Crashpad/pending", "web/Crashpad/completed"] {
            #expect(!fake.allowed(linked, relative), "Linked/\(relative)")
        }
        #expect(!fake.allowed(dotted, "Crashpad/pending"))
        #expect(!fake.allowed(flagged, "Crashpad/pending"))
    }

    /// A folder with Finder's hidden flag is left out like one whose name starts
    /// with a dot, wherever it is: the database, a folder above it, or `pending`.
    @Test(arguments: ["web", "web/Crashpad", "web/Crashpad/pending"])
    func hiddenFlagIsLeftOut(hidden: String) throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("Codex")
        try fake.crashpadDatabase(in: root, at: "web/Crashpad")
        try setHidden(root.appendingPathComponent(hidden, isDirectory: true))

        #expect(!fake.listed(root).contains("web/Crashpad/pending"))
        #expect(!fake.allowed(root, "web/Crashpad/pending"))
    }

    private func setHidden(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
        url.removeAllCachedResourceValues()
        try #require((try url.resourceValues(forKeys: [.isHiddenKey])).isHidden == true)
    }

    /// The gate allows exactly what discovery lists, with Crashpad databases at
    /// every depth next to an Electron app's caches and data.
    @Test
    func gateAllowsExactlyWhatDiscoveryLists() throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app(
            "com.openai.codex",
            folders: ["web/GPUCache", "web/IndexedDB", "web/Local Storage/leveldb", "Crashpad-old/pending"],
            files: ["web/Local State", "web/Preferences"]
        )
        try fake.crashpadDatabase(in: root)
        try fake.crashpadDatabase(in: root, at: "web/Crashpad")
        try fake.crashpadDatabase(in: root, at: "Profiles/v2/Crashpad")
        try Data().write(to: root.appendingPathComponent("web/Crashpad/pending/a.dmp"))
        try Data().write(to: root.appendingPathComponent("web/Crashpad/pending/a_sidecar.json"))

        let listed = fake.listed(root)
        #expect(listed == [
            "Crashpad/completed", "Crashpad/pending",
            "Profiles/v2/Crashpad/completed", "Profiles/v2/Crashpad/pending",
            "web/Crashpad/completed", "web/Crashpad/pending", "web/GPUCache",
        ])
        let everything = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        #expect(everything.filter { fake.allowed(root, $0) }.sorted() == listed)
    }

    /// Unsent reports are Check First wherever they are, even in an app whose own
    /// entry is Safe, so Clean Safe Items and scheduled cleans never take them.
    @Test(arguments: ["Codex", "Claude", "Code", "SomeApp"])
    func pendingIsCheckFirst(app: String) {
        let path = URL(fileURLWithPath: "/Users/alice/Library/Application Support/\(app)/web/Crashpad/pending",
                       isDirectory: true)
        #expect(SafetyTierList.evaluate(folderName: app, path: path) == .medium)
        let info = ExplanationResolver.initialSafetyForCacheFolder(
            folderName: CacheDiscoveryPaths.crashpadPendingKey,
            friendlyHeadline: CacheDiscoveryPaths.crashpadPendingKey,
            path: path
        )
        #expect(info.level == .medium)
        #expect(info.headline == "Unsent Crash Reports")
        #expect(ExplanationDatabase.definitionKey(forFolderName: CacheDiscoveryPaths.crashpadPendingKey)
            == "crashpad-pending")

        let completed = path.deletingLastPathComponent().appendingPathComponent("completed", isDirectory: true)
        #expect(SafetyTierList.evaluate(folderName: app, path: completed) == .safe)
    }

    /// The row and tier come from the last two names. `pending` anywhere else,
    /// like electron-updater's download folder, is not a crash report folder.
    @Test
    func pendingFolderIsKnownByItsParent() {
        let base = URL(fileURLWithPath: "/Users/alice/Library", isDirectory: true)
        #expect(CacheDiscoveryPaths.isCrashpadPendingFolder(
            base.appendingPathComponent("Application Support/Codex/Crashpad/pending")))
        #expect(!CacheDiscoveryPaths.isCrashpadPendingFolder(
            base.appendingPathComponent("Caches/t3code-updater/pending")))
        #expect(!CacheDiscoveryPaths.isCrashpadPendingFolder(
            base.appendingPathComponent("Application Support/Codex/Crashpad/completed")))
    }

    /// The scan puts `pending` on the shared row even in an app whose own entry
    /// is Safe. On the app's row that entry would decide, so Clean Safe Items and
    /// scheduled cleans would take the reports. `completed` stays on the app's row.
    @Test(arguments: [("Claude", "claude-app"), ("Code", "vscode"), ("Slack", "slack")])
    func pendingLeavesASafeAppsRow(app: String, entry: String) {
        let pending = URL(fileURLWithPath: "/Users/alice/Library/Application Support/\(app)/Crashpad/pending",
                          isDirectory: true)
        #expect(ExplanationDatabase.definitionKey(forFolderName: app) == entry)
        #expect(ExplanationResolver.initialSafetyForCacheFolder(
            folderName: app, friendlyHeadline: "\(app) Cache", path: pending
        ).level == .safe, "the app's own entry is Safe, so the row swap is what keeps pending Check First")

        let row = CacheScanner.applicationSupportRow(for: pending, appFolderName: app, groupKey: nil)
        let name = row.classificationName ?? app
        let info = ExplanationResolver.initialSafetyForCacheFolder(folderName: name, friendlyHeadline: row.headline,
                                                                   path: pending)
        #expect(info.level == .medium)
        #expect(info.headline == "Unsent Crash Reports")
        #expect((row.groupKey ?? ExplanationDatabase.definitionKey(forFolderName: name)) == "crashpad-pending")

        let completed = pending.deletingLastPathComponent().appendingPathComponent("completed", isDirectory: true)
        let appRow = CacheScanner.applicationSupportRow(for: completed, appFolderName: app, groupKey: nil)
        #expect(appRow.classificationName == nil)
        #expect(appRow.headline == "\(app) Cache")
    }

    /// An app with no entry keeps its own group key for everything but `pending`.
    @Test
    func pendingLeavesAnUnknownAppsGroup() {
        let root = URL(fileURLWithPath: "/Users/alice/Library/Application Support/SomeApp", isDirectory: true)
        let group = CacheDiscoveryPaths.applicationSupportGroupKey(appFolderName: "SomeApp")
        let pending = CacheScanner.applicationSupportRow(
            for: root.appendingPathComponent("web/Crashpad/pending"), appFolderName: "SomeApp", groupKey: group)
        #expect(pending.groupKey == nil)
        #expect(pending.classificationName == CacheDiscoveryPaths.crashpadPendingKey)
        let cache = CacheScanner.applicationSupportRow(
            for: root.appendingPathComponent("GPUCache"), appFolderName: "SomeApp", groupKey: group)
        #expect(cache.groupKey == group)
    }
}
