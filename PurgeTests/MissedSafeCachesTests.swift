import Foundation
import Testing
@testable import Purge

/// The safe caches the #323 survey found Purge missing. Each one is pinned by
/// what is offered and by what next to it must stay out.
private enum MissedPaths {
    static var home: String { DeletionSafetyPolicy.cachedHomePath }

    static func evaluate(_ relative: String) -> DeletionSafetyDecision {
        DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "\(home)/\(relative)"))
    }

    static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-323-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Folders and empty files under `root`.
    static func lay(_ root: URL, folders: [String], files: [String] = []) throws {
        let fm = FileManager.default
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
}

// MARK: - Chromium storage folders below the app folder

@Suite("Missed caches (#323): nested Chromium folders")
struct NestedChromiumCacheTests {
    /// What discovery lists in `appRoot`, relative to it and sorted.
    private func listed(_ appRoot: URL) -> [String] {
        let prefix = appRoot.standardizedFileURL.path + "/"
        return CacheDiscoveryPaths.applicationSupportCacheURLs(in: appRoot, access: .full)
            .map { String($0.path.dropFirst(prefix.count)) }
            .sorted()
    }

    /// Whether the shape check, which the gate and the tier share, accepts `relative`.
    private func allowed(_ appRoot: URL, _ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        return CacheDiscoveryPaths.isApplicationSupportCachePath(parts, appRoot: appRoot)
    }

    /// Every path under `appRoot` the gate allows, which must be what discovery lists.
    private func everythingAllowed(_ appRoot: URL) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: appRoot.path)
            .filter { allowed(appRoot, $0) }
            .sorted()
    }

    /// Figma keeps one Chromium folder per version in `DesktopProfile/vNN`.
    @Test
    func figmaProfileCachesAreListed() throws {
        let support = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let figma = support.appendingPathComponent("Figma", isDirectory: true)
        try MissedPaths.lay(figma, folders: [
            "DesktopProfile/v43/Cache/Cache_Data", "DesktopProfile/v43/Code Cache/js",
            "DesktopProfile/v43/GPUCache", "DesktopProfile/v43/DawnWebGPUCache",
            "DesktopProfile/v43/Service Worker/CacheStorage", "DesktopProfile/v43/Service Worker/Database",
            "DesktopProfile/v43/IndexedDB", "DesktopProfile/v43/Local Storage/leveldb",
            "DesktopProfile/v42/Code Cache", "DesktopProfile/v42/IndexedDB",
            "FigmaAgent.app/Contents",
        ], files: [
            "DesktopProfile/v43/Local State", "DesktopProfile/v43/Cookies", "DesktopProfile/v43/Preferences",
            "DesktopProfile/v42/Local State", "settings.json",
        ])

        let expected = [
            "DesktopProfile/v42/Code Cache",
            "DesktopProfile/v43/Cache", "DesktopProfile/v43/Code Cache", "DesktopProfile/v43/DawnWebGPUCache",
            "DesktopProfile/v43/GPUCache",
        ]
        #expect(listed(figma) == expected)
        #expect(try everythingAllowed(figma) == expected)
    }

    /// Chrome keeps its data folder inside `Google`, with profiles inside that.
    @Test
    func chromeDataFolderAndProfileCachesAreListed() throws {
        let support = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let google = support.appendingPathComponent("Google", isDirectory: true)
        try MissedPaths.lay(google, folders: [
            "Chrome Beta/component_crx_cache", "Chrome Beta/GrShaderCache", "Chrome Beta/GraphiteDawnCache",
            "Chrome Beta/Safe Browsing", "Chrome Beta/SODALanguagePacks", "Chrome Beta/WidevineCdm",
            "Chrome Beta/Default/Service Worker/CacheStorage", "Chrome Beta/Default/Service Worker/ScriptCache",
            "Chrome Beta/Default/GPUCache", "Chrome Beta/Default/IndexedDB", "Chrome Beta/Default/Extensions",
            "Chrome Beta/Default/File System",
            "GoogleUpdater/Cache",
        ], files: [
            "Chrome Beta/Local State", "Chrome Beta/Default/Network Persistent State",
            "Chrome Beta/Default/Login Data", "Chrome Beta/Default/Cookies", "Chrome Beta/Default/History",
        ])

        let expected = [
            "Chrome Beta/Default/GPUCache", "Chrome Beta/GrShaderCache",
            "Chrome Beta/GraphiteDawnCache", "Chrome Beta/component_crx_cache",
        ]
        #expect(listed(google) == expected)
        #expect(try everythingAllowed(google) == expected)
    }

    /// The main browsers' own profiles keep installed web apps' offline content
    /// in `Service Worker/CacheStorage`, and each site's worker scripts in
    /// `Service Worker/ScriptCache`. Chromium deletes a site's registration and
    /// its web push subscription when the script is gone. Neither is offered,
    /// so Clean Safe Items and scheduled cleans can't take them. What is offered
    /// next to them is Safe.
    @Test(arguments: [
        ("Google", "Chrome"), ("Google", "Chrome Beta"),
        ("BraveSoftware", "Brave-Browser"), ("Microsoft Edge", ""),
    ])
    func browserProfileServiceWorkerCachesAreNeverOffered(app: String, browser: String) throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.standardizedFileURL.path
        let support = base.appendingPathComponent("Library/Application Support", isDirectory: true)
        let appRoot = support.appendingPathComponent(app, isDirectory: true)
        let data = browser.isEmpty ? "" : "\(browser)/"
        try MissedPaths.lay(appRoot, folders: [
            "\(data)Default/Service Worker/CacheStorage/abc", "\(data)Default/Service Worker/ScriptCache",
            "\(data)Default/Code Cache/js", "\(data)Profile 1/Service Worker/CacheStorage",
        ], files: [
            "\(data)Local State", "\(data)Default/Network Persistent State",
            "\(data)Profile 1/Network Persistent State",
        ])

        let listedPaths = listed(appRoot)
        #expect(!listedPaths.contains { $0.contains("Service Worker") }, "\(listedPaths)")
        for relative in ["Default/Service Worker/CacheStorage", "Default/Service Worker/CacheStorage/abc",
                         "Default/Service Worker/ScriptCache", "Profile 1/Service Worker/CacheStorage"] {
            #expect(!allowed(appRoot, data + relative), "\(relative)")
            let url = appRoot.appendingPathComponent(data + relative, isDirectory: true)
            let path = url.standardizedFileURL.path
            #expect(!DeletionSafetyPolicy.isWhitelistedApplicationSupportCachePath(path, home: home), "\(relative)")
            #expect(SafetyTierList.evaluate(folderName: app, path: url) != .safe, "\(relative)")
        }

        #expect(listedPaths.contains(data + "Default/Code Cache"))
        let codeCache = appRoot.appendingPathComponent(data + "Default/Code Cache", isDirectory: true)
        #expect(SafetyTierList.evaluate(folderName: app, path: codeCache) == .safe)
    }

    /// An Electron session partition holds its own caches next to its storage.
    @Test
    func partitionCachesNeedTheirOwnMarker() throws {
        let support = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let cursor = support.appendingPathComponent("Cursor", isDirectory: true)
        try MissedPaths.lay(cursor, folders: [
            "Partitions/cursor-browser/Cache/Cache_Data", "Partitions/cursor-browser/Code Cache",
            "Partitions/cursor-browser/IndexedDB", "Partitions/plain/Cache/Cache_Data",
            "Partitions/plain/Code Cache", "User/globalStorage",
        ], files: ["Local State", "Partitions/cursor-browser/Network Persistent State"])

        let expected = ["Partitions/cursor-browser/Cache", "Partitions/cursor-browser/Code Cache"]
        #expect(listed(cursor) == expected)
        #expect(try everythingAllowed(cursor) == expected)
    }

    /// The app folder's own Service Worker caches are not offered either.
    @Test
    func appFolderServiceWorkerCachesAreNotListed() throws {
        let support = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let app = support.appendingPathComponent("Code", isDirectory: true)
        try MissedPaths.lay(app, folders: [
            "Service Worker/ScriptCache", "Service Worker/Database", "User/History",
        ], files: ["Network Persistent State"])
        #expect(listed(app).isEmpty)
        #expect(try everythingAllowed(app).isEmpty)
    }

    /// Three levels down is not looked at, and neither is a folder without a marker.
    @Test
    func deeperOrUnmarkedFoldersStayOut() throws {
        let support = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let app = support.appendingPathComponent("SomeApp", isDirectory: true)
        try MissedPaths.lay(app, folders: [
            "a/b/c/Code Cache", "a/b/c/GPUCache", "x/y/Code Cache", "x/y/GPUCache",
        ], files: ["a/b/c/Local State", "x/y/Preferences"])
        #expect(listed(app).isEmpty)
        #expect(try everythingAllowed(app).isEmpty)
    }

    /// A storage folder reached through a link is neither listed nor allowed,
    /// so a link into Documents is never followed there.
    @Test
    func linkedFolderOnTheWayIsNotFollowed() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let elsewhere = base.appendingPathComponent("Documents/profile", isDirectory: true)
        try MissedPaths.lay(elsewhere, folders: ["Code Cache", "GPUCache"], files: ["Local State"])
        let app = base.appendingPathComponent("Support/LinkApp", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("profile"),
            withDestinationURL: elsewhere
        )
        #expect(listed(app).isEmpty)
        #expect(!allowed(app, "profile/Code Cache"))
        #expect(!allowed(app, "profile/GPUCache"))
    }

    /// A `Service Worker` folder that is a link is not followed, in the app folder,
    /// in a nested storage folder, or in a `User Data` profile.
    @Test
    func linkedServiceWorkerFolderIsNotFollowed() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let elsewhere = base.appendingPathComponent("Documents/sw", isDirectory: true)
        try MissedPaths.lay(elsewhere, folders: ["ScriptCache", "CacheStorage"])
        let app = base.appendingPathComponent("Support/LinkApp", isDirectory: true)
        try MissedPaths.lay(app, folders: ["nested", "User Data/Default"], files: [
            "Local State", "nested/Local State", "User Data/Local State",
        ])
        for folder in ["", "nested/", "User Data/Default/"] {
            try FileManager.default.createSymbolicLink(
                at: app.appendingPathComponent("\(folder)Service Worker"),
                withDestinationURL: elsewhere
            )
        }

        #expect(listed(app).isEmpty, "\(listed(app))")
        for relative in ["Service Worker/ScriptCache", "nested/Service Worker/ScriptCache",
                         "User Data/Default/Service Worker/ScriptCache",
                         "User Data/Default/Service Worker/CacheStorage"] {
            #expect(!allowed(app, relative), "\(relative)")
        }
    }

    /// Discovery skips hidden folders, so the gate does too.
    @Test
    func hiddenStorageFolderIsNotLookedAt() throws {
        let support = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let app = support.appendingPathComponent("HiddenApp", isDirectory: true)
        try MissedPaths.lay(app, folders: [".hidden/Code Cache", "a/.b/GPUCache"], files: [
            ".hidden/Local State", "a/.b/Local State",
        ])
        #expect(listed(app).isEmpty)
        #expect(try everythingAllowed(app).isEmpty)
    }

    /// A nested cache gets its tier from the shape, so an app with no entry
    /// still shows it as Safe.
    @Test
    func nestedCacheTierComesFromTheShape() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let support = base.appendingPathComponent("Library/Application Support", isDirectory: true)
        let storage = support.appendingPathComponent("NoEntryApp/Profiles/main", isDirectory: true)
        try MissedPaths.lay(storage, folders: ["Code Cache"], files: ["Network Persistent State"])
        let cache = storage.appendingPathComponent("Code Cache", isDirectory: true)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "NoEntryApp") == nil)
        #expect(SafetyTierList.evaluate(folderName: "NoEntryApp", path: cache) == .safe)
    }
}

// MARK: - Gradle daemon folders and temp folder

@Suite("Missed caches (#323): Gradle leftovers")
struct GradleLeftoverTests {
    private let home = "/Users/alice"
    private let weekAndADay: TimeInterval = 8 * 24 * 60 * 60

    @Test(arguments: [
        (".gradle/daemon/8.10.2", DeletionSafetyPolicy.GradleLeftover.daemonFolder),
        (".gradle/daemon/7.5.1", .daemonFolder),
        (".gradle/daemon/9.0-rc-1", .daemonFolder),
        (".gradle/.tmp", .temporaryFolder),
    ])
    func leftoversAreNamed(relative: String, kind: DeletionSafetyPolicy.GradleLeftover) {
        #expect(DeletionSafetyPolicy.gradleLeftover(at: "\(home)/\(relative)", home: home) == kind)
    }

    /// The folders only: nothing inside them, and nothing else in `~/.gradle`.
    @Test(arguments: [
        ".gradle", ".gradle/daemon", ".gradle/daemon/8.13/registry.bin", ".gradle/daemon/8.13/daemon-1.out.log",
        ".gradle/daemon/8.13/sub", ".gradle/daemon/.hidden", ".gradle/daemon/daemon-1.out.log",
        ".gradle/.tmp/jdks", ".gradle/.tmp/.cache", ".gradle/.tmp/gradle_download1bin",
        ".gradle/caches", ".gradle/jdks", ".gradle/native", "gradle/.tmp", ".gradle/tmp",
        ".gradle/daemon/CACHEDIR.TAG", ".gradle/daemon/latest",
    ])
    func everythingElseInGradleIsNotOne(relative: String) {
        #expect(DeletionSafetyPolicy.gradleLeftover(at: "\(home)/\(relative)", home: home) == nil, "\(relative)")
    }

    /// A version folder stays while any of its daemons runs.
    @Test
    func aVersionWithALiveDaemonStays() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try MissedPaths.lay(base, folders: [".gradle/daemon/8.9"], files: [
            ".gradle/daemon/8.13/daemon-111.out.log", ".gradle/daemon/8.13/daemon-222.out.log",
            ".gradle/daemon/8.13/registry.bin", ".gradle/daemon/8.10/daemon-333.out.log",
        ])
        let homePath = base.standardizedFileURL.path
        func refuses(_ version: String) -> Bool {
            DeletionSafetyPolicy.gradleLeftoverRefusesDeletion(
                base.appendingPathComponent(".gradle/daemon/\(version)", isDirectory: true),
                home: homePath, isRunning: { $0 == 111 }
            )
        }
        #expect(refuses("8.13"))
        #expect(!refuses("8.10"))
        // A version folder with no logs has no daemon to wait for.
        #expect(!refuses("8.9"))
        // Gone already: nothing to take.
        #expect(refuses("8.0"))
    }

    /// The temp folder stays while any daemon runs, and until nothing directly in
    /// it changed for a week.
    @Test
    func theTempFolderWaitsForIdleAndAge() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try MissedPaths.lay(base, folders: [".gradle/.tmp/jdks"], files: [
            ".gradle/.tmp/gradle_download42bin", ".gradle/daemon/8.13/daemon-111.out.log",
        ])
        let tmp = base.appendingPathComponent(".gradle/.tmp", isDirectory: true)
        let homePath = base.standardizedFileURL.path
        func refuses(after age: TimeInterval, running: Set<Int32> = []) -> Bool {
            DeletionSafetyPolicy.gradleLeftoverRefusesDeletion(
                tmp, home: homePath, now: Date().addingTimeInterval(age), isRunning: { running.contains($0) }
            )
        }
        #expect(refuses(after: 6 * 24 * 60 * 60))
        #expect(!refuses(after: weekAndADay))
        #expect(refuses(after: weekAndADay, running: [111]))
    }

    /// With no daemon folder at all, nothing has run, so age alone decides.
    @Test
    func theTempFolderWithNoDaemonFolder() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try MissedPaths.lay(base, folders: [], files: [".gradle/.tmp/gradle-worker-classpath8txt"])
        #expect(!DeletionSafetyPolicy.gradleLeftoverRefusesDeletion(
            base.appendingPathComponent(".gradle/.tmp", isDirectory: true), home: base.standardizedFileURL.path,
            now: Date().addingTimeInterval(weekAndADay), isRunning: { _ in false }
        ))
    }

    /// A linked version folder, `daemon` folder, `.tmp` or `.gradle` is not
    /// followed, and a file by a folder's name is not a folder.
    @Test
    func linksAndFilesAreNotTaken() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try MissedPaths.lay(elsewhere, folders: ["logs", "tmp", "daemon/8.13", "gradle/daemon/8.13", "gradle/.tmp"])

        let home = base.appendingPathComponent("home", isDirectory: true)
        try MissedPaths.lay(home, folders: [".gradle/daemon"], files: [".gradle/daemon/8.9"])
        try fm.createSymbolicLink(at: home.appendingPathComponent(".gradle/daemon/8.13"),
                                  withDestinationURL: elsewhere.appendingPathComponent("logs"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".gradle/.tmp"),
                                  withDestinationURL: elsewhere.appendingPathComponent("tmp"))
        let linkedDaemon = base.appendingPathComponent("home2", isDirectory: true)
        try MissedPaths.lay(linkedDaemon, folders: [".gradle"])
        try fm.createSymbolicLink(at: linkedDaemon.appendingPathComponent(".gradle/daemon"),
                                  withDestinationURL: elsewhere.appendingPathComponent("daemon"))
        let linkedGradle = base.appendingPathComponent("home3", isDirectory: true)
        try fm.createDirectory(at: linkedGradle, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedGradle.appendingPathComponent(".gradle"),
                                  withDestinationURL: elsewhere.appendingPathComponent("gradle"))

        func refuses(_ relative: String, in home: URL) -> Bool {
            DeletionSafetyPolicy.gradleLeftoverRefusesDeletion(
                home.appendingPathComponent(relative), home: home.standardizedFileURL.path,
                now: Date().addingTimeInterval(weekAndADay), isRunning: { _ in false }
            )
        }
        #expect(refuses(".gradle/daemon/8.13", in: home))
        #expect(refuses(".gradle/daemon/8.9", in: home))
        #expect(refuses(".gradle/.tmp", in: home))
        #expect(refuses(".gradle/daemon/8.13", in: linkedDaemon))
        #expect(refuses(".gradle/daemon/8.13", in: linkedGradle))
        #expect(refuses(".gradle/.tmp", in: linkedGradle))
    }

    @Test
    func theRowListsTheFolders() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try MissedPaths.lay(base, folders: [".gradle/.tmp/jdks", ".gradle/caches/modules-2", ".gradle/daemon/.hidden"], files: [
            ".gradle/daemon/8.13/daemon-5.out.log", ".gradle/daemon/8.13/registry.bin",
            ".gradle/daemon/8.9/daemon-6.out.log", ".gradle/.tmp/gradle_download7bin",
        ])
        let names = DevScanner.gradleLeftoverPaths(home: base).map {
            String($0.path.dropFirst(base.path.count + 1))
        }
        #expect(names.sorted() == [".gradle/.tmp", ".gradle/daemon/8.13", ".gradle/daemon/8.9"])
    }

    /// A `daemon` folder linked into Documents is not listed, so a scan without
    /// Full Disk Access never sets off the prompt it is meant to avoid.
    @Test
    func aDaemonFolderLinkedIntoDocumentsIsNotListed() throws {
        let home = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        try MissedPaths.lay(home, folders: [".gradle/.tmp", "Documents/gradle-daemon/8.13"])
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".gradle/daemon"),
            withDestinationURL: home.appendingPathComponent("Documents/gradle-daemon")
        )
        let names = DevScanner.gradleLeftoverPaths(home: home).map {
            String($0.path.dropFirst(home.path.count + 1))
        }
        #expect(names == [".gradle/.tmp"])
    }

    /// Through the whole chain on this Mac's home path: the folders are allowed,
    /// Gradle's own state is not.
    @Test
    func evaluateAllowsOnlyTheFolders() {
        #expect(MissedPaths.evaluate(".gradle/daemon/8.13") == .allow)
        #expect(MissedPaths.evaluate(".gradle/.tmp") == .allow)
        for relative in [".gradle", ".gradle/daemon", ".gradle/daemon/8.13/registry.bin",
                         ".gradle/.tmp/jdks", ".gradle/jdks", ".gradle/gradle.properties", ".gradle/init.d"] {
            #expect(MissedPaths.evaluate(relative) != .allow, "\(relative)")
        }
    }

    /// A pid now used by something other than `java` is not a daemon. This test
    /// host is `Purge`; a pid that can't be read still counts as one.
    /// `FileDeleter` asks `isOfferedForCleanup` before every move, and that is
    /// where the delete-time checks run. A version folder that isn't there and
    /// a Grok entry that isn't a binary pass `evaluate` or fail it by shape, but
    /// are never offered. Nothing here exists on disk.
    @Test
    func deleteTimeChecksRunThroughTheOfferGate() {
        let missingVersion = "9.9.9-purge-test-\(UUID().uuidString)"
        let folder = URL(fileURLWithPath: "\(MissedPaths.home)/.gradle/daemon/\(missingVersion)", isDirectory: true)
        #expect(DeletionSafetyPolicy.evaluate(folder) == .allow)
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(folder))

        let missingBinary = URL(fileURLWithPath: "\(MissedPaths.home)/.grok/downloads/grok-9.9.9-macos-purgetest")
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(missingBinary))
        let manifest = URL(fileURLWithPath: "\(MissedPaths.home)/.grok/downloads/manifest.json")
        #expect(DeletionSafetyPolicy.evaluate(manifest) != .allow)
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(manifest))
    }

    @Test
    func aReusedPidIsNotADaemon() {
        #expect(!DeletionSafetyPolicy.isGradleDaemonRunning(getpid()))
        #expect(DeletionSafetyPolicy.isGradleDaemonRunning(0))
        #expect(DeletionSafetyPolicy.isGradleDaemonRunning(-1))
    }

    @Test
    func aMissingOrInvalidPidCountsAsRunning() {
        #expect(DeletionSafetyPolicy.isProcessRunning(getpid()))
        #expect(DeletionSafetyPolicy.isProcessRunning(0))
        #expect(DeletionSafetyPolicy.isProcessRunning(-1))
    }
}

// MARK: - clang's module cache in /var/folders

@Suite("Missed caches (#323): clang module cache")
struct ClangModuleCacheTests {
    @Test
    func thePerUserCacheFolderIsUnderVarFolders() throws {
        let base = try #require(DeletionSafetyPolicy.darwinUserCacheDirectory())
        #expect(base.hasPrefix("/var/folders/") || base.hasPrefix("/private/var/folders/"))
        #expect(DeletionSafetyPolicy.clangModuleCachePaths.count == 2)
        #expect(DeletionSafetyPolicy.clangModuleCachePaths.allSatisfy { $0.hasSuffix("/C/clang/ModuleCache") })
    }

    @Test
    func bothSpellingsOfVarCount() {
        let paths = DeletionSafetyPolicy.bothVarSpellings(of: "/var/folders/ab/cd/C/clang/ModuleCache")
        #expect(paths == ["/var/folders/ab/cd/C/clang/ModuleCache", "/private/var/folders/ab/cd/C/clang/ModuleCache"])
        for path in [
            "/var/folders/ab/cd/C/clang/ModuleCache", "/var/folders/ab/cd/C/clang/ModuleCache/3ABC/Foundation.pcm",
            "/private/var/folders/ab/cd/C/clang/ModuleCache",
        ] {
            #expect(DeletionSafetyPolicy.isWhitelistedClangModuleCachePath(path, cachePaths: paths), "\(path)")
        }
        for path in [
            "/var/folders/ab/cd/C/clang", "/var/folders/ab/cd/C", "/var/folders/ab/cd/C/com.apple.Safari",
            "/var/folders/ab/cd/T/clang/ModuleCache", "/var/folders/ab/other/C/clang/ModuleCache",
            "/var/folders/ab/cd/C/clang/ModuleCacheBackup",
        ] {
            #expect(!DeletionSafetyPolicy.isWhitelistedClangModuleCachePath(path, cachePaths: paths), "\(path)")
        }
    }

    /// The real folder is allowed; the rest of `/var` stays refused.
    @Test
    func evaluateAllowsOnlyTheModuleCache() throws {
        let cache = try #require(DeletionSafetyPolicy.clangModuleCachePaths.first)
        #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: cache, isDirectory: true)) == .allow)
        let parent = URL(fileURLWithPath: cache).deletingLastPathComponent()
        #expect(DeletionSafetyPolicy.evaluate(parent) == .blockedNeverDelete)
        #expect(DeletionSafetyPolicy.evaluate(parent.deletingLastPathComponent()) == .blockedNeverDelete)
        #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "/var/db")) == .blockedNeverDelete)
    }
}

// MARK: - Download caches, CLI versions and Caches entries

@Suite("Missed caches (#323): allowlist and entries")
struct MissedCacheAllowlistTests {
    @Test(arguments: [
        ".nvm/.cache", ".nvm/.cache/bin/node-v22.14.0-darwin-arm64/node-v22.14.0-darwin-arm64.tar.xz",
        ".cache/giget", ".cache/giget/github/owner-repo/main.tar.gz",
        ".cache/firebase/emulators", ".cache/firebase/emulators/cloud-firestore-emulator-v1.19.8.jar",
    ])
    func downloadCachesAreOffered(relative: String) {
        #expect(MissedPaths.evaluate(relative) == .allow, "\(relative)")
    }

    /// Installed Node versions, nvm itself, and the rest of `~/.cache` stay out.
    @Test(arguments: [
        ".nvm", ".nvm/versions", ".nvm/versions/node/v22.14.0", ".nvm/nvm.sh", ".nvm/alias",
        ".cache/firebase", ".cache/codex-runtimes", ".cache/hyperframes", ".cache/gh",
    ])
    func neighboursStayOut(relative: String) {
        #expect(MissedPaths.evaluate(relative) != .allow, "\(relative)")
    }

    /// `.cache` is an allowed folder name, which used to allow the whole shared
    /// folder in home. Only listed subfolders are offered now; a project's own
    /// `.cache` is unchanged.
    @Test
    func homeCacheFolderIsRefusedWhole() {
        #expect(MissedPaths.evaluate(".cache") == .blockedNeverDelete)
        #expect(MissedPaths.evaluate(".cache/giget") == .allow)
        #expect(MissedPaths.evaluate(".cache/go-build") == .allow)
        #expect(MissedPaths.evaluate("Developer/site/.cache") == .allow)
    }

    @Test(arguments: [
        ("nvm Download Cache", SafetyLevel.safe),
        ("giget Template Cache", .safe),
        ("Firebase Emulators", .safe),
        ("Gradle Logs and Temp Files", .safe),
        ("Clang Module Cache", .safe),
        ("Old Grok Versions", .safe),
        ("Old Cursor Agent Versions", .safe),
    ])
    func devToolRowsResolve(label: String, level: SafetyLevel) {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: label, primaryPath: nil)
        #expect(info.level == level, "\(label) is \(info.level)")
    }

    /// `~/Library/Caches` folders that were hidden as Not Sure for want of an entry.
    @Test(arguments: [
        ("com.steipete.codexbar", SafetyLevel.safe),
        ("CodexBar", .medium),
        ("com.apple.intelligenceflow.intelligenceflowd", .safe),
        ("swift-frontend", .safe),
    ])
    func cacheFoldersResolve(name: String, level: SafetyLevel) {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: name)?.safetyLevel == level, "\(name)")
        #expect(MissedPaths.evaluate("Library/Caches/\(name)") == .allow, "\(name)")
    }

    /// iCloud Mail's agent holds only compiled model files, but the protected
    /// list refuses every iCloud and mail folder, and that wins over an entry.
    @Test
    func iCloudMailAgentStaysProtected() {
        #expect(MissedPaths.evaluate("Library/Caches/com.apple.icloudmailagent") == .blockedNeverDelete)
    }

    /// Left as Not Sure on purpose: a Core ML model nobody has shown macOS fetches again.
    @Test
    func visualIntelligenceModelHasNoEntry() {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "com.apple.VisualIntelligenceCore") == nil)
    }

    /// Grok points its command at a file in `downloads` with a relative link.
    @Test
    func grokKeepsTheLinkedDownloadAndTheNewest() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let downloads = base.appendingPathComponent(".grok/downloads", isDirectory: true)
        try MissedPaths.lay(base, folders: [".grok/bin"], files: [
            ".grok/downloads/grok-1.0.5-macos-aarch64", ".grok/downloads/grok-1.0.13-macos-aarch64",
            ".grok/downloads/grok-1.0.14-macos-aarch64",
        ])
        let command = base.appendingPathComponent(".grok/bin/grok")
        try FileManager.default.createSymbolicLink(
            atPath: command.path,
            withDestinationPath: "../downloads/grok-1.0.13-macos-aarch64"
        )
        let kept = DeletionSafetyPolicy.keptCLIVersions(versionsRoot: downloads.path, command: command.path)
        #expect(kept == ["grok-1.0.13-macos-aarch64", "grok-1.0.14-macos-aarch64"])
    }

    /// `~/.grok/downloads` is a generic downloads folder. A manifest, a partial
    /// download, or a folder or link by a version's name is never a version: it
    /// is not offered, and it can't stand in for the newest, which stays.
    @Test
    func grokOffersOnlyItsBinaries() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let downloads = base.appendingPathComponent(".grok/downloads", isDirectory: true)
        try MissedPaths.lay(base, folders: [".grok/bin", ".grok/downloads/grok-1.0.99-macos-aarch64"], files: [
            ".grok/downloads/grok-1.0.5-macos-aarch64", ".grok/downloads/grok-1.0.13-macos-aarch64",
            ".grok/downloads/grok-1.0.14-macos-aarch64", ".grok/downloads/manifest.json",
            ".grok/downloads/grok-1.0.15-macos-aarch64.part", ".grok/downloads/grok-latest",
            "Documents/notes.txt",
        ])
        try FileManager.default.createSymbolicLink(
            at: downloads.appendingPathComponent("grok-1.0.98-macos-aarch64"),
            withDestinationURL: base.appendingPathComponent("Documents/notes.txt")
        )
        let command = base.appendingPathComponent(".grok/bin/grok")
        try FileManager.default.createSymbolicLink(
            atPath: command.path,
            withDestinationPath: "../downloads/grok-1.0.13-macos-aarch64"
        )

        let kept = DeletionSafetyPolicy.keptCLIVersions(
            versionsRoot: downloads.path, command: command.path, entry: .grokBinary
        )
        #expect(kept == ["grok-1.0.13-macos-aarch64", "grok-1.0.14-macos-aarch64"])

        let rows = DevScanner.oldCLIVersionDefinitions(home: base)
        let grok = rows.first { $0.label == "Old Grok Versions" }
        #expect(grok?.paths.map(\.lastPathComponent) == ["grok-1.0.5-macos-aarch64"])

        for name in ["manifest.json", "grok-1.0.15-macos-aarch64.part", "grok-latest"] {
            #expect(MissedPaths.evaluate(".grok/downloads/\(name)") != .allow, "\(name)")
        }
        // A file inside an entry is never a version, even under a version's name.
        #expect(MissedPaths.evaluate(".grok/downloads/grok-1.0.99-macos-aarch64/grok") != .allow)
    }

    @Test(arguments: ["grok-1.0.13", "grok-1.0.13-macos-aarch64", "grok-0.1-macos-x86_64", "grok-2.10.3-macos-arm64"])
    func grokBinaryNamesMatch(name: String) {
        #expect(DeletionSafetyPolicy.CLIVersionEntry.isGrokBinaryName(name), "\(name)")
    }

    @Test(arguments: [
        "grok", "grok-", "grok-1", "grok-1.0.13.part", "grok-1.0.13-macos-aarch64.part", "grok-1.0.13-macos-",
        "grok-1..13", "grok-.1.0", "grok-1.0.", "grok-latest", "manifest.json", "grok-1.0.13-linux-x86_64",
        "grok-1.0.13-macos-aarch64/../x", "Grok-1.0.13",
    ])
    func otherGrokNamesDoNotMatch(name: String) {
        #expect(!DeletionSafetyPolicy.CLIVersionEntry.isGrokBinaryName(name), "\(name)")
    }

    @Test
    func newCLIStoresAreListed() {
        let stores = DeletionSafetyPolicy.cliVersionStores
        let worker = DeletionSafetyPolicy.cursorAgentWorkerCLI
        #expect(stores.contains { $0.versions == "\(worker)/.local/share/cursor-agent/versions"
            && $0.command == "\(worker)/.local/bin/cursor-agent" && $0.label == "Old Cursor Agent Versions" })
        #expect(stores.contains { $0.versions == ".grok/downloads" && $0.command == ".grok/bin/grok"
            && $0.entry == .grokBinary })
        #expect(stores.filter { $0.entry == .anyName }.count == 3)
        // Inside a store only; the stores' own folders and their neighbours stay out.
        #expect(MissedPaths.evaluate("\(worker)/.local/share/cursor-agent/versions/2026.09.10-fd3934a") == .allow)
        #expect(MissedPaths.evaluate(".grok/downloads/grok-1.0.5-macos-aarch64") == .allow)
        for relative in ["\(worker)/.local/share/cursor-agent/versions", "\(worker)/.local/bin/cursor-agent",
                         worker, ".grok/downloads", ".grok/bin/grok", ".grok/config.toml", ".grok/sessions"] {
            #expect(MissedPaths.evaluate(relative) != .allow, "\(relative)")
        }
    }
}
