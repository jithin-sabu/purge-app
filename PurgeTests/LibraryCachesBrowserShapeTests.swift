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
    /// A throwaway home with its `Library/Caches`, removed by the caller.
    private func makeCaches() throws -> (caches: URL, cleanup: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-caches-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return (caches, root)
    }

    /// The throwaway home a folder in its `Library/Caches` belongs to.
    private func home(of folder: URL) -> String {
        var url = folder.standardizedFileURL
        while url.lastPathComponent != "Library", url.path != "/" { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent().path
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

    private func tier(_ folder: URL, home: String? = nil) -> SafetyLevel? {
        SafetyTierList.evaluate(folderName: folder.lastPathComponent, path: folder, home: home ?? self.home(of: folder))
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

    /// Only a `.DS_Store` file. A folder or a link with that name is looked at
    /// like anything else, and fails.
    @Test
    func dsStoreFolderOrLinkKeepsItNotSure() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let folder = caches.appendingPathComponent("DSFolder", isDirectory: true)
        try lay(folder, folders: Self.yabFolders + ["Chromium/.DS_Store/IndexedDB"], files: ["Chromium/.DS_Store/Cookies"])
        let link = caches.appendingPathComponent("DSLink", isDirectory: true)
        try lay(link, folders: Self.yabFolders)
        try FileManager.default.createSymbolicLink(
            at: link.appendingPathComponent(".DS_Store"),
            withDestinationURL: cleanup.appendingPathComponent("Documents", isDirectory: true)
        )

        #expect(tier(folder) == nil)
        #expect(tier(link) == nil)
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

        let emptyWorker = caches.appendingPathComponent("EmptyWorker", isDirectory: true)
        try lay(emptyWorker, folders: Self.yabFolders + ["Chromium/Default/Service Worker"])

        #expect(tier(worker) == nil)
        #expect(tier(script) == nil)
        #expect(tier(indexedDB) == nil)
        #expect(tier(emptyWorker) == nil)
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

        // The blockfile markers must be files: a folder or a link with their names fails.
        let folderMarkers = caches.appendingPathComponent("FolderMarkers", isDirectory: true)
        try lay(folderMarkers, folders: ["Default/Cache/index", "Default/Cache/data_0"])
        let linkedMarkers = caches.appendingPathComponent("LinkedMarkers", isDirectory: true)
        try lay(linkedMarkers, folders: ["Default/Cache"], files: ["Default/Cache/index"])
        try lay(cleanup, folders: [], files: ["data_0"])
        try FileManager.default.createSymbolicLink(
            at: linkedMarkers.appendingPathComponent("Default/Cache/data_0"),
            withDestinationURL: cleanup.appendingPathComponent("data_0")
        )

        #expect(tier(plain) == nil)
        #expect(tier(codeOnly) == nil)
        #expect(tier(empty) == nil)
        #expect(tier(folderMarkers) == nil)
        #expect(tier(linkedMarkers) == nil)
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
        let linkedData = caches.appendingPathComponent("LinkedData", isDirectory: true)
        try lay(linkedData, folders: ["Chromium/Default/Cache"])
        try fm.createSymbolicLink(
            at: linkedData.appendingPathComponent("Chromium/Default/Cache/Cache_Data"),
            withDestinationURL: elsewhere.appendingPathComponent("Chromium/Default/Cache/Cache_Data")
        )

        #expect(tier(linkedProfile) == nil)
        #expect(tier(linkedCache) == nil)
        #expect(tier(linkedTop) == nil)
        #expect(tier(linkedData) == nil)
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

    /// Only a folder directly in the home's `Library/Caches`. The same shape in a
    /// sandboxed app's `Data/Library/Caches`, in Application Support, deeper in
    /// Caches, or anywhere else is not lifted.
    @Test
    func onlyFoldersDirectlyInHomeCaches() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.path
        let container = cleanup.appendingPathComponent(
            "Library/Containers/com.example.app/Data/Library/Caches/NewBrowser", isDirectory: true
        )
        try lay(container, folders: Self.yabFolders)
        let support = cleanup.appendingPathComponent("Library/Application Support/NewBrowser", isDirectory: true)
        try lay(support, folders: Self.yabFolders)
        let nested = caches.appendingPathComponent("Vendor/NewBrowser", isDirectory: true)
        try lay(nested, folders: Self.yabFolders)
        let documents = cleanup.appendingPathComponent("Documents/NewBrowser", isDirectory: true)
        try lay(documents, folders: Self.yabFolders)
        let inHome = caches.appendingPathComponent("NewBrowser", isDirectory: true)
        try lay(inHome, folders: Self.yabFolders)

        #expect(tier(container, home: home) == nil)
        #expect(tier(support, home: home) == nil)
        #expect(tier(nested, home: home) == nil)
        #expect(tier(documents, home: home) == nil)
        #expect(tier(inHome, home: home) == .safe)
        // Another user's home, or no path at all.
        #expect(tier(inHome, home: "/Users/someone-else") == nil)
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
            path: browser,
            home: cleanup.path
        )
        #expect(info.level == .safe)
    }

    // MARK: - Right before the move

    /// The rating is read at scan time. Anything the browser writes there
    /// before the clean keeps the folder where it is (#440 review).
    @Test
    func moveReadsTheShapeAgain() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.path
        let check = FileDeleter.defaultImmediateMoveCheck(home: home)
        let browser = caches.appendingPathComponent("NewBrowser", isDirectory: true)
        try lay(browser, folders: Self.yabFolders)
        #expect(tier(browser) == .safe)
        #expect(check(browser))

        try lay(browser, folders: [], files: ["Chromium/Default/Local State"])
        #expect(!SafetyTierList.passesChromiumShapeBoundary(browser, home: home))
        #expect(!check(browser))

        let worker = caches.appendingPathComponent("WorkerLater", isDirectory: true)
        try lay(worker, folders: Self.yabFolders)
        #expect(tier(worker) == .safe)
        #expect(check(worker))
        try lay(worker, folders: ["Chromium/Default/Service Worker/CacheStorage"])
        #expect(!check(worker))
    }

    /// Only a folder that nothing but its shape could rate Safe is read again.
    /// A folder rated by its name, a bundle ID or another rule, and any path
    /// outside the home's Caches, passes as before.
    @Test
    func moveCheckLeavesOtherPathsAlone() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.path
        let chrome = caches.appendingPathComponent("Google", isDirectory: true)
        try lay(chrome, folders: ["Chrome/Default/Cache/Cache_Data"], files: ["Chrome/Default/Local State"])
        let support = cleanup.appendingPathComponent("Library/Application Support/NewBrowser/Cache", isDirectory: true)
        try lay(support, folders: [], files: ["file"])
        let homebrew = caches.appendingPathComponent("Homebrew", isDirectory: true)
        try lay(homebrew, folders: ["downloads"], files: ["downloads/wget.bottle.tar.gz"])
        let slack = caches.appendingPathComponent("com.tinyspeck.slackmacgap", isDirectory: true)
        try lay(slack, folders: [], files: ["Cache.db"])
        let dropbox = caches.appendingPathComponent("com.dropbox.client2", isDirectory: true)
        try lay(dropbox, folders: [], files: ["data.db"])
        // An Electron updater cache, which the scan rates under its own entry.
        let updater = caches.appendingPathComponent("example-updater", isDirectory: true)
        try lay(updater, folders: ["pending"], files: ["pending/installer.zip"])

        for url in [chrome, support, homebrew, slack, dropbox, updater] {
            #expect(!SafetyTierList.dependsOnChromiumShape(url, home: home), "\(url.lastPathComponent)")
            #expect(SafetyTierList.passesChromiumShapeBoundary(url, home: home), "\(url.lastPathComponent)")
        }
        #expect(FileDeleter.defaultImmediateMoveCheck(home: home)(updater))
    }

    /// The move check holds nothing in memory (#452). A scan in one session
    /// rates the folder Safe. The clean runs in another, from a saved row, an
    /// App Intent or another process, where nothing rated it. Here that is a
    /// second home this test process never rated. The folder there gains
    /// profile data before the move, and the move is refused.
    @Test
    func moveReadsTheShapeForAFolderAnotherSessionRated() throws {
        let (sessionOneCaches, sessionOneCleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: sessionOneCleanup) }
        let rated = sessionOneCaches.appendingPathComponent("NewBrowser", isDirectory: true)
        try lay(rated, folders: Self.yabFolders)
        #expect(tier(rated) == .safe)

        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.path
        let check = FileDeleter.defaultImmediateMoveCheck(home: home)
        let browser = caches.appendingPathComponent("NewBrowser", isDirectory: true)
        try lay(browser, folders: Self.yabFolders)
        #expect(SafetyTierList.dependsOnChromiumShape(browser, home: home))
        #expect(check(browser))

        try lay(browser, folders: [], files: ["Chromium/Default/Local State"])
        #expect(!SafetyTierList.passesChromiumShapeBoundary(browser, home: home))
        #expect(!check(browser))

        // The folder session one rated is read again the same way.
        try lay(rated, folders: ["Chromium/Default/Service Worker/CacheStorage"])
        #expect(!SafetyTierList.passesChromiumShapeBoundary(rated, home: self.home(of: rated)))
    }

    /// A folder directly in the home's Caches that no entry or rule knows can
    /// only have been rated Safe by its shape. Without the shape it never moves,
    /// whatever row asked for it.
    @Test
    func moveRefusesAnUnlistedFolderWithoutTheShape() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.path
        let unlisted = caches.appendingPathComponent("com.example.app.updater", isDirectory: true)
        try lay(unlisted, folders: [], files: ["installer.zip"])
        let empty = caches.appendingPathComponent("SomethingNew", isDirectory: true)
        try lay(empty, folders: [])

        for url in [unlisted, empty] {
            #expect(SafetyTierList.dependsOnChromiumShape(url, home: home), "\(url.lastPathComponent)")
            #expect(!SafetyTierList.passesChromiumShapeBoundary(url, home: home), "\(url.lastPathComponent)")
            #expect(!FileDeleter.defaultImmediateMoveCheck(home: home)(url), "\(url.lastPathComponent)")
        }
        // The same folder outside the home's Caches is not this check's to judge.
        let nested = caches.appendingPathComponent("Vendor/SomethingNew", isDirectory: true)
        try lay(nested, folders: [], files: ["data.db"])
        #expect(SafetyTierList.passesChromiumShapeBoundary(nested, home: home))
        #expect(SafetyTierList.passesChromiumShapeBoundary(unlisted, home: "/Users/someone-else"))
    }

    /// A `-updater` folder the shape rated that gains a `pending` folder keeps
    /// its profile folders, so the Electron updater entry doesn't let it skip
    /// the shape. An updater folder with only `pending` and loose files moves
    /// under that entry (#454 review).
    @Test
    func updaterEntryCoversOnlyAnUpdaterLayout() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.path
        let check = FileDeleter.defaultImmediateMoveCheck(home: home)

        let browser = caches.appendingPathComponent("browser-updater", isDirectory: true)
        try lay(browser, folders: Self.yabFolders)
        #expect(tier(browser) == .safe)
        #expect(check(browser))
        try lay(browser, folders: ["pending"], files: ["pending/update.zip", "Chromium/Default/Local State"])
        #expect(CacheDiscoveryPaths.isElectronUpdaterCache(browser))
        #expect(SafetyTierList.dependsOnChromiumShape(browser, home: home))
        #expect(!check(browser))

        let updater = caches.appendingPathComponent("t3code-updater", isDirectory: true)
        try lay(updater, folders: ["pending"], files: ["pending/update.zip", "pending/update-info.json", "current.blockmap"])
        #expect(!SafetyTierList.dependsOnChromiumShape(updater, home: home))
        #expect(check(updater))

        // A link beside `pending`, or a `pending` that is a link, is not an updater layout.
        let linked = caches.appendingPathComponent("linked-updater", isDirectory: true)
        try lay(linked, folders: ["pending"])
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("update.zip"),
            withDestinationURL: cleanup.appendingPathComponent("Documents/notes.txt")
        )
        let linkedPending = caches.appendingPathComponent("pending-link-updater", isDirectory: true)
        try lay(linkedPending, folders: [])
        try lay(cleanup, folders: ["Elsewhere/pending"])
        try FileManager.default.createSymbolicLink(
            at: linkedPending.appendingPathComponent("pending"),
            withDestinationURL: cleanup.appendingPathComponent("Elsewhere/pending")
        )
        #expect(!check(linked))
        #expect(!check(linkedPending))
    }

    /// An updater folder whose `pending` folder went before the move, and whose
    /// own name no entry knows, can't be told apart from a folder the shape
    /// rated. It stays, on purpose: the leftover is small, and the next scan no
    /// longer lists it.
    @Test
    func updaterFolderThatLostPendingStays() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.path
        let updater = caches.appendingPathComponent("t3code-updater", isDirectory: true)
        try lay(updater, folders: [], files: ["current.blockmap"])

        #expect(!CacheDiscoveryPaths.isElectronUpdaterCache(updater))
        #expect(tier(updater) == nil)
        #expect(!FileDeleter.defaultImmediateMoveCheck(home: home)(updater))
    }

    /// The disk ignores case, so a `service worker` folder is a Service Worker
    /// folder, as the tier list already reads it.
    @Test
    func serviceWorkerInAnyCaseKeepsItNotSure() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let lower = caches.appendingPathComponent("LowerWorker", isDirectory: true)
        try lay(lower, folders: Self.yabFolders + ["Chromium/Default/service worker"])
        let upper = caches.appendingPathComponent("UpperWorker", isDirectory: true)
        try lay(upper, folders: Self.yabFolders + ["Chromium/Default/SERVICE WORKER"])

        #expect(!CacheDiscoveryPaths.holdsOnlyChromiumDiskCaches(lower))
        #expect(!CacheDiscoveryPaths.holdsOnlyChromiumDiskCaches(upper))
        #expect(tier(lower) == nil)
        #expect(tier(upper) == nil)
        #expect(!SafetyTierList.passesChromiumShapeBoundary(lower, home: cleanup.path))
    }

    // MARK: - Yab's own entry

    /// Yab's entry names the folder and explains it, but the shape decides its
    /// tier. Its bundle ID folder, `dev.serafim.fast`, holds `Cache.db` and
    /// WebKit's `CacheStorage`, so the entry must not reach it.
    @Test
    func yabEntryCoversOnlyItsChromiumFolder() throws {
        #expect(ExplanationDatabase.definitionKey(forFolderName: "Yab") == "yab")
        let record = try #require(ExplanationDatabase.matchBundledDatabase(folderName: "Yab"))
        #expect(record.needsChromiumShape == true)
        #expect(ExplanationDatabase.definitionKey(forFolderName: "dev.serafim.fast") == nil)
    }

    /// A Yab folder that holds anything but Chromium disk caches is not Safe, by
    /// its entry or otherwise, and a move reads it again.
    @Test
    func yabEntryNeedsTheShape() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.path
        let yab = caches.appendingPathComponent("Yab", isDirectory: true)
        try lay(yab, folders: Self.yabFolders)

        func resolved() -> SafetyInfo {
            ExplanationResolver.initialSafetyForCacheFolder(folderName: "Yab", friendlyHeadline: "Yab", path: yab, home: home)
        }
        #expect(resolved().level == .safe)
        #expect(resolved().headline != "Yab")
        #expect(SafetyTierList.passesChromiumShapeBoundary(yab, home: home))

        try lay(yab, folders: ["Chromium/Default/Service Worker/CacheStorage"])
        #expect(resolved().level == .unknown)
        #expect(!SafetyTierList.passesChromiumShapeBoundary(yab, home: home))

        // A container cache folder with the same name is not Safe by the entry.
        let container = cleanup.appendingPathComponent(
            "Library/Containers/com.example.app/Data/Library/Caches/Yab", isDirectory: true
        )
        try lay(container, folders: Self.yabFolders)
        let inContainer = ExplanationResolver.initialSafetyForCacheFolder(
            folderName: "Yab", friendlyHeadline: "Yab", path: container, home: home
        )
        #expect(inContainer.level == .unknown)
    }

    /// Yab's entry is held to the shape before the move with no scan in this
    /// process, as for a row read from `last-scan.json` (#452).
    @Test
    func yabEntryIsReadAgainWithoutAScan() throws {
        let (caches, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.path
        let yab = caches.appendingPathComponent("Yab", isDirectory: true)
        try lay(yab, folders: Self.yabFolders)

        #expect(SafetyTierList.dependsOnChromiumShape(yab, home: home))
        #expect(SafetyTierList.passesChromiumShapeBoundary(yab, home: home))
        try lay(yab, folders: [], files: ["Chromium/Default/Cookies"])
        #expect(!SafetyTierList.passesChromiumShapeBoundary(yab, home: home))
        #expect(!FileDeleter.defaultImmediateMoveCheck(home: home)(yab))
    }

    /// Only the shape lets Yab's entry rate a folder. A folder named Yab that
    /// another rule rates Safe, such as a `Crashpad/completed` path, gets that
    /// rule's row, not Yab's entry.
    @Test
    func yabEntryNeedsTheShapeNotAnotherRule() throws {
        let (_, cleanup) = try makeCaches()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let completed = cleanup.appendingPathComponent(
            "Library/Application Support/Yab/Crashpad/completed", isDirectory: true
        )
        try lay(completed, folders: [])
        #expect(SafetyTierList.evaluate(folderName: "Yab", path: completed, home: cleanup.path) == .safe)

        let info = ExplanationResolver.initialSafetyForCacheFolder(
            folderName: "Yab", friendlyHeadline: "Yab crash reports", path: completed, home: cleanup.path
        )
        #expect(info.level == .safe)
        #expect(info.headline == "Yab crash reports")
    }
}
