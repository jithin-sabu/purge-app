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
    private func listed(_ appRoot: URL) -> [String] {
        let prefix = appRoot.standardizedFileURL.path + "/"
        return CacheDiscoveryPaths.applicationSupportCacheURLs(in: appRoot, access: .full)
            .map { String($0.path.dropFirst(prefix.count)) }
            .sorted()
    }

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
            "Chrome Beta/Default/GPUCache",
            "Chrome Beta/Default/Service Worker/ScriptCache", "Chrome Beta/GrShaderCache",
            "Chrome Beta/GraphiteDawnCache", "Chrome Beta/component_crx_cache",
        ]
        #expect(listed(google) == expected)
        #expect(try everythingAllowed(google) == expected)
    }

    /// The main browsers' own profiles keep installed web apps' offline content
    /// in `Service Worker/CacheStorage`. It is never offered there, so Clean Safe
    /// Items and scheduled cleans can't take it. What is offered next to it is Safe.
    @Test(arguments: [
        ("Google", "Chrome"), ("Google", "Chrome Beta"),
        ("BraveSoftware", "Brave-Browser"), ("Microsoft Edge", ""),
    ])
    func browserProfileCacheStorageIsNeverOffered(app: String, browser: String) throws {
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
        #expect(!listedPaths.contains { $0.contains("CacheStorage") }, "\(listedPaths)")
        for relative in ["Default/Service Worker/CacheStorage", "Default/Service Worker/CacheStorage/abc",
                         "Profile 1/Service Worker/CacheStorage"] {
            #expect(!allowed(appRoot, data + relative), "\(relative)")
            let path = appRoot.appendingPathComponent(data + relative).standardizedFileURL.path
            #expect(!DeletionSafetyPolicy.isWhitelistedApplicationSupportCachePath(path, home: home), "\(relative)")
        }

        for relative in ["Default/Service Worker/ScriptCache", "Default/Code Cache"] {
            #expect(listedPaths.contains(data + relative), "\(relative)")
            let url = appRoot.appendingPathComponent(data + relative, isDirectory: true)
            #expect(SafetyTierList.evaluate(folderName: app, path: url) == .safe, "\(relative)")
        }
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

    /// The app folder's own Service Worker caches, which the old rule left out.
    @Test
    func appFolderServiceWorkerCachesAreListed() throws {
        let support = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let app = support.appendingPathComponent("Code", isDirectory: true)
        try MissedPaths.lay(app, folders: [
            "Service Worker/ScriptCache", "Service Worker/Database", "User/History",
        ], files: ["Network Persistent State"])
        #expect(listed(app) == ["Service Worker/ScriptCache"])
        #expect(try everythingAllowed(app) == ["Service Worker/ScriptCache"])
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

// MARK: - Gradle daemon logs and temp files

@Suite("Missed caches (#323): Gradle leftovers")
struct GradleLeftoverTests {
    private let home = "/Users/alice"

    @Test(arguments: [
        (".gradle/daemon/8.10.2/daemon-12345.out.log", DeletionSafetyPolicy.GradleLeftover.daemonLog(pid: 12345)),
        (".gradle/daemon/7.5.1/daemon-1.out.log", .daemonLog(pid: 1)),
        (".gradle/.tmp/gradle_download16784810064779947987bin", .temporaryFile),
        (".gradle/.tmp/gradle-worker-classpath10292051080325833030txt", .temporaryFile),
    ])
    func leftoversAreNamed(relative: String, kind: DeletionSafetyPolicy.GradleLeftover) {
        #expect(DeletionSafetyPolicy.gradleLeftover(at: "\(home)/\(relative)", home: home) == kind)
    }

    @Test(arguments: [
        ".gradle", ".gradle/daemon", ".gradle/daemon/8.13", ".gradle/daemon/8.13/registry.bin",
        ".gradle/daemon/8.13/registry.bin.lock", ".gradle/daemon/daemon-1.out.log",
        ".gradle/daemon/8.13/sub/daemon-1.out.log", ".gradle/daemon/8.13/daemon-.out.log",
        ".gradle/daemon/8.13/daemon-12a.out.log", ".gradle/daemon/8.13/daemon-0.out.log",
        ".gradle/daemon/8.13/daemon-99999999999.out.log", ".gradle/daemon/.hidden/daemon-1.out.log",
        ".gradle/.tmp", ".gradle/.tmp/jdks", ".gradle/.tmp/.cache/expanded",
        ".gradle/.tmp/gradle_downloadbin", ".gradle/.tmp/gradle_download12.bin",
        ".gradle/.tmp/problems-report1.html", ".gradle/.tmp/jdks/gradle_download1bin",
        ".gradle/caches/gradle_download1bin", ".gradle/jdks", "gradle/.tmp/gradle_download1bin",
    ])
    func everythingElseInGradleIsNotOne(relative: String) {
        #expect(DeletionSafetyPolicy.gradleLeftover(at: "\(home)/\(relative)", home: home) == nil, "\(relative)")
    }

    @Test
    func aLiveDaemonsLogStays() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try MissedPaths.lay(base, folders: [], files: [
            ".gradle/daemon/8.13/daemon-111.out.log", ".gradle/daemon/8.13/daemon-222.out.log",
        ])
        let logs = base.appendingPathComponent(".gradle/daemon/8.13", isDirectory: true)
        let running: (Int32) -> Bool = { $0 == 111 }
        func refuses(_ name: String) -> Bool {
            DeletionSafetyPolicy.gradleLeftoverRefusesDeletion(
                logs.appendingPathComponent(name), home: base.standardizedFileURL.path, isRunning: running
            )
        }
        #expect(refuses("daemon-111.out.log"))
        #expect(!refuses("daemon-222.out.log"))
        // Gone already: nothing to take.
        #expect(refuses("daemon-333.out.log"))
    }

    @Test
    func aTempFileMustBeAWeekOld() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try MissedPaths.lay(base, folders: [], files: [".gradle/.tmp/gradle_download42bin"])
        let file = base.appendingPathComponent(".gradle/.tmp/gradle_download42bin")
        let modified = try #require(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        func refuses(after age: TimeInterval) -> Bool {
            DeletionSafetyPolicy.gradleLeftoverRefusesDeletion(
                file, home: base.standardizedFileURL.path, now: modified.addingTimeInterval(age), isRunning: { _ in false }
            )
        }
        #expect(refuses(after: 6 * 24 * 60 * 60))
        #expect(!refuses(after: DeletionSafetyPolicy.gradleTemporaryFileMinimumAge + 60))
    }

    /// A link or a folder by a leftover's name is never taken.
    @Test
    func onlyAPlainFileIsTaken() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try MissedPaths.lay(base, folders: [".gradle/daemon/8.13/daemon-5.out.log"], files: ["Documents/notes.txt"])
        let logs = base.appendingPathComponent(".gradle/daemon/8.13", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: logs.appendingPathComponent("daemon-6.out.log"),
            withDestinationURL: base.appendingPathComponent("Documents/notes.txt")
        )
        for name in ["daemon-5.out.log", "daemon-6.out.log"] {
            #expect(DeletionSafetyPolicy.gradleLeftoverRefusesDeletion(
                logs.appendingPathComponent(name), home: base.standardizedFileURL.path, isRunning: { _ in false }
            ), "\(name)")
        }
    }

    /// A linked version folder, `daemon` folder or `.tmp` is not followed, even
    /// to a file with a leftover's name.
    @Test
    func aLinkedParentFolderIsNotFollowed() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try MissedPaths.lay(elsewhere, folders: ["daemon/8.13"], files: [
            "logs/daemon-7.out.log", "daemon/8.13/daemon-8.out.log", "tmp/gradle_download9bin",
        ])
        let old = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: elsewhere.appendingPathComponent("tmp/gradle_download9bin").path
        )
        let fm = FileManager.default
        try MissedPaths.lay(home, folders: [".gradle/daemon"])
        try fm.createSymbolicLink(at: home.appendingPathComponent(".gradle/daemon/8.13"),
                                  withDestinationURL: elsewhere.appendingPathComponent("logs"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".gradle/.tmp"),
                                  withDestinationURL: elsewhere.appendingPathComponent("tmp"))
        let linkedDaemonHome = base.appendingPathComponent("home2", isDirectory: true)
        try MissedPaths.lay(linkedDaemonHome, folders: [".gradle"])
        try fm.createSymbolicLink(at: linkedDaemonHome.appendingPathComponent(".gradle/daemon"),
                                  withDestinationURL: elsewhere.appendingPathComponent("daemon"))

        func refuses(_ relative: String, in home: URL) -> Bool {
            DeletionSafetyPolicy.gradleLeftoverRefusesDeletion(
                home.appendingPathComponent(relative), home: home.standardizedFileURL.path, isRunning: { _ in false }
            )
        }
        #expect(refuses(".gradle/daemon/8.13/daemon-7.out.log", in: home))
        #expect(refuses(".gradle/.tmp/gradle_download9bin", in: home))
        #expect(refuses(".gradle/daemon/8.13/daemon-8.out.log", in: linkedDaemonHome))
    }

    @Test
    func theRowListsOnlyLeftovers() throws {
        let base = try MissedPaths.makeFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        try MissedPaths.lay(base, folders: [".gradle/.tmp/jdks", ".gradle/caches/modules-2"], files: [
            ".gradle/daemon/8.13/daemon-5.out.log", ".gradle/daemon/8.13/registry.bin",
            ".gradle/daemon/8.9/daemon-6.out.log", ".gradle/.tmp/gradle_download7bin",
            ".gradle/.tmp/gradle-worker-classpath8txt", ".gradle/.tmp/problems-report9.html",
        ])
        let names = DevScanner.gradleLeftoverPaths(home: base).map {
            String($0.path.dropFirst(base.path.count + 1))
        }
        #expect(names.sorted() == [
            ".gradle/.tmp/gradle-worker-classpath8txt", ".gradle/.tmp/gradle_download7bin",
            ".gradle/daemon/8.13/daemon-5.out.log", ".gradle/daemon/8.9/daemon-6.out.log",
        ])
    }

    /// Through the whole chain on this Mac's home path: the shapes are allowed,
    /// Gradle's own state is not.
    @Test
    func evaluateAllowsOnlyTheShapes() {
        #expect(MissedPaths.evaluate(".gradle/daemon/8.13/daemon-5.out.log") == .allow)
        #expect(MissedPaths.evaluate(".gradle/.tmp/gradle_download7bin") == .allow)
        for relative in [".gradle/daemon", ".gradle/daemon/8.13", ".gradle/daemon/8.13/registry.bin",
                         ".gradle/.tmp", ".gradle/.tmp/jdks", ".gradle/jdks", ".gradle/gradle.properties"] {
            #expect(MissedPaths.evaluate(relative) != .allow, "\(relative)")
        }
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
