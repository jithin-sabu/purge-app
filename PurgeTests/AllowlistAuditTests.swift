import Foundation
import Testing
@testable import Purge

/// Pins the 2026-10 allowlist audit. Safe rows are what "Clean Safe Items" and
/// scheduled cleans take without asking, so anything here that is not a pure,
/// self-rebuilding cache must be Check First or not offered at all.
private enum AuditPaths {
    static var home: String {
        DeletionSafetyPolicy.cachedHomePath
    }

    static func url(_ relative: String) -> URL {
        URL(fileURLWithPath: "\(home)/\(relative)")
    }

    static func evaluate(_ relative: String) -> DeletionSafetyDecision {
        DeletionSafetyPolicy.evaluate(url(relative))
    }
}

private func bundledLevel(_ key: String) -> SafetyLevel? {
    ExplanationDatabase.record(forKey: key)?.safetyLevel
}

// MARK: - Part 1: rows that were Safe but hold more than a cache

@Suite("Allowlist audit: no longer Safe")
struct AllowlistNoLongerSafeTests {
    @Test
    func gemsOnlyOfferDownloadsNotInstalledGems() {
        #expect(AuditPaths.evaluate(".gem") != .allow)
        #expect(AuditPaths.evaluate(".gem/ruby/3.3.0/gems/cocoapods-1.16.2") != .allow)
        #expect(AuditPaths.evaluate(".gem/ruby/3.3.0/bin/pod") != .allow)
        #expect(AuditPaths.evaluate(".gem/specs") == .allow)
        #expect(AuditPaths.evaluate(".gem/ruby/3.3.0/cache") == .allow)
        #expect(AuditPaths.evaluate(".gem/ruby/3.3.0/cache/cocoapods-1.16.2.gem") == .allow)
    }

    @Test
    func sbtSettingsAreNeverOffered() {
        #expect(AuditPaths.evaluate(".sbt") != .allow)
        #expect(AuditPaths.evaluate(".sbt/1.0/global.sbt") != .allow)
        #expect(AuditPaths.evaluate(".ivy2/cache") == .allow)
    }

    @Test
    func pubCacheKeepsGloballyActivatedTools() {
        #expect(AuditPaths.evaluate(".pub-cache") != .allow)
        #expect(AuditPaths.evaluate(".pub-cache/bin") != .allow)
        #expect(AuditPaths.evaluate(".pub-cache/global_packages") != .allow)
        #expect(AuditPaths.evaluate(".pub-cache/hosted") == .allow)
        #expect(AuditPaths.evaluate(".pub-cache/git") == .allow)
    }

    @Test
    func cocoaPodsOffersSpecReposOnly() {
        #expect(AuditPaths.evaluate(".cocoapods") != .allow)
        #expect(AuditPaths.evaluate(".cocoapods/repos") == .allow)
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "CocoaPods", primaryPath: nil)
        #expect(info.level == .medium)
    }

    @Test
    func zedWorkspaceDatabaseIsNeverOffered() {
        #expect(AuditPaths.evaluate("Library/Application Support/Zed/db") != .allow)
        #expect(AuditPaths.evaluate("Library/Caches/Zed") == .allow)
    }

    @Test
    func jetBrainsLocalHistoryIsNeverOffered() {
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains") == .blockedNeverDelete)
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2") == .blockedNeverDelete)
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2/LocalHistory") == .blockedNeverDelete)
        #expect(
            AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2/LocalHistory/changes.storageData")
                == .blockedNeverDelete
        )
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2/caches") == .allow)
        #expect(AuditPaths.evaluate("Library/Caches/JetBrains/IntelliJIdea2025.2/index") == .allow)
    }

    @Test
    func editorWorkspaceStorageIsOfferedEntryByEntry() {
        for editor in ["Code", "Cursor"] {
            let root = "Library/Application Support/\(editor)/User/workspaceStorage"
            #expect(AuditPaths.evaluate(root) != .allow, "whole folder offered for \(editor)")
            #expect(AuditPaths.evaluate("\(root)/0a1b2c3d") == .allow)
        }
        #expect(bundledLevel("orphaned-editor-workspace-storage") == .medium)
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "Cursor Old Workspace Data", primaryPath: nil)
        #expect(info.level == .medium)
    }

    @Test(arguments: [
        "Maven Cache", "Gradle Cache", "NuGet Packages", "Cabal Packages",
        "SBT Cache", "Playwright Browsers",
    ])
    func bigDownloadStoresAreCheckFirst(label: String) {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: label, primaryPath: nil)
        #expect(info.level == .medium, "\(label) is \(info.level)")
    }

    /// Project `.gradle` folders share the old key and stay Safe; only the global
    /// `~/.gradle/caches` row moved.
    @Test
    func projectGradleFoldersStaySafe() {
        #expect(bundledLevel("gradle-cache") == .safe)
        #expect(bundledLevel("gradle-global-cache") == .medium)
    }
}

@Suite("Editor workspace storage: only provably orphaned entries")
struct EditorWorkspaceStoragePolicyTests {
    private func makeEntry(in root: URL, json: String?) throws -> URL {
        let entry = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        if let json {
            try Data(json.utf8).write(to: entry.appendingPathComponent("workspace.json"))
        }
        return entry
    }

    @Test
    func onlyEntriesWhoseProjectIsGoneAreOrphaned() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("workspaceStorage", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let live = try makeEntry(in: root, json: #"{"folder":"\#(project.absoluteString)"}"#)
        let gone = try makeEntry(
            in: root,
            json: #"{"folder":"\#(base.appendingPathComponent("deleted-project").absoluteString)"}"#
        )
        let remote = try makeEntry(in: root, json: #"{"folder":"vscode-remote://ssh-remote+box/home/me/app"}"#)
        let emptyWindow = try makeEntry(in: root, json: nil)
        let unplugged = try makeEntry(in: root, json: #"{"folder":"file:///Volumes/NotPluggedIn-\#(UUID().uuidString)/app"}"#)

        let orphaned = Set(
            EditorWorkspaceStoragePolicy.orphanedEntries(inRoot: root, access: .full).map(\.lastPathComponent)
        )
        #expect(orphaned == [gone.lastPathComponent])
        for kept in [live, remote, emptyWindow, unplugged] {
            #expect(!orphaned.contains(kept.lastPathComponent))
        }
    }

    @Test
    func projectsInLockedFoldersCountAsPresentWithoutFullDiskAccess() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let inDocuments = URL(fileURLWithPath: "\(AuditPaths.home)/Documents/purge-test-\(UUID().uuidString)")
        let entry = try makeEntry(in: root, json: #"{"folder":"\#(inDocuments.absoluteString)"}"#)
        #expect(!EditorWorkspaceStoragePolicy.isOrphaned(entry: entry, access: .limited))
    }
}

// MARK: - Part 2: Check First rows that were too broad or never safe to offer

@Suite("Allowlist audit: narrowed or blocked")
struct AllowlistNarrowedTests {
    @Test
    func androidOffersCachesOnly() {
        #expect(AuditPaths.evaluate(".android") != .allow)
        #expect(AuditPaths.evaluate(".android/avd") != .allow)
        #expect(AuditPaths.evaluate(".android/adbkey") != .allow)
        #expect(AuditPaths.evaluate(".android/debug.keystore") != .allow)
        #expect(AuditPaths.evaluate(".android/cache") == .allow)
        #expect(AuditPaths.evaluate(".android/build-cache") == .allow)
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "Android Build Cache", primaryPath: nil)
        #expect(info.level == .safe)
    }

    @Test
    func stackKeepsSettingsAndCompilers() {
        #expect(AuditPaths.evaluate(".stack") != .allow)
        #expect(AuditPaths.evaluate(".stack/config.yaml") != .allow)
        #expect(AuditPaths.evaluate(".stack/global-project") != .allow)
        #expect(AuditPaths.evaluate(".stack/programs") != .allow)
        #expect(AuditPaths.evaluate(".stack/pantry") == .allow)
        #expect(AuditPaths.evaluate(".stack/snapshots") == .allow)
    }

    @Test(arguments: [
        "com.apple.ScreenTimeAgent",
        "com.apple.ScreenTimeSettingsAgent",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "org.keepassxc.keepassxc",
        "com.authy.authy-mac",
        "com.yubico.yubioath",
    ])
    func sensitiveCachesAreNeverOffered(folderName: String) {
        #expect(AuditPaths.evaluate("Library/Caches/\(folderName)") == .blockedNeverDelete)
        #expect(
            AuditPaths.evaluate("Library/Containers/\(folderName)/Data/Library/Caches/x") == .blockedNeverDelete
        )
    }
}

// MARK: - Part 3: explanations and names

@Suite("Allowlist audit: explanation data")
struct AllowlistExplanationDataTests {
    private struct Entry: Decodable {
        let key: String
        let aliases: [String]?
        let bundle_ids: [String]?
    }

    private func entries() throws -> [Entry] {
        let url = try #require(Bundle.main.url(forResource: "explanations", withExtension: "json"))
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }

    /// A name claimed by two entries resolves to whichever the loader saw last,
    /// so a row could silently take another entry's tier.
    @Test
    func everyNameBelongsToOneEntry() throws {
        var owners: [String: Set<String>] = [:]
        for entry in try entries() {
            for name in [entry.key] + (entry.aliases ?? []) + (entry.bundle_ids ?? []) {
                owners[name.lowercased(), default: []].insert(entry.key)
            }
        }
        let shared = owners.filter { $0.value.count > 1 }
        #expect(shared.isEmpty, "names claimed by more than one entry: \(shared)")
    }

    /// These names belong to folders that are not caches: installed Homebrew
    /// packages, committed git hooks, and installed tool versions.
    @Test(arguments: ["Cellar", ".husky", ".volta", ".mise", "Devices"])
    func nonCacheFolderNamesHaveNoEntry(name: String) {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: name) == nil)
    }

    @Test
    func mapsTilesAreCheckFirstLikeAppleMaps() {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "GeoServices")?.safetyLevel == .medium)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "com.apple.Maps")?.safetyLevel == .medium)
    }

    @Test
    func flutterSettingsFileIsNotOffered() {
        #expect(AuditPaths.evaluate(".flutter") != .allow)
    }

    @Test
    func containerManagerCacheIsNeverOffered() {
        #expect(AuditPaths.evaluate("Library/Caches/com.apple.containermanagerd") == .blockedNeverDelete)
    }
}

// MARK: - Part 4: bugs

@Suite("Allowlist audit: bugs")
struct AllowlistBugTests {
    /// Both rows used to resolve to "Not Sure" and were dropped from every scan.
    @Test(arguments: ["Deno Cache", "Bun Cache"])
    func denoAndBunRowsResolve(label: String) {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: label, primaryPath: nil)
        #expect(info.level == .safe)
    }

    @Test
    func macOSInstallersAreFoundByBundleIDNotName() throws {
        let fm = FileManager.default
        let apps = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: apps) }
        func makeApp(_ name: String, bundleID: String) throws {
            let contents = apps.appendingPathComponent("\(name)/Contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: NSDictionary = ["CFBundleIdentifier": bundleID]
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("Install macOS Sequoia.app", bundleID: "com.apple.InstallAssistant.macOSSequoia")
        try makeApp("Install macOS Helper.app", bundleID: "com.example.helper")
        try makeApp("Xcode.app", bundleID: "com.apple.dt.Xcode")

        let found = CacheDiscoveryPaths.macOSInstallerURLs(applications: apps).map(\.lastPathComponent)
        #expect(found == ["Install macOS Sequoia.app"])
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: CacheDiscoveryPaths.macOSInstallerKey)?
            .safetyLevel == .medium)
        // The old prefix matched nothing real and is gone.
        #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "/Applications/Install macOS")) != .allow)
    }

    @Test
    func everyChromiumBrowserFrameworkIsRecognised() throws {
        let fm = FileManager.default
        let app = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/Brave Browser.app")
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try fm.createDirectory(
            at: frameworks.appendingPathComponent("Brave Browser Framework.framework/Versions"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: frameworks.appendingPathComponent("Sparkle.framework/Versions"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: app.deletingLastPathComponent()) }
        #expect(CacheDiscoveryPaths.chromiumFrameworkVersionsDir(in: app)?.deletingLastPathComponent().lastPathComponent
            == "Brave Browser Framework.framework")

        for (appName, framework) in [
            ("Brave Browser.app", "Brave Browser Framework.framework"),
            ("Microsoft Edge.app", "Microsoft Edge Framework.framework"),
            ("Chromium.app", "Chromium Framework.framework"),
        ] {
            let old = "/Applications/\(appName)/Contents/Frameworks/\(framework)/Versions/120.0.1.2"
            #expect(DeletionSafetyPolicy.isWhitelistedStaleBrowserFrameworkPath(old), "\(appName)")
            #expect(!DeletionSafetyPolicy.isWhitelistedStaleBrowserFrameworkPath(
                "/Applications/\(appName)/Contents/Frameworks/\(framework)/Versions/Current"
            ))
        }
    }

    /// The old rule allowed a version folder of any framework in any app.
    @Test
    func otherAppsFrameworkVersionsAreNotOffered() {
        for path in [
            "/Applications/Xcode.app/Contents/Frameworks/IDEFoundation.framework/Versions/A",
            "/Applications/Dia.app/Contents/Frameworks/Sparkle.framework/Versions/B",
            "/Applications/Google Chrome.app/Contents/Frameworks/Sparkle.framework/Versions/B",
        ] {
            #expect(!DeletionSafetyPolicy.isWhitelistedStaleBrowserFrameworkPath(path), "\(path)")
        }
    }

    @Test
    func safariPrefixNoLongerCoversItsSyncAgents() {
        #expect(SafetyTierList.evaluate(folderName: "com.apple.SafariBookmarksSyncAgent") == nil)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "com.apple.Safari")?.safetyLevel == .safe)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "com.apple.Safari.SafeBrowsing")?.safetyLevel == .safe)
    }

    @Test(arguments: [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.controlcenter.helper",
        "com.apple.systemsettings.menucache",
        "com.apple.Settings",
        "com.apple.systempreferences.cache",
        "com.crowdstrike.falcon.Agent",
        "com.jamfsoftware.selfservice.mac",
        "com.paloaltonetworks.GlobalProtect.client",
        "com.cisco.secureclient.gui",
        "im.rime.inputmethod.Squirrel",
        "com.sogou.inputmethod.sogou",
    ])
    func systemUIAndSecurityAgentCachesAreNeverOffered(folderName: String) {
        #expect(AuditPaths.evaluate("Library/Caches/\(folderName)") == .blockedNeverDelete)
        #expect(
            AuditPaths.evaluate("Library/Containers/\(folderName)/Data/Library/Caches/x") == .blockedNeverDelete
        )
    }

    /// Crash Reports has its own row, so Application Logs must not reach it.
    @Test
    func applicationLogsAndCrashReportsAreSeparateDefinitions() {
        #expect(ExplanationDatabase.definitionKey(forFolderName: "Logs") == "applogs")
        #expect(ExplanationDatabase.definitionKey(forFolderName: "DiagnosticReports") == "crashreports")
        #expect(CacheScanner.crashReportsFolderName == "DiagnosticReports")
    }
}

@Suite("Spotify cache is held back when offline music exists")
struct SpotifyOfflineMusicTests {
    @Test
    func onlySpotifyPathsAreChecked() {
        let other = AuditPaths.url("Library/Caches/com.tinyspeck.slackmacgap")
        #expect(!DeletionSafetyPolicy.spotifyOfflineMusicRefusesDeletion(other))
    }

    @Test
    func refusalFollowsTheOfflineIndex() {
        let spotify = AuditPaths.url("Library/Caches/com.spotify.client")
        #expect(
            DeletionSafetyPolicy.spotifyOfflineMusicRefusesDeletion(spotify)
                == DeletionSafetyPolicy.spotifyOfflineIndexShowsDownloads(home: AuditPaths.home)
        )
    }
}

// MARK: - Part 5: additions

@Suite("Allowlist audit: additions")
struct AllowlistAdditionTests {
    @Test(arguments: [
        "Library/iTunes/iPhone Software Updates",
        "Library/iTunes/iPad Software Updates",
        "Movies/CacheClip",
        "Library/Developer/CoreSimulator/Caches",
        "Library/Developer/XCTestDevices",
        "Library/Developer/Xcode/watchOS DeviceSupport",
        "Library/pnpm/store",
        ".yarn/berry/cache",
        ".cache/pre-commit",
        ".cache/prisma",
        ".expo/versions-cache",
        ".pyenv/cache",
        ".rbenv/cache",
        ".oh-my-zsh/cache",
        ".opam/download-cache",
        ".cache/puppeteer",
        ".conda/pkgs",
        "miniforge3/pkgs",
        "Library/Application Support/com.apple.wallpaper/aerials/videos",
        "Library/Messages/Caches/Previews",
        "Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        "Downloads/installer.dmg.crdownload",
        "Downloads/movie.mkv.part",
        "Downloads/archive.zip.download",
    ])
    func newCachesAreOffered(relative: String) {
        #expect(AuditPaths.evaluate(relative) == .allow, "\(relative)")
    }

    /// The neighbours of each addition that hold real data stay out.
    @Test(arguments: [
        "Library/Application Support/com.apple.wallpaper/aerials/thumbnails",
        "Library/Application Support/com.apple.wallpaper/aerials/manifest",
        ".expo/state.json",
        ".pyenv/versions",
        ".rbenv/versions",
        ".conda/envs",
        "miniforge3/envs",
        "Library/Messages/chat.db",
        "Library/Containers/com.apple.mail/Data/Library/Mail",
        "Downloads/report.pdf",
        "Downloads/project/notes.part",
        ".oh-my-zsh/custom",
        "Movies/My Film.mov",
    ])
    func neighboursStayOut(relative: String) {
        #expect(AuditPaths.evaluate(relative) != .allow, "\(relative)")
    }

    @Test(arguments: [
        ("Simulator Caches", SafetyLevel.safe),
        ("Xcode Test Devices", .safe),
        ("Xcode Device Support", .medium),
        ("Old Claude Code Versions", .safe),
        ("Old Cursor Agent Versions", .safe),
        ("Dart Pub Cache", .safe),
        ("pre-commit Environments", .safe),
        ("Prisma Engines", .safe),
        ("Expo Cache", .safe),
        ("pyenv and rbenv Downloads", .safe),
        ("Oh My Zsh Cache", .safe),
        ("opam Download Cache", .safe),
        ("Puppeteer Browsers", .medium),
        ("Conda Package Cache", .medium),
    ])
    func newDevToolRowsResolve(label: String, level: SafetyLevel) {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: label, primaryPath: nil)
        #expect(info.level == level, "\(label) is \(info.level)")
    }

    @Test(arguments: [
        ("Device Software Updates", SafetyLevel.safe),
        ("CacheClip", .safe),
        ("Aerial Wallpaper Videos", .medium),
        ("Messages Previews", .safe),
        ("Mail Downloads", .medium),
        ("Unfinished Downloads", .medium),
        ("Electron Updater Downloads", .safe),
        ("node-gyp", .safe),
        ("typescript", .safe),
        ("claude-cli-nodejs", .safe),
        ("Adobe Camera Raw 2", .safe),
    ])
    func newAppCacheEntriesResolve(name: String, level: SafetyLevel) {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: name)?.safetyLevel == level, "\(name)")
    }

    @Test
    func electronUpdaterNeedsItsPendingFolder() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let real = base.appendingPathComponent("t3code-updater", isDirectory: true)
        try fm.createDirectory(at: real.appendingPathComponent("pending"), withIntermediateDirectories: true)
        let lookalike = base.appendingPathComponent("my-updater", isDirectory: true)
        try fm.createDirectory(at: lookalike, withIntermediateDirectories: true)
        #expect(CacheDiscoveryPaths.isElectronUpdaterCache(real))
        #expect(!CacheDiscoveryPaths.isElectronUpdaterCache(lookalike))
    }

    @Test
    func electronHTTPCacheIsSafeOnlyWithChromiumLayout() throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        defer { try? fm.removeItem(at: support.deletingLastPathComponent().deletingLastPathComponent()) }
        let chromium = support.appendingPathComponent("Recordly/Cache", isDirectory: true)
        try fm.createDirectory(at: chromium.appendingPathComponent("Cache_Data"), withIntermediateDirectories: true)
        let plain = support.appendingPathComponent("SomeApp/Cache", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(SafetyTierList.evaluate(folderName: "Recordly", path: chromium) == .safe)
        #expect(SafetyTierList.evaluate(folderName: "SomeApp", path: plain) == nil)
    }

    @Test
    func cliVersionsKeepTheOneInUseAndTheNewest() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let versions = base.appendingPathComponent("versions", isDirectory: true)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        for version in ["2.1.9", "2.1.10", "2.1.237"] {
            try Data().write(to: versions.appendingPathComponent(version))
        }
        let command = base.appendingPathComponent("claude")
        try fm.createSymbolicLink(at: command, withDestinationURL: versions.appendingPathComponent("2.1.10"))

        let kept = DeletionSafetyPolicy.keptCLIVersions(versionsRoot: versions.path, command: command.path)
        #expect(kept == ["2.1.10", "2.1.237"])

        try fm.removeItem(at: command)
        #expect(DeletionSafetyPolicy.keptCLIVersions(versionsRoot: versions.path, command: command.path) == nil)
    }

    @Test
    func unfinishedDownloadsMustBeAWeekOld() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let stale = downloads.appendingPathComponent("old.iso.crdownload")
        let fresh = downloads.appendingPathComponent("now.iso.crdownload")
        let finished = downloads.appendingPathComponent("done.iso")
        for url in [stale, fresh, finished] { try Data("x".utf8).write(to: url) }
        let longAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: stale.path)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: finished.path)

        let found = CacheDiscoveryPaths.unfinishedDownloadURLs(home: home).map(\.lastPathComponent)
        #expect(found == ["old.iso.crdownload"])
    }
}
