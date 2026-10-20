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
        "Cache/Cache_Data", "Code Cache/js", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache",
        "GraphiteDawnCache", "GrShaderCache", "Crashpad/completed", "Crashpad/pending",
        "IndexedDB", "Local Storage/leveldb", "Session Storage", "blob_storage", "Partitions/main/Cache/Cache_Data",
    ]

    @Test(arguments: CacheDiscoveryPaths.chromiumDataFolderMarkers)
    func electronAppWithMarkerListsItsCaches(marker: String) throws {
        let fake = try makeHome()
        defer { try? FileManager.default.removeItem(at: fake.home) }
        let root = try fake.app("Recordly", folders: Self.electronFolders, files: [marker, "Preferences"])
        #expect(fake.listed(root) == [
            "Cache", "Code Cache", "Crashpad/completed", "DawnGraphiteCache", "DawnWebGPUCache",
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
                "User Data/Default/DawnWebGPUCache", "User Data/Default/Service Worker/CacheStorage",
                "User Data/Default/Service Worker/Database", "User Data/Default/Extensions",
                "User Data/Default/IndexedDB", "User Data/Profile 1/Cache", "User Data/Profile 1/GPUCache",
            ],
            files: ["Network Persistent State", "User Data/Local State", "User Data/Default/Login Data"]
        )
        let listed = fake.listed(root)
        #expect(listed == [
            "Cache", "Code Cache", "Crashpad/completed", "DawnGraphiteCache", "DawnWebGPUCache", "GPUCache",
            "GrShaderCache", "GraphiteDawnCache",
            "User Data/Default/Cache", "User Data/Default/Code Cache", "User Data/Default/DawnWebGPUCache",
            "User Data/Default/Service Worker/CacheStorage", "User Data/GrShaderCache",
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

    /// An app with no `explanations.json` entry gets its tier from the shape, so
    /// its GPU caches are Safe instead of hidden as Not Sure.
    @Test(arguments: ["DawnWebGPUCache", "DawnGraphiteCache", "GraphiteDawnCache", "GrShaderCache"])
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
