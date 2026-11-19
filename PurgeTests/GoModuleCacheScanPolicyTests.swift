import Darwin
import Foundation
import os
import Testing
@testable import Purge

/// The whole Go module cache as one Check First row (#397). Every cache here is
/// a fake one in a temporary home, never the real `~/go`.
@Suite("Go module cache")
struct GoModuleCacheScanPolicyTests {
    // MARK: Fixtures

    /// A temporary home with a Go module cache at `relative`: the download
    /// folder, two read-only modules and a read-only file in each.
    private static func makeHome(cacheAt relative: String = "go/pkg/mod") throws -> (home: URL, root: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-397-\(UUID().uuidString)", isDirectory: true)
        let root = home.appendingPathComponent(relative, isDirectory: true)
        try lay(root, folders: [
            "cache/download/github.com/x/y/@v",
            "github.com/x/y@v1.2.0/internal",
            "golang.org/x/text@v0.20.0",
        ], files: [
            "cache/download/github.com/x/y/@v/v1.2.0.zip",
            "github.com/x/y@v1.2.0/go.mod",
            "github.com/x/y@v1.2.0/internal/a.go",
            "golang.org/x/text@v0.20.0/go.mod",
        ])
        makeReadOnlyLikeGo(root.appendingPathComponent("github.com/x/y@v1.2.0"))
        makeReadOnlyLikeGo(root.appendingPathComponent("golang.org/x/text@v0.20.0"))
        return (home, root)
    }

    private static func lay(_ root: URL, folders: [String], files: [String] = []) throws {
        let fm = FileManager.default
        for folder in folders {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in files {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
    }

    /// Folders 0555 and files 0444, as Go leaves an unpacked module.
    private static func makeReadOnlyLikeGo(_ module: URL) {
        let fm = FileManager.default
        var folders: [URL] = [module]
        if let walk = fm.enumerator(at: module, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walk {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    folders.append(url)
                } else {
                    chmod(url.path, 0o444)
                }
            }
        }
        // Deepest first, so a parent is still writable while its children change.
        for folder in folders.reversed() { chmod(folder.path, 0o555) }
    }

    /// Makes every folder writable again, so the temporary home can be removed.
    private static func cleanUp(_ home: URL) {
        if let walk = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil) {
            for case let url as URL in walk { chmod(url.path, 0o755) }
        }
        try? FileManager.default.removeItem(at: home)
    }

    private static func mode(_ url: URL) -> mode_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & 0o777
    }

    // MARK: Finding the folder

    @Test
    func goModCacheWinsOverGoPath() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let root = GoModuleCacheScanPolicy.configuredRoot(
            environment: ["GOMODCACHE": "/Volumes/Fast/gomod", "GOPATH": "/Users/someone/gopath"],
            home: home,
            envFile: { _ in nil }
        )
        #expect(root?.path == "/Volumes/Fast/gomod")
    }

    @Test
    func goPathUsesItsFirstEntry() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let root = GoModuleCacheScanPolicy.configuredRoot(
            environment: ["GOPATH": "/Users/someone/gopath:/Users/someone/other"],
            home: home,
            envFile: { _ in nil }
        )
        #expect(root?.path == "/Users/someone/gopath/pkg/mod")
    }

    @Test
    func defaultIsGoInHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let root = GoModuleCacheScanPolicy.configuredRoot(environment: [:], home: home, envFile: { _ in nil })
        #expect(root?.path == "/Users/someone/go/pkg/mod")
    }

    /// Go itself refuses a relative path, and `~` is not expanded.
    @Test
    func relativeValuesFindNothing() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(GoModuleCacheScanPolicy.configuredRoot(
            environment: ["GOMODCACHE": "~/gomod"], home: home, envFile: { _ in nil }
        ) == nil)
        #expect(GoModuleCacheScanPolicy.configuredRoot(
            environment: ["GOPATH": "gopath"], home: home, envFile: { _ in nil }
        ) == nil)
    }

    @Test
    func goEnvFileIsReadWhenTheEnvironmentHasNoValue() {
        let home = URL(fileURLWithPath: "/Users/someone")
        var readFile: String?
        let root = GoModuleCacheScanPolicy.configuredRoot(environment: [:], home: home) { url in
            readFile = url.path
            return "GOPROXY=direct\nGOMODCACHE=/Users/someone/gomod\n"
        }
        #expect(readFile == "/Users/someone/Library/Application Support/go/env")
        #expect(root?.path == "/Users/someone/gomod")
    }

    @Test
    func theEnvironmentWinsOverGoEnvFile() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let root = GoModuleCacheScanPolicy.configuredRoot(
            environment: ["GOMODCACHE": "/Users/someone/fromenv"],
            home: home,
            envFile: { _ in "GOMODCACHE=/Users/someone/fromfile\n" }
        )
        #expect(root?.path == "/Users/someone/fromenv")
    }

    @Test
    func goEnvOffSkipsTheFile() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let root = GoModuleCacheScanPolicy.configuredRoot(
            environment: ["GOENV": "off"],
            home: home,
            envFile: { _ in "GOMODCACHE=/Users/someone/fromfile\n" }
        )
        #expect(root?.path == "/Users/someone/go/pkg/mod")
    }

    // MARK: Judging the folder

    @Test
    func aRealCacheIsOfferedWhole() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let read = GoModuleCacheScanPolicy.read(environment: [:], home: home, excludedPaths: [], insideHomeOnly: false)
        #expect(read == .init(root: root.standardizedFileURL.path, offer: .wholeCache, limited: false))
    }

    /// `GOMODCACHE` naming `GOPATH` would take the user's code in `src`.
    @Test(arguments: ["src", "bin", "pkg", "notes", ".git"])
    func anEntryThatIsNotAModuleOffersOnlyTheDownloads(name: String) throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        let read = GoModuleCacheScanPolicy.read(environment: [:], home: home, excludedPaths: [], insideHomeOnly: false)
        #expect(read?.isWholeCache == false)
    }

    @Test
    func aFileOrLinkAtTheTopOffersOnlyTheDownloads() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        try Data().write(to: root.appendingPathComponent("example.com"))
        #expect(GoModuleCacheScanPolicy.holdsOnlyModules(root, excludedPaths: []) == false)
        try FileManager.default.removeItem(at: root.appendingPathComponent("example.com"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("example.org"),
            withDestinationURL: home
        )
        #expect(GoModuleCacheScanPolicy.holdsOnlyModules(root, excludedPaths: []) == false)
    }

    @Test
    func finderFilesAreIgnored() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        #expect(GoModuleCacheScanPolicy.holdsOnlyModules(root, excludedPaths: []))
    }

    /// An old exclusion of `~/go/pkg/mod/cache` must not be moved with the
    /// whole folder.
    @Test
    func anExclusionInsideOffersOnlyTheDownloads() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let excluded = root.appendingPathComponent("cache").standardizedFileURL.resolvingSymlinksInPath().path
        let read = GoModuleCacheScanPolicy.read(
            environment: [:], home: home, excludedPaths: [excluded], insideHomeOnly: false
        )
        #expect(read?.isWholeCache == false)
    }

    @Test
    func aFolderWithoutDownloadsIsNotACache() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("cache/download"))
        #expect(GoModuleCacheScanPolicy.read(environment: [:], home: home, excludedPaths: [], insideHomeOnly: false) == nil)
    }

    @Test
    func homeAndAboveAreRefused() throws {
        let (home, _) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        // Home itself, even when it holds `cache/download`.
        try Self.lay(home, folders: ["cache/download"])
        #expect(!GoModuleCacheScanPolicy.acceptsLocation(home, home: home))
        #expect(!GoModuleCacheScanPolicy.acceptsLocation(home.deletingLastPathComponent(), home: home))
        #expect(!GoModuleCacheScanPolicy.acceptsLocation(URL(fileURLWithPath: "/"), home: home))
    }

    @Test
    func aLinkedRootIsRefused() throws {
        let (home, root) = try Self.makeHome(cacheAt: "real/mod")
        defer { Self.cleanUp(home) }
        let link = home.appendingPathComponent("gomod")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(GoModuleCacheScanPolicy.acceptsLocation(root, home: home))
        #expect(!GoModuleCacheScanPolicy.acceptsLocation(link, home: home))
    }

    @Test(arguments: ["Pictures/gomod", "Library/Mobile Documents/gomod", "Library/CloudStorage/Dropbox/gomod"])
    func neverDeleteAndCloudFoldersAreRefused(relative: String) throws {
        let (home, root) = try Self.makeHome(cacheAt: relative)
        defer { Self.cleanUp(home) }
        #expect(!GoModuleCacheScanPolicy.acceptsLocation(root, home: home))
    }

    /// By spelling alone, so the test fails if the list is dropped, whether or
    /// not the folders exist.
    @Test(arguments: [
        "/usr/local/gomod", "/Library/gomod", "/private/var/gomod", "/private/etc/gomod",
        // The home folder and its Pictures under another spelling, reached
        // through no link.
        "/System/Volumes/Data/Users/someone/gomod", "/System/Volumes/Data/Users/someone/Pictures/gomod",
        // Case differs from the real folder.
        "/Users/someone/pictures/gomod", "/Users/someone/Library/mobile documents/gomod",
        // Exact folders `evaluate` refuses, which hold the user's files.
        "/Users/someone/Downloads", "/Users/someone/Documents", "/Users/someone/library",
        "/Users/someone", "/Users", "/",
    ])
    func refusedSpellings(path: String) {
        #expect(GoModuleCacheScanPolicy.isRefusedSpelling(path, home: "/Users/someone"))
    }

    @Test
    func ordinaryPlacesAreNotRefusedBySpelling() {
        #expect(!GoModuleCacheScanPolicy.isRefusedSpelling("/Users/someone/go/pkg/mod", home: "/Users/someone"))
        #expect(!GoModuleCacheScanPolicy.isRefusedSpelling("/Users/someone/Documents/go/pkg/mod", home: "/Users/someone"))
        #expect(!GoModuleCacheScanPolicy.isRefusedSpelling("/Volumes/Fast/gomod", home: "/Users/someone"))
        // The system list is what refuses a folder outside home.
        #expect(!GoModuleCacheScanPolicy.isRefusedSpelling("/opt/gomod", home: "/Users/someone", systemPrefixes: []))
        #expect(GoModuleCacheScanPolicy.isRefusedSpelling("/opt/gomod", home: "/Users/someone", systemPrefixes: ["/opt"]))
    }

    /// `GOMODCACHE` naming Downloads, with Go's folders in it, never offers
    /// Downloads itself.
    @Test
    func anExactNeverDeleteFolderIsNotRead() throws {
        let (home, _) = try Self.makeHome(cacheAt: "Downloads")
        defer { Self.cleanUp(home) }
        let downloads = home.appendingPathComponent("Downloads").path
        #expect(GoModuleCacheScanPolicy.read(
            environment: ["GOMODCACHE": downloads], home: home, excludedPaths: [], insideHomeOnly: false
        ) == nil)
    }

    @Test
    func aDifferentlyCasedProtectedFolderIsRefused() throws {
        let (home, _) = try Self.makeHome(cacheAt: "Pictures/gomod")
        defer { Self.cleanUp(home) }
        #expect(!GoModuleCacheScanPolicy.acceptsLocation(home.appendingPathComponent("pictures/gomod"), home: home))
    }

    /// A scan without Full Disk Access reads nothing in Documents, which would
    /// make macOS ask, so it finds no cache there.
    @Test
    func aLimitedScanSkipsAProtectedFolder() throws {
        let (home, root) = try Self.makeHome(cacheAt: "Documents/go/pkg/mod")
        defer { Self.cleanUp(home) }
        let limited = GoModuleCacheScanPolicy.read(
            environment: ["GOPATH": home.appendingPathComponent("Documents/go").path],
            home: home, excludedPaths: [], insideHomeOnly: true
        )
        #expect(limited == nil)
        let full = GoModuleCacheScanPolicy.read(
            environment: ["GOPATH": home.appendingPathComponent("Documents/go").path],
            home: home, excludedPaths: [], insideHomeOnly: false
        )
        #expect(full?.root == root.standardizedFileURL.path)
    }

    // MARK: Evidence below the top

    /// A folder of the user's own repos, laid out by host, gains Go's
    /// `cache/download` after one `go mod download`. It must not be offered whole.
    @Test(arguments: [
        ["folders": "github.com/me/repo/.git", "files": ""],
        ["folders": "github.com/me/repo", "files": "github.com/me/repo/main.go"],
        ["folders": "github.com/me/tool@v1.0.0/.git", "files": ""],
        ["folders": "github.com/me/.hidden", "files": ""],
    ])
    func checkoutsBelowTheTopOfferOnlyTheDownloads(layout: [String: String]) throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        try Self.lay(
            root,
            folders: [layout["folders"]!],
            files: layout["files"]!.isEmpty ? [] : [layout["files"]!]
        )
        let read = GoModuleCacheScanPolicy.read(environment: [:], home: home, excludedPaths: [], insideHomeOnly: false)
        #expect(read?.offer == .downloadsOnly)
    }

    @Test
    func aOneElementModuleCountsAsGos() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        try Self.lay(root, folders: ["example.com@v1.0.0"], files: ["example.com@v1.0.0/go.mod"])
        #expect(GoModuleCacheScanPolicy.holdsOnlyModules(root, excludedPaths: []))
    }

    /// An exclusion inside `cache` keeps the fallback from being offered too.
    @Test
    func anExclusionInsideTheDownloadsOffersNothing() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let excluded = root.appendingPathComponent("cache/download/github.com")
            .standardizedFileURL.resolvingSymlinksInPath().path
        let read = GoModuleCacheScanPolicy.read(
            environment: [:], home: home, excludedPaths: [excluded], insideHomeOnly: false
        )
        #expect(read?.offer == .nothing)
        let context = GoModuleCacheScanPolicy.TestContext(home: home, excludedPaths: [excluded])
        GoModuleCacheScanPolicy.$testContext.withValue(context) {
            GoModuleCacheScanPolicy.refreshSnapshot()
            #expect(GoModuleCacheScanPolicy.rowPaths(home: home).isEmpty)
            #expect(!GoModuleCacheScanPolicy.isWhitelistedPath(root.appendingPathComponent("cache").path))
        }
    }

    // MARK: Other rows

    /// A cache inside a folder another rule offers, such as Go's build cache
    /// in `~/Library/Caches`, gets no row: that row is Safe. Judged by
    /// `evaluate` on the spelling only.
    @Test
    func aCacheInsideAnotherOfferedFolderIsNoticed() {
        let home = URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
        #expect(GoModuleCacheScanPolicy.isInsideAnotherOfferedFolder(
            home.appendingPathComponent("Library/Caches/go-build/gomod")
        ))
        #expect(!GoModuleCacheScanPolicy.isInsideAnotherOfferedFolder(home.appendingPathComponent("go/pkg/mod")))
    }

    /// No row may move a folder that holds the module cache, such as Go's
    /// build cache with `GOMODCACHE` inside it.
    @Test
    func aFolderHoldingTheCacheIsNeverMoved() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let context = GoModuleCacheScanPolicy.TestContext(home: home)
        try GoModuleCacheScanPolicy.$testContext.withValue(context) {
            try #require(GoModuleCacheScanPolicy.refreshSnapshot()?.isWholeCache == true)
            #expect(GoModuleCacheScanPolicy.refusesDeletion(root.deletingLastPathComponent()))
            #expect(GoModuleCacheScanPolicy.refusesDeletion(home.appendingPathComponent("go")))
            // A folder beside it is not this rule's business.
            #expect(!GoModuleCacheScanPolicy.refusesDeletion(home.appendingPathComponent("go/bin")))
        }
    }

    @Test
    func aFolderAnotherServiceSyncsIsRefused() throws {
        let (home, root) = try Self.makeHome(cacheAt: "Sync/gomod")
        defer { Self.cleanUp(home) }
        try Data().write(to: home.appendingPathComponent("Sync/.stfolder"))
        #expect(!GoModuleCacheScanPolicy.acceptsLocation(root, home: home))
    }

    @Test
    func aLimitedScanReadsNothingOutsideHome() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let otherHome = home.appendingPathComponent("elsewhere", isDirectory: true)
        let read = GoModuleCacheScanPolicy.read(
            environment: ["GOMODCACHE": root.path], home: otherHome, excludedPaths: [], insideHomeOnly: true
        )
        #expect(read == nil)
    }

    // MARK: Row and gates

    @Test
    func theRowAndTheGateFollowTheSnapshot() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let context = GoModuleCacheScanPolicy.TestContext(home: home)
        try GoModuleCacheScanPolicy.$testContext.withValue(context) {
            try #require(GoModuleCacheScanPolicy.refreshSnapshot()?.isWholeCache == true)
            let rootPath = root.standardizedFileURL.path
            #expect(GoModuleCacheScanPolicy.rowPaths(home: home).map(\.path) == [rootPath])
            #expect(DeletionSafetyPolicy.evaluate(root) == .allow)
            #expect(DeletionSafetyPolicy.evaluate(root.appendingPathComponent("cache/download")) == .allow)
            // One module on its own, and the folders above, are never offered.
            #expect(!GoModuleCacheScanPolicy.isWhitelistedPath(rootPath + "/github.com/x/y@v1.2.0"))
            #expect(!GoModuleCacheScanPolicy.isWhitelistedPath(root.deletingLastPathComponent().path))
            #expect(!GoModuleCacheScanPolicy.refusesDeletion(root))
        }
    }

    @Test
    func aFolderThatGainedYourCodeIsRefusedAtTheMove() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let context = GoModuleCacheScanPolicy.TestContext(home: home)
        try GoModuleCacheScanPolicy.$testContext.withValue(context) {
            try #require(GoModuleCacheScanPolicy.refreshSnapshot()?.isWholeCache == true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("src/myapp"), withIntermediateDirectories: true)
            // The main thread takes the scan's answer; a move reads the disk.
            #expect(!GoModuleCacheScanPolicy.refusesDeletion(root, reuseRecentRead: true))
            #expect(GoModuleCacheScanPolicy.refusesDeletion(root))
        }
    }

    @Test
    func aPartialCacheOffersOnlyItsDownloads() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let context = GoModuleCacheScanPolicy.TestContext(home: home)
        GoModuleCacheScanPolicy.$testContext.withValue(context) {
            GoModuleCacheScanPolicy.refreshSnapshot()
            let cache = root.appendingPathComponent("cache", isDirectory: true)
            #expect(GoModuleCacheScanPolicy.rowPaths(home: home).map(\.path) == [cache.standardizedFileURL.path])
            #expect(!GoModuleCacheScanPolicy.isWhitelistedPath(root.standardizedFileURL.path))
            #expect(GoModuleCacheScanPolicy.refusesDeletion(root))
        }
    }

    @Test
    func theModuleCacheIsCheckFirstAndTheBuildCacheIsSafe() {
        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: "Go Module Cache", primaryPath: nil).level == .medium)
        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: "Go Build Cache", primaryPath: nil).level == .safe)
    }

    // MARK: Before the move

    @Test
    func readOnlyModulesBecomeRemovable() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let module = root.appendingPathComponent("github.com/x/y@v1.2.0")
        #expect(Self.mode(module) == 0o555)
        #expect(GoModuleCacheScanPolicy.makeFoldersWritable(in: root))
        #expect(Self.mode(module) == 0o755)
        #expect(Self.mode(module.appendingPathComponent("internal")) == 0o755)
        // Files keep Go's mode; only their folders change.
        #expect(Self.mode(module.appendingPathComponent("go.mod")) == 0o444)
        try FileManager.default.removeItem(at: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func aLinkInsideIsNeverFollowed() throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let outside = home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        chmod(outside.path, 0o555)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("golang.org/link"),
            withDestinationURL: outside
        )
        #expect(GoModuleCacheScanPolicy.makeFoldersWritable(in: root))
        #expect(Self.mode(outside) == 0o555)
    }

    @Test
    func theCleanMovesTheWholeCacheWithWritableFolders() async throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let context = GoModuleCacheScanPolicy.TestContext(home: home)
        let module = root.appendingPathComponent("golang.org/x/text@v0.20.0")
        // Read when the Trash is asked, since the real one moves the folder:
        // a change made after that would be too late.
        let modeAtMove = OSAllocatedUnfairLock<mode_t?>(initialState: nil)
        let trash = FakeTrash()
        let deleter = FileDeleter(
            home: home,
            trash: { url in
                modeAtMove.withLock { $0 = Self.mode(module) }
                try trash.trash(url)
            },
            fullDiskAccessGranted: { true }
        )
        try await GoModuleCacheScanPolicy.$testContext.withValue(context) {
            try #require(GoModuleCacheScanPolicy.refreshSnapshot()?.isWholeCache == true)
            let report = try await deleter.deleteItems(
                at: [root],
                pathToExpectedSizeBytes: [root.standardizedFileURL.path: 4_096]
            )
            #expect(report.failedItems.isEmpty)
            #expect(trash.trashedPaths == [root.standardizedFileURL.path])
        }
        #expect(modeAtMove.withLock { $0 } == 0o755)
        #expect(Self.mode(module) == 0o755)
    }

    /// `GOMODCACHE` moved after the scan: the old `cache` stays, through the
    /// clean and through Retry.
    @Test
    func anOldCacheStaysAfterGoModCacheMoves() async throws {
        let (home, oldRoot) = try Self.makeHome(cacheAt: "old/mod")
        defer { Self.cleanUp(home) }
        try FileManager.default.createDirectory(at: oldRoot.appendingPathComponent("src"), withIntermediateDirectories: true)
        let newRoot = home.appendingPathComponent("new/mod", isDirectory: true)
        try Self.lay(newRoot, folders: ["cache/download"])
        let context = GoModuleCacheScanPolicy.TestContext(environment: ["GOMODCACHE": oldRoot.path], home: home)
        let trash = FakeTrash()
        let deleter = FileDeleter(home: home, trash: trash.trash, fullDiskAccessGranted: { true })
        let oldCache = oldRoot.appendingPathComponent("cache", isDirectory: true)
        try await GoModuleCacheScanPolicy.$testContext.withValue(context) {
            try #require(GoModuleCacheScanPolicy.refreshSnapshot()?.offer == .downloadsOnly)
            #expect(GoModuleCacheScanPolicy.rowPaths(home: home).map(\.path) == [oldCache.standardizedFileURL.path])
            context.environment = ["GOMODCACHE": newRoot.path]
            _ = try await deleter.deleteItems(at: [oldCache])
            _ = await deleter.retryDeleteItem(at: oldCache, displayName: nil, expectedSizeBytes: 0, route: .cache)
        }
        #expect(trash.trashedPaths.isEmpty)
    }

    @Test
    func theCleanSkipsACacheThatChangedSinceTheScan() async throws {
        let (home, root) = try Self.makeHome()
        defer { Self.cleanUp(home) }
        let context = GoModuleCacheScanPolicy.TestContext(home: home)
        let trash = FakeTrash()
        let deleter = FileDeleter(home: home, trash: trash.trash, fullDiskAccessGranted: { true })
        try await GoModuleCacheScanPolicy.$testContext.withValue(context) {
            try #require(GoModuleCacheScanPolicy.refreshSnapshot()?.isWholeCache == true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            _ = try await deleter.deleteItems(at: [root])
            #expect(trash.trashedPaths.isEmpty)
        }
        // Nothing was changed on a folder Purge did not move.
        #expect(Self.mode(root.appendingPathComponent("golang.org/x/text@v0.20.0")) == 0o555)
    }
}
