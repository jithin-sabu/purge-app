import Foundation
import Testing
@testable import Purge

/// A folder in `~/Library/Caches` with no `explanations.json` entry is Safe when
/// it holds nothing but a Chromium browser's disk caches, laid out as Chromium
/// writes them there. Anything else in it keeps the folder Not Sure, which hides
/// it. The layouts below are copied from real browsers: Yab writes
/// `Yab/Chromium/<space>/Cache` and `Code Cache`, Chrome writes
/// `Google/Chrome/<profile>/Cache`.
@Suite("Library/Caches browser caches: Chromium shape")
struct LibraryCachesBrowserShapeTests {
    /// A fresh `<temp>/Library/Caches`, removed by the caller.
    private func makeCaches() throws -> (caches: URL, cleanup: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-caches-\(UUID().uuidString)", isDirectory: true)
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return (caches, root)
    }

    /// Folders and empty files under `root`.
    private func lay(_ root: URL, folders: [String], files: [String] = []) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in folders {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in files {
            try fm.createDirectory(
                at: root.appendingPathComponent(file).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: root.appendingPathComponent(file))
        }
    }

    private func tier(_ folder: URL) -> SafetyLevel? {
        SafetyTierList.evaluate(folderName: folder.lastPathComponent, path: folder)
    }

    /// Yab's folder exactly as it is on a real Mac.
    private static let yabFolders = [
        "Chromium/Default/Cache/Cache_Data", "Chromium/Default/Cache/No_Vary_Search",
        "Chromium/Default/Code Cache/js", "Chromium/Default/Code Cache/wasm",
        "Chromium/space-00000000-0000-0000-0000-000000000001/Cache/Cache_Data",
        "Chromium/space-00000000-0000-0000-0000-000000000001/Cache/No_Vary_Search",
        "Chromium/space-00000000-0000-0000-0000-000000000001/Code Cache/js",
        "Chromium/space-00000000-0000-0000-0000-000000000001/Code Cache/wasm",
    ]

    // MARK: - Safe

    @Test
    func yabLayoutIsSafe() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let browser = caches.appendingPathComponent("NewBrowser", isDirectory: true)
        try lay(browser, folders: Self.yabFolders)

        #expect(CacheDiscoveryPaths.holdsOnlyChromiumDiskCaches(browser))
        #expect(tier(browser) == .safe)
    }

    @Test
    func chromeAndVivaldiLayoutsAreSafe() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let chrome = caches.appendingPathComponent("SomeVendor", isDirectory: true)
        try lay(chrome, folders: [
            "Chrome/Default/Cache/Cache_Data", "Chrome/Default/Code Cache/js",
            "Chrome/Profile 1/Cache/Cache_Data",
        ])
        let vivaldi = caches.appendingPathComponent("SomeBrowser", isDirectory: true)
        try lay(vivaldi, folders: ["Default/Cache/Cache_Data", "Default/GPUCache"])

        #expect(tier(chrome) == .safe)
        #expect(tier(vivaldi) == .safe)
    }

    /// Chromium's older blockfile cache has `index` and `data_0` files in `Cache`.
    @Test
    func blockfileCacheLayoutIsSafe() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let browser = caches.appendingPathComponent("OldBrowser", isDirectory: true)
        try lay(browser, folders: ["Default/Cache"], files: ["Default/Cache/index", "Default/Cache/data_0"])

        #expect(tier(browser) == .safe)
    }

    /// Finder writes `.DS_Store` into any folder it shows.
    @Test
    func finderDSStoreIsAllowed() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let browser = caches.appendingPathComponent("NewBrowser", isDirectory: true)
        try lay(browser, folders: Self.yabFolders, files: [".DS_Store", "Chromium/.DS_Store"])

        #expect(tier(browser) == .safe)
    }

    // MARK: - Not Sure

    /// An app that keeps anything but caches here, such as Yab's own
    /// `dev.serafim.fast` folder with `Cache.db` and WebKit's `CacheStorage`.
    @Test
    func aFileAnywhereKeepsItNotSure() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let top = caches.appendingPathComponent("TopFile", isDirectory: true)
        try lay(top, folders: Self.yabFolders, files: ["Cache.db"])
        let profile = caches.appendingPathComponent("ProfileFile", isDirectory: true)
        try lay(profile, folders: Self.yabFolders, files: ["Chromium/Default/Local State"])
        let webKit = caches.appendingPathComponent("WebKitApp", isDirectory: true)
        try lay(webKit, folders: ["WebKit/NetworkCache/Version 17/Records", "WebKit/CacheStorage", "fsCachedData"],
                files: ["Cache.db", "WebKit/CacheStorage/salt"])

        #expect(tier(top) == nil)
        #expect(tier(profile) == nil)
        #expect(tier(webKit) == nil)
    }

    /// Service Worker caches hold installed web apps' offline content and push
    /// subscriptions (see `docs/safety-notes.md`, 2026-11-07). A folder with
    /// one is never Safe by this shape, nor is one with a profile's data.
    @Test
    func serviceWorkerOrProfileDataKeepsItNotSure() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let worker = caches.appendingPathComponent("Worker", isDirectory: true)
        try lay(worker, folders: Self.yabFolders + ["Chromium/Default/Service Worker/CacheStorage"])
        let script = caches.appendingPathComponent("Script", isDirectory: true)
        try lay(script, folders: Self.yabFolders + ["Chromium/Default/Service Worker/ScriptCache"])
        let indexedDB = caches.appendingPathComponent("Data", isDirectory: true)
        try lay(indexedDB, folders: Self.yabFolders + ["Chromium/Default/IndexedDB/https_example.com_0.indexeddb.leveldb"])

        #expect(tier(worker) == nil)
        #expect(tier(script) == nil)
        #expect(tier(indexedDB) == nil)
    }

    /// The name `Cache` is not enough: it needs Chromium's layout, and at least
    /// one such `Cache` must be there.
    @Test
    func cacheWithoutChromiumLayoutKeepsItNotSure() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let plain = caches.appendingPathComponent("PlainCache", isDirectory: true)
        try lay(plain, folders: ["Default/Cache/Cache_Data", "Other/Cache"])
        let codeOnly = caches.appendingPathComponent("CodeOnly", isDirectory: true)
        try lay(codeOnly, folders: ["Default/Code Cache/js", "Default/GPUCache"])
        let empty = caches.appendingPathComponent("Empty", isDirectory: true)
        try lay(empty, folders: ["Default"])

        #expect(tier(plain) == nil)
        #expect(tier(codeOnly) == nil)
        #expect(tier(empty) == nil)
    }

    /// A link is never followed: behind it the only evidence left is a name.
    @Test
    func linksKeepItNotSure() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let fm = FileManager.default
        let elsewhere = cleanup.appendingPathComponent("Elsewhere", isDirectory: true)
        try lay(elsewhere, folders: Self.yabFolders)

        let linkedProfile = caches.appendingPathComponent("LinkedProfile", isDirectory: true)
        try lay(linkedProfile, folders: ["Chromium/Default/Cache/Cache_Data"])
        try fm.createSymbolicLink(
            at: linkedProfile.appendingPathComponent("Chromium/space-1"),
            withDestinationURL: elsewhere.appendingPathComponent("Chromium/Default")
        )
        let linkedCache = caches.appendingPathComponent("LinkedCache", isDirectory: true)
        try lay(linkedCache, folders: ["Chromium/Default/Code Cache/js"])
        try fm.createSymbolicLink(
            at: linkedCache.appendingPathComponent("Chromium/Default/Cache"),
            withDestinationURL: elsewhere.appendingPathComponent("Chromium/Default/Cache")
        )
        let linkedTop = caches.appendingPathComponent("LinkedTop", isDirectory: true)
        try fm.createSymbolicLink(at: linkedTop, withDestinationURL: elsewhere)

        #expect(tier(linkedProfile) == nil)
        #expect(tier(linkedCache) == nil)
        #expect(tier(linkedTop) == nil)
    }

    @Test
    func hiddenEntryKeepsItNotSure() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let browser = caches.appendingPathComponent("Hidden", isDirectory: true)
        try lay(browser, folders: Self.yabFolders + ["Chromium/.backup"])

        #expect(tier(browser) == nil)
    }

    /// Profiles at most three folders down, as `cachesFolderChromiumMaxDepth` says.
    @Test
    func tooDeepKeepsItNotSure() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let deepest = caches.appendingPathComponent("Deepest", isDirectory: true)
        try lay(deepest, folders: ["a/b/c/Cache/Cache_Data"])
        let tooDeep = caches.appendingPathComponent("TooDeep", isDirectory: true)
        try lay(tooDeep, folders: ["a/b/c/d/Cache/Cache_Data"])

        #expect(tier(deepest) == .safe)
        #expect(tier(tooDeep) == nil)
    }

    // MARK: - Where the rule applies

    /// Only a folder directly in a `Library/Caches` folder. The same shape in
    /// Application Support, deeper in Caches, or anywhere else is not lifted.
    @Test
    func onlyFoldersDirectlyInLibraryCaches() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let support = cleanup.appendingPathComponent("Library/Application Support/NewBrowser", isDirectory: true)
        try lay(support, folders: Self.yabFolders)
        let nested = caches.appendingPathComponent("Vendor/NewBrowser", isDirectory: true)
        try lay(nested, folders: Self.yabFolders)
        let documents = cleanup.appendingPathComponent("Documents/NewBrowser", isDirectory: true)
        try lay(documents, folders: Self.yabFolders)

        #expect(tier(support) == nil)
        #expect(tier(nested) == nil)
        #expect(tier(documents) == nil)
        #expect(SafetyTierList.evaluate(folderName: "NewBrowser") == nil)
    }

    /// The shape only lifts a folder that would be Not Sure. A name the tier list
    /// marks Check First stays Check First.
    @Test
    func knownCheckFirstNameStaysCheckFirst() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let dropbox = caches.appendingPathComponent("com.dropbox.client2", isDirectory: true)
        try lay(dropbox, folders: Self.yabFolders)

        #expect(tier(dropbox) == .medium)
    }

    /// A row the scan builds for such a folder reads as Safe to Clean.
    @Test
    func resolverGivesTheRowSafe() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let browser = caches.appendingPathComponent("NewBrowser", isDirectory: true)
        try lay(browser, folders: Self.yabFolders)

        let info = ExplanationResolver.initialSafetyForCacheFolder(
            folderName: "NewBrowser",
            friendlyHeadline: "NewBrowser",
            path: browser
        )
        #expect(info.level == .safe)
    }

    // MARK: - Yab's own entry

    /// Yab's `~/Library/Caches/Yab` folder is Safe by its entry. Its bundle ID
    /// folder, `dev.serafim.fast`, holds `Cache.db` and WebKit's `CacheStorage`,
    /// so the entry must not reach it.
    @Test
    func yabEntryCoversOnlyItsChromiumFolder() throws {
        #expect(ExplanationDatabase.definitionKey(forFolderName: "Yab") == "yab")
        let record = try #require(ExplanationDatabase.matchBundledDatabase(folderName: "Yab"))
        #expect(ExplanationDatabase.safetyInfo(from: record).level == .safe)
        #expect(ExplanationDatabase.definitionKey(forFolderName: "dev.serafim.fast") == nil)
    }
}
