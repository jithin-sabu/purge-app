import Foundation
import Testing
@testable import Purge

/// Unity's package cache and Asset Store downloads (#474). Both are Dev Tools
/// rows at Check First, and nothing else in `~/Library/Unity` is offered.
/// Editors are never offered: Everything else points at Unity Hub instead.
@Suite("Unity caches (#474): offered, never Safe")
struct UnityCacheTests {
    private static var home: String { DeletionSafetyPolicy.cachedHomePath }

    private static func evaluate(_ relative: String) -> DeletionSafetyDecision {
        DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "\(home)/\(relative)"))
    }

    /// A throwaway home, so building the row list reads no real folder.
    private static func makeHome(_ name: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("unity-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    // MARK: Package cache

    /// The layout up to 2023.2 (`npm`, `packages`, `git-lfs`) and Unity 6's
    /// (`db`, `git-lfs`), from Unity's docs.
    @Test(arguments: [
        "Library/Unity/cache",
        "Library/Unity/cache/npm/packages.unity.com/com.unity.textmeshpro",
        "Library/Unity/cache/packages/packages.unity.com/com.unity.textmeshpro@3.0.6",
        "Library/Unity/cache/git-lfs",
        "Library/Caches/Unity/upm",
        "Library/Caches/Unity/upm/db/packages.unity.com/content",
        "Library/Caches/Unity/upm/git-lfs",
    ])
    func packageCacheIsOffered(relative: String) {
        #expect(Self.evaluate(relative) == .allow, "\(relative)")
    }

    @Test
    func devToolsScanListsBothCacheFolders() throws {
        let home = try Self.makeHome("claimed")
        defer { try? FileManager.default.removeItem(at: home) }
        let claimed = DevScanner.claimedGlobalCachePaths(home: home)
        for relative in ["Library/Unity/cache", "Library/Caches/Unity/upm", "Library/Caches/Unity"] {
            #expect(claimed.contains(home.appendingPathComponent(relative).standardizedFileURL.path), "\(relative)")
        }
    }

    /// A project with no `Library` folder fetches its packages again, which
    /// needs a connection, so Clean Safe Items and scheduled cleans must not
    /// take the cache.
    @Test
    func packageCacheIsNeverSafe() {
        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: "Unity Package Cache", primaryPath: nil).level == .medium)
        #expect(ExplanationDatabase.record(forKey: "unity-package-cache")?.safetyLevel == .medium)
    }

    /// The folder Unity 6's cache sits in is not this row. It has no entry, so
    /// App Caches doesn't list it, and the cache is not offered twice.
    @Test
    func unity6ParentFolderStaysNotSure() {
        let path = URL(fileURLWithPath: "\(Self.home)/Library/Caches/Unity", isDirectory: true)
        let info = ExplanationResolver.initialSafetyForCacheFolder(folderName: "Unity", friendlyHeadline: "Unity", path: path)
        #expect(info.level == .unknown)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "Unity") == nil)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "cache") == nil)
    }

    // MARK: Asset Store downloads

    @Test(arguments: [
        "Library/Unity/Asset Store-5.x",
        "Library/Unity/Asset Store-5.x/Unity Technologies/3D ModelsCharacters/Robot Kyle URP.unitypackage",
        "Library/Unity/Asset Store-6.x",
        "Library/Unity/Asset Store-12.x/Publisher",
        "Library/Unity/Asset Store",
        "Library/Unity/Asset Store/Publisher/Pack.unitypackage",
    ])
    func assetStoreDownloadsAreOffered(relative: String) {
        #expect(Self.evaluate(relative) == .allow, "\(relative)")
    }

    @Test(arguments: [
        ("Asset Store-5.x", true),
        ("Asset Store-12.x", true),
        ("Asset Store", true),
        ("Asset Store-", false),
        ("Asset Store-.x", false),
        ("Asset Store-5", false),
        ("Asset Store-5.x.bak", false),
        ("Asset Store-x.x", false),
        ("Asset Store-٥.x", false),
        ("Asset Store 5.x", false),
        ("Asset Stores", false),
        ("asset store-5.x", false),
        ("My Asset Store-5.x", false),
    ])
    func assetStoreNames(name: String, matches: Bool) {
        #expect(DeletionSafetyPolicy.isUnityAssetStoreFolderName(name) == matches, "\(name)")
    }

    /// These download again only from My Assets with the Unity account, and a
    /// package taken off the store may not come back.
    @Test
    func assetStoreDownloadsAreNeverSafe() {
        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: "Unity Asset Store Downloads", primaryPath: nil).level == .medium)
        #expect(ExplanationDatabase.record(forKey: "unity-asset-store")?.safetyLevel == .medium)
    }

    /// The scan lists each Asset Store folder by name, and nothing else in
    /// `~/Library/Unity`. A file or a link with such a name is not a row.
    @Test
    func devToolsScanListsOnlyAssetStoreFolders() throws {
        let fm = FileManager.default
        let home = try Self.makeHome("asset-store")
        defer { try? fm.removeItem(at: home) }
        let unity = home.appendingPathComponent("Library/Unity", isDirectory: true)
        for name in ["Asset Store-5.x", "Asset Store", "cache", "Licenses", "Asset Store-5.x old", "config"] {
            try fm.createDirectory(at: unity.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        try Data("notes".utf8).write(to: unity.appendingPathComponent("Asset Store-6.x"))
        let elsewhere = home.appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: unity.appendingPathComponent("Asset Store-7.x"), withDestinationURL: elsewhere)
        let names = DevScanner.unityAssetStorePaths(home: home).map(\.lastPathComponent)
        #expect(names == ["Asset Store", "Asset Store-5.x"])
        let claimed = DevScanner.claimedGlobalCachePaths(home: home)
        #expect(claimed.contains(unity.appendingPathComponent("Asset Store-5.x").standardizedFileURL.path))
        #expect(!claimed.contains(unity.appendingPathComponent("Licenses").standardizedFileURL.path))
    }

    @Test
    func noUnityFolderListsNothing() throws {
        let home = try Self.makeHome("empty")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(DevScanner.unityAssetStorePaths(home: home).isEmpty)
    }

    // MARK: What stays

    /// `~/Library/Unity` itself, anything else in it, and Unity's settings,
    /// licences and projects.
    @Test(arguments: [
        "Library/Unity",
        "Library/Unity/Licenses",
        "Library/Unity/config",
        "Library/Unity/cache-old",
        "Library/Unity/Asset Store-5.x old",
        "Library/Unity/Unity Hub",
        "Library/Application Support/Unity",
        "Library/Application Support/UnityHub",
        "Library/Preferences/com.unity3d.UnityEditor5.x.plist",
        "Unity Projects/Racer/Assets",
    ])
    func unityDataStaysOut(relative: String) {
        #expect(Self.evaluate(relative) != .allow, "\(relative)")
    }

    @Test(arguments: [
        "/Applications/Unity",
        "/Applications/Unity/Hub/Editor/6000.0.23f1",
        "/Applications/Unity/Hub/Editor/6000.0.23f1/Unity.app",
        "/Applications/Unity Hub.app",
    ])
    func editorsAreNeverOffered(path: String) {
        #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: path)) != .allow, "\(path)")
    }

    // MARK: Links

    /// The allowlist and the Asset Store rule both compare path text. With
    /// `~/Library/Unity` a link to `~/Developer`, a move would take a folder in
    /// `~/Developer`, so the link guards refuse every Unity row.
    @Test(arguments: ["none", "Library/Unity", "Library/Unity/cache", "Library/Unity/Asset Store-5.x"])
    func rowsReachedThroughALinkAreRefused(link: String) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("unity-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let unity = home.appendingPathComponent("Library/Unity", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Developer", isDirectory: true)
        let cache = unity.appendingPathComponent("cache", isDirectory: true)
        let store = unity.appendingPathComponent("Asset Store-5.x", isDirectory: true)

        switch link {
        case "Library/Unity":
            for name in ["cache/npm", "Asset Store-5.x/Publisher"] {
                try fm.createDirectory(at: elsewhere.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
            }
            try fm.createDirectory(at: unity.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: unity, withDestinationURL: elsewhere)
        case "none":
            try fm.createDirectory(at: cache.appendingPathComponent("npm", isDirectory: true), withIntermediateDirectories: true)
            try fm.createDirectory(at: store.appendingPathComponent("Publisher", isDirectory: true), withIntermediateDirectories: true)
        default:
            try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try fm.createDirectory(at: unity, withIntermediateDirectories: true)
            let linked = home.appendingPathComponent(link, isDirectory: true)
            try fm.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
            for url in [cache, store] where url != linked {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }

        let cacheRefused = DeletionSafetyPolicy.allowlistLinkRefusesDeletion(cache, home: home.path)
        let storeRefused = DeletionSafetyPolicy.shapeLinkRefusesDeletion(standardizedPath: store.path, home: home.path)
        switch link {
        case "none":
            #expect(!cacheRefused)
            #expect(!storeRefused)
        case "Library/Unity":
            #expect(cacheRefused)
            #expect(storeRefused)
        case "Library/Unity/cache":
            #expect(cacheRefused)
            #expect(!storeRefused)
        default:
            #expect(!cacheRefused)
            #expect(storeRefused)
        }
    }

    // MARK: Everything else hint

    private static let hintHome = URL(fileURLWithPath: "/Users/alice", isDirectory: true)

    @Test(arguments: [
        "/Applications/Unity",
        "/Applications/Unity/Hub",
        "/Applications/Unity/Hub/Editor",
        "/Applications/Unity/Hub/Editor/2022.3.45f1",
    ])
    func editorFoldersPointToUnityHub(path: String) throws {
        let hint = try #require(EverythingElseFolderHint.hint(for: path, group: .otherApps, home: Self.hintHome, steamGames: [:]))
        #expect(hint.action == .openApp(bundleID: "com.unity3d.unityhub", title: String(localized: "Open Unity Hub")))
        #expect(hint.steps.contains("Uninstall"))
    }

    @Test(arguments: [
        "/Applications/Unity Hub.app",
        "/Applications/Unityx",
        "/Applications/Unity/Other",
        "/Users/alice/Library/Unity",
    ])
    func otherFoldersGetNoUnityHint(path: String) {
        let hint = EverythingElseFolderHint.hint(for: path, group: .otherApps, home: Self.hintHome, steamGames: [:])
        #expect(hint?.action != .openApp(bundleID: "com.unity3d.unityhub", title: String(localized: "Open Unity Hub")))
    }
}
