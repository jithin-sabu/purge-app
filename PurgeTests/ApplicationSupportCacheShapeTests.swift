import Foundation
import Testing
@testable import Purge

/// Application Support caches are offered by their shape, not their name. The
/// generic names count only in a Chromium data folder, and `Cache` also needs
/// Chromium's layout inside (#130). An app-name alias in `explanations.json` no
/// longer reaches a folder that fails the shape (#226).
@Suite("Application Support caches: Chromium shape")
struct ApplicationSupportCacheShapeTests {
    private struct FakeHome {
        let home: URL

        var support: URL {
            home.appendingPathComponent("Library/Application Support", isDirectory: true)
        }

        /// An app folder with `folders` inside and empty `files`.
        @discardableResult
        func app(_ name: String, folders: [String], files: [String] = []) throws -> URL {
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
            .appendingPathComponent("purge-test-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FakeHome(home: url)
    }

    /// What an Electron app keeps in its Application Support folder: caches next
    /// to its databases, local storage and settings.
    private static let electronFolders = [
        "Cache/Cache_Data", "Code Cache/js", "GPUCache", "DawnCache", "DawnWebGPUCache", "DawnGraphiteCache",
        "GraphiteDawnCache", "GrShaderCache", "Crashpad/completed", "Crashpad/pending",
        "IndexedDB", "Local Storage/leveldb", "Session Storage", "blob_storage", "Partitions/main/Cache/Cache_Data",
    ]

    @Test(arguments: CacheDiscoveryPaths.chromiumDataFolderMarkers)
    func electronAppWithMarkerListsItsCaches(marker: String) throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("Recordly", folders: Self.electronFolders, files: [marker, "Preferences"])
        #expect(fake.listed(root) == [
            "Cache", "Code Cache", "Crashpad/completed", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
            "GPUCache", "GrShaderCache", "GraphiteDawnCache",
        ])
    }

    /// Without Chromium's marker a folder named `Cache` could be anything, so
    /// only the crash reports are left. `Preferences` is too generic to count.
    @Test
    func appWithoutMarkerListsOnlyCrashReports() throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("SomeApp", folders: Self.electronFolders, files: ["Preferences"])
        #expect(fake.listed(root) == ["Crashpad/completed"])
        #expect(!fake.allowed(root, "Cache"))
        #expect(!fake.allowed(root, "GPUCache"))
        #expect(fake.allowed(root, "Crashpad/completed"))
    }

    /// The gate allows exactly the folders discovery lists: walking every folder
    /// under a full Electron and Chromium layout finds no other allowed path.
    @Test
    func gateAllowsExactlyWhatDiscoveryLists() throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app(
            "Arc",
            folders: Self.electronFolders + [
                "User Data/GrShaderCache", "User Data/GraphiteDawnCache", "User Data/ShaderCache",
                "User Data/Safe Browsing", "User Data/Default/Cache/Cache_Data", "User Data/Default/Code Cache",
                "User Data/Default/DawnWebGPUCache", "User Data/Default/DawnCache",
                "User Data/Default/Service Worker/CacheStorage", "User Data/Default/Service Worker/ScriptCache",
                "User Data/Default/Service Worker/Database", "User Data/Default/Extensions",
                "User Data/Default/IndexedDB", "User Data/Profile 1/Cache", "User Data/Profile 1/GPUCache",
            ],
            files: ["Network Persistent State", "User Data/Local State", "User Data/Default/Login Data"]
        )
        let listed = fake.listed(root)
        #expect(listed == [
            "Cache", "Code Cache", "Crashpad/completed", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
            "GPUCache", "GrShaderCache", "GraphiteDawnCache",
            "User Data/Default/Cache", "User Data/Default/Code Cache", "User Data/Default/DawnCache",
            "User Data/Default/DawnWebGPUCache", "User Data/GrShaderCache",
            "User Data/GraphiteDawnCache", "User Data/Profile 1/GPUCache", "User Data/ShaderCache",
        ])

        let everything = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        let allowed = everything.filter { fake.allowed(root, $0) }.sorted()
        #expect(allowed == listed)
    }

    /// The bare `Cache` an alias used to reach: a Chromium app, but nothing of
    /// Chromium's inside the folder. It is neither listed nor allowed until
    /// `Cache_Data` appears, and then the alias's entry names the row.
    @Test(arguments: ["Codex", "EffectCraft", "Code", "Cursor", "Claude"])
    func bareCacheIsLeftOutEvenForAnAlias(appName: String) throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app(appName, folders: ["Cache"], files: ["Local State", "Cache/notes.db"])
        #expect(fake.listed(root).isEmpty)
        #expect(!fake.allowed(root, "Cache"))

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Cache/Cache_Data"),
            withIntermediateDirectories: true
        )
        #expect(fake.listed(root) == ["Cache"])
        #expect(fake.allowed(root, "Cache"))
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        let info = ExplanationResolver.initialSafetyForCacheFolder(folderName: appName, friendlyHeadline: appName, path: cache)
        #expect(info.level == .safe, "\(appName)")
    }

    /// No allowlist prefix under Application Support may end in a Chromium cache
    /// name: `evaluate` checks the prefixes first, so one would allow the folder
    /// by name and skip the shape check.
    @Test
    func noPrefixAllowsAnApplicationSupportCacheByName() {
        let home = DeletionSafetyPolicy.cachedHomePath
        let names = CacheDiscoveryPaths.applicationSupportDirectCacheNames
            .union(CacheDiscoveryPaths.chromiumProfileCacheNames)
        let byName = DeletionSafetyPolicy.whitelistedAbsolutePrefixes(home: home).filter {
            $0.hasPrefix("\(home)/Library/Application Support/")
                && names.contains(URL(fileURLWithPath: $0).lastPathComponent)
        }
        #expect(byName.isEmpty, "\(byName)")
    }

    /// Through the whole decision chain: what an alias app's `Cache` holds is never
    /// allowed by itself, whatever is on this Mac.
    @Test(arguments: ["Code", "Cursor", "Slack", "discord", "Notion", "Figma", "Codex", "Claude"])
    func evaluateRefusesFilesInsideAnAppCache(appName: String) {
        for relative in ["Cache/notes.db", "Code Cache/js", "CachedData/settings.json", "Partitions/main/Cache"] {
            let url = URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)
                .appendingPathComponent("Library/Application Support/\(appName)/\(relative)")
            #expect(DeletionSafetyPolicy.evaluate(url) != .allow, "\(appName)/\(relative)")
        }
    }

    /// Chromium's HTTP cache before `Cache_Data`: blockfile `index` and `data_0`.
    @Test
    func olderChromiumCacheLayoutCounts() throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("OldElectron", folders: ["Cache"], files: ["Local State", "Cache/index"])
        #expect(fake.listed(root).isEmpty)
        try Data().write(to: root.appendingPathComponent("Cache/data_0"))
        #expect(fake.listed(root) == ["Cache"])
        #expect(fake.allowed(root, "Cache"))
    }

    /// Where a `Cache` folder is offered in Application Support: directly in an
    /// Electron app's folder, at the root of its `User Data` folder, in a
    /// profile, and in a storage folder below the app's folder.
    private static let httpCacheShapes = ["Cache", "User Data/Cache", "User Data/Default/Cache", "Partitions/main/Cache"]

    /// An app whose Chromium data folders all hold `Local State`, with an empty
    /// folder at `shape`.
    private func appWithEmptyCache(_ fake: FakeHome, shape: String) throws -> URL {
        try fake.app(
            "Recordly",
            folders: [shape, "User Data", "Partitions/main"],
            files: ["Local State", "User Data/Local State", "Partitions/main/Local State"]
        )
    }

    /// The layout made of real items counts in every shape: `Cache_Data` a
    /// folder, or `index` and `data_0` files.
    @Test(arguments: httpCacheShapes, [true, false])
    func realMarkersCount(shape: String, blockfile: Bool) throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try appWithEmptyCache(fake, shape: shape)
        let cache = root.appendingPathComponent(shape, isDirectory: true)
        #expect(fake.listed(root).isEmpty)
        #expect(!fake.allowed(root, shape))

        if blockfile {
            try Data().write(to: cache.appendingPathComponent("index"))
            try Data().write(to: cache.appendingPathComponent("data_0"))
        } else {
            try FileManager.default.createDirectory(
                at: cache.appendingPathComponent("Cache_Data"), withIntermediateDirectories: false
            )
        }
        #expect(fake.listed(root) == [shape])
        #expect(fake.allowed(root, shape))
    }

    /// Ways a `Cache` folder can carry Chromium's marker names without
    /// Chromium's layout (#443).
    enum FakeMarker: String, CaseIterable, Sendable {
        /// `Cache_Data` is a link to a real folder elsewhere.
        case cacheDataLink
        /// `index` and `data_0` are links to real files elsewhere.
        case blockfileLinks
        /// `index` and `data_0` are folders.
        case blockfileFolders
        /// `Cache_Data` is a file.
        case cacheDataFile
    }

    /// Plants `marker` in `cache`, with any link pointing into `elsewhere`.
    private func plant(_ marker: FakeMarker, in cache: URL, elsewhere: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        switch marker {
        case .cacheDataLink:
            let target = elsewhere.appendingPathComponent("Cache_Data", isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: cache.appendingPathComponent("Cache_Data"), withDestinationURL: target)
        case .blockfileLinks:
            for name in ["index", "data_0"] {
                let target = elsewhere.appendingPathComponent(name)
                try Data().write(to: target)
                try fm.createSymbolicLink(at: cache.appendingPathComponent(name), withDestinationURL: target)
            }
        case .blockfileFolders:
            for name in ["index", "data_0"] {
                try fm.createDirectory(at: cache.appendingPathComponent(name), withIntermediateDirectories: false)
            }
        case .cacheDataFile:
            try Data().write(to: cache.appendingPathComponent("Cache_Data"))
        }
    }

    /// A link or a folder with a marker's name is no evidence: `fileExists`
    /// follows links and accepts folders, so the name alone used to pass. The
    /// `Cache` folder is neither listed nor allowed, in any shape, until the
    /// real layout appears beside it.
    @Test(arguments: httpCacheShapes, FakeMarker.allCases)
    func fakeMarkersDoNotCount(shape: String, marker: FakeMarker) throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try appWithEmptyCache(fake, shape: shape)
        let cache = root.appendingPathComponent(shape, isDirectory: true)
        try plant(marker, in: cache, elsewhere: fake.home.appendingPathComponent("Elsewhere", isDirectory: true))

        let markers = marker == .cacheDataLink || marker == .cacheDataFile ? ["Cache_Data"] : ["index", "data_0"]
        for name in markers {
            #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent(name).path))
        }
        #expect(!CacheDiscoveryPaths.hasChromiumHTTPCacheLayout(cache))
        #expect(fake.listed(root).isEmpty)
        #expect(!fake.allowed(root, shape))
    }

    /// An app with no `explanations.json` entry gets its tier from the shape, so
    /// its GPU caches are Safe instead of hidden as Not Sure.
    @Test(arguments: ["DawnCache", "DawnWebGPUCache", "DawnGraphiteCache", "GraphiteDawnCache", "GrShaderCache"])
    func appWithoutAnEntryGetsSafeGPUCaches(name: String) throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("Recordly", folders: [name])
        let cache = root.appendingPathComponent(name, isDirectory: true)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "Recordly") == nil)
        #expect(SafetyTierList.evaluate(folderName: "Recordly", path: cache) == nil)

        try Data().write(to: root.appendingPathComponent("Network Persistent State"))
        #expect(SafetyTierList.evaluate(folderName: "Recordly", path: cache) == .safe)
    }
}

/// An app with no `explanations.json` entry used to get one App Caches row per
/// cache folder, which the new GPU cache names turned into dozens of tiny rows.
@Suite("Application Support caches: one row per app")
struct ApplicationSupportCacheGroupingTests {
    private func item(_ app: String, _ folder: String, bytes: Int64, level: SafetyLevel = .safe) -> CacheItem {
        let path = URL(fileURLWithPath: "/Users/alice/Library/Application Support/\(app)/\(folder)", isDirectory: true)
        return CacheItem(
            definitionKey: CacheDiscoveryPaths.applicationSupportGroupKey(appFolderName: app),
            location: CacheLocation(path: path, sizeBytes: bytes, lastModified: .distantPast, folderName: app),
            appName: "\(app) Cache",
            safetyInfo: ExplanationResolver.tierSafetyInfo(level: level, headline: "\(app) Cache")
        )
    }

    @Test
    func anAppsFoldersShareOneRow() {
        let rows = DefinitionCacheGrouper.group([
            item("Aqua Voice", "DawnWebGPUCache", bytes: 600),
            item("Aqua Voice", "DawnGraphiteCache", bytes: 500),
            item("Aqua Voice", "Crashpad/completed", bytes: 100),
            item("Recordly", "DawnWebGPUCache", bytes: 5_800),
        ])
        #expect(rows.map(\.appName) == ["Recordly Cache", "Aqua Voice Cache"])
        #expect(rows.map(\.locations.count) == [1, 3])
        #expect(rows.map(\.sizeBytes) == [5_800, 1_200])
        #expect(rows.allSatisfy { $0.safetyInfo.level == .safe })
    }

    /// A merged row takes its most cautious folder's tier.
    @Test
    func theRowIsAsCautiousAsItsMostCautiousFolder() {
        let rows = DefinitionCacheGrouper.group([
            item("Aqua Voice", "DawnWebGPUCache", bytes: 600),
            item("Aqua Voice", "GPUCache", bytes: 500, level: .medium),
        ])
        #expect(rows.count == 1)
        #expect(rows.first?.safetyInfo.level == .medium)
    }

    /// The key is only for grouping: it never finds an entry, so it can never
    /// lend a folder an entry's tier.
    @Test(arguments: ["Aqua Voice", "Claude", "Code", "Slack"])
    func theGroupKeyNeverMatchesAnEntry(app: String) {
        let key = CacheDiscoveryPaths.applicationSupportGroupKey(appFolderName: app)
        #expect(ExplanationDatabase.record(forKey: key) == nil)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: key) == nil)
    }
}
