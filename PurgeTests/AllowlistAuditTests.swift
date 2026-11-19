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
        "SBT Cache", "Unused Playwright Browsers", "Go Module Cache",
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

    /// Records every path it is asked about.
    private final class SpyFileManager: FileManager, @unchecked Sendable {
        private(set) var paths: [String] = []
        override func fileExists(atPath path: String) -> Bool {
            paths.append(path)
            return super.fileExists(atPath: path)
        }
        override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            paths.append(path)
            return super.fileExists(atPath: path, isDirectory: isDirectory)
        }
        override func destinationOfSymbolicLink(atPath path: String) throws -> String {
            paths.append(path)
            return try super.destinationOfSymbolicLink(atPath: path)
        }
    }

    /// Looking at a removable or network volume can ask for permission, so a
    /// limited scan never looks under `/Volumes` (#183).
    @Test
    func aLimitedScanNeverLooksAtAVolume() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let entry = try makeEntry(in: root, json: #"{"folder":"file:///Volumes/Purge-Test-\#(UUID().uuidString)/app"}"#)
        let spy = SpyFileManager()

        #expect(!EditorWorkspaceStoragePolicy.isOrphaned(entry: entry, access: .limited, fileManager: spy))
        #expect(!spy.paths.contains { $0.hasPrefix("/Volumes") })
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
    /// packages, committed git hooks, installed tool versions, and tool folders
    /// that keep config or the tool itself next to a cache (`.moon`, `.nx`,
    /// `~/.hex`) (#184).
    @Test(arguments: ["Cellar", ".husky", ".volta", ".mise", "Devices", ".moon", ".nx", ".hex"])
    func nonCacheFolderNamesHaveNoEntry(name: String) {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: name) == nil)
    }

    /// A sandboxed app can keep SwiftPM's cache in its own container, and the
    /// container scan looks that folder up by its name, so the entry stays even
    /// though Dev Tools owns `~/Library/Caches/org.swift.swiftpm` (#184).
    @Test
    func containerSwiftPMCacheKeepsItsEntry() {
        #expect(ExplanationDatabase.definitionKey(forFolderName: "org.swift.swiftpm") == "swiftpm")
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "org.swift.swiftpm")?.safetyLevel == .safe)
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

    /// Dev Tools listed `~/.git/worktrees` once, but the allowlist never let it
    /// through, so the row was removed (#184).
    @Test
    func gitWorktreeRecordsAreNotOffered() {
        #expect(AuditPaths.evaluate(".git/worktrees") != .allow)
    }

    @Test
    func containerManagerCacheIsNeverOffered() {
        #expect(AuditPaths.evaluate("Library/Caches/com.apple.containermanagerd") == .blockedNeverDelete)
    }

    /// The row is Safe, and its text once said Mise would have to download every
    /// tool again. The cache holds version lists; installs live elsewhere (#191).
    @Test
    func miseTextMatchesItsSafeTag() throws {
        let record = try #require(ExplanationDatabase.record(forKey: "mise-cache"))
        #expect(record.tag == "safe")
        #expect(record.explanation.contains("Installed tools stay"))
        #expect(!record.explanation.contains("re-download any tools"))
    }

    @Test(arguments: ["dotnet-bin", "dotnet-obj"])
    func dotNetNamesKeepTheirDot(key: String) {
        #expect(ExplanationDatabase.record(forKey: key)?.displayName.hasPrefix(".NET ") == true)
    }

    /// "Comet" is the Comet browser's own folder name. As an alias of the
    /// updater entry it gave the browser's caches the updater's name and tier (#183).
    @Test
    func cometBrowserIsNotTheUpdater() {
        #expect(ExplanationDatabase.definitionKey(forFolderName: "Comet") != "perplexity-updater")
        #expect(ExplanationDatabase.definitionKey(forFolderName: "ai.perplexity.CometUpdater") == "perplexity-updater")
    }

    /// The rows picked the "newest" extension by folder name alone and never
    /// resolved to a tier, so they were sized on every scan and never shown (#183).
    @Test(arguments: ["obsolete-cursor-extension", "obsolete-vscode-extension"])
    func obsoleteExtensionEntriesAreGone(key: String) {
        #expect(ExplanationDatabase.record(forKey: key) == nil)
    }

    /// Their allow rule went too. It let through any folder directly inside the
    /// extensions folder, installed extensions included, and its tier rule
    /// called them Safe (#183).
    @Test(arguments: [".vscode/extensions/ms-python.python-2026.1.0", ".cursor/extensions/esbenp.prettier-vscode-11.0.0"])
    func installedExtensionsAreNeverAllowed(relative: String) {
        #expect(AuditPaths.evaluate(relative) != .allow)
        #expect(SafetyTierList.evaluate(folderName: (relative as NSString).lastPathComponent, path: AuditPaths.url(relative)) != .safe)
    }

    /// Go's build cache is `~/Library/Caches/go-build` on macOS. Dev Tools listed
    /// only `~/.cache/go-build`, so the real one showed again under App Caches (#183).
    @Test
    func goBuildCacheIsOneDevToolsRow() {
        let path = AuditPaths.url("Library/Caches/go-build").standardizedFileURL.path
        #expect(DevScanner.claimedGlobalCachePaths().contains(path))
        #expect(AuditPaths.evaluate("Library/Caches/go-build") == .allow)
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "Go Build Cache", primaryPath: nil)
        #expect(info.level == .safe)
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
    /// #127: only an entry directly inside the folder is allowed, never the folder,
    /// `Locked Files`, or the `/macOS Install Data` spelling, which isn't a firmlink.
    @Test
    func macOSInstallLeftoversAreDirectChildrenOnly() {
        let root = MacOSInstallLeftovers.root.path
        func evaluate(_ path: String) -> DeletionSafetyDecision {
            DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: path))
        }
        #expect(evaluate("\(root)/UpdateBundle") == .allow)
        #expect(evaluate("\(root)/InstallInfo.plist") == .allow)
        #expect(evaluate(root) != .allow)
        #expect(evaluate("\(root)/Locked Files") != .allow)
        #expect(evaluate("\(root)/Locked Files/x") != .allow)
        #expect(evaluate("\(root)/UpdateBundle/Payload") != .allow)
        #expect(evaluate("\(root)/.hidden") != .allow)
        #expect(evaluate("/macOS Install Data/UpdateBundle") != .allow)
        #expect(evaluate("/System/Volumes/Data/Library/UpdateBundle") != .allow)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: CacheDiscoveryPaths.macOSInstallDataKey)?
            .safetyLevel == .medium)
    }

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
        "Downloads/ParallelsDesktop.dmg.prlupd-part",
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
        // Mise's installs, which the Safe Mise row's text promises stay (#191).
        ".local/share/mise",
        ".local/share/mise/installs",
        ".local/share/mise/installs/node/22.11.0",
        ".conda/envs",
        "miniforge3/envs",
        "Library/Messages/chat.db",
        "Library/Containers/com.apple.mail/Data/Library/Mail",
        "Downloads/report.pdf",
        "Downloads/project/notes.part",
        "Downloads/project/setup.prlupd-part",
        "Downloads/Notes.part/chapter.pdf",
        "Downloads/X.prlupd-part/inner.bin",
        "Downloads/X.crdownload/inner.bin",
        ".oh-my-zsh/custom",
        "Movies/My Film.mov",
        // Gradle's own folder, which a stray `~/settings.gradle` made a project
        // artifact (#190). Its caches are separate rows.
        ".gradle",
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

    @Test
    func prekCacheDefaultsToCheckFirstAndKeepsRecoveryPatches() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("prek-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let claimed = DevScanner.claimedGlobalCachePaths(home: home)
        for folder in ["repos", "hooks", "tools", "cache"] {
            let path = ".cache/prek/\(folder)"
            #expect(claimed.contains(home.appendingPathComponent(path).standardizedFileURL.path))
            #expect(AuditPaths.evaluate(path) == .allow)
        }
        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: "prek Cache", primaryPath: nil).level == .medium)
        for path in [".cache", ".cache/prek", ".cache/prek/patches", ".cache/prek/patches/123-456.patch",
                     ".cache/prek/repos-backup", ".cache/prek-backup/repos", ".config/prek"] {
            #expect(!claimed.contains(home.appendingPathComponent(path).standardizedFileURL.path))
            #expect(AuditPaths.evaluate(path) != .allow)
        }
    }

    @Test(arguments: ["tools", "tools/rust/1.90/bin/cargo"])
    func keptPrekHooksKeepTheirManagedTools(relative: String) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("prek-\(UUID().uuidString)", isDirectory: true)
        let root = home.appendingPathComponent(".cache/prek", isDirectory: true)
        let path = root.appendingPathComponent(relative)
        let hooks = root.appendingPathComponent("hooks", isDirectory: true)
        var hooksExcluded = false
        let isExcluded: (URL) -> Bool = { hooksExcluded && $0 == hooks }
        #expect(!DeletionSafetyPolicy.prekToolsRefuseDeletion(path, home: home.path, isExcluded: isExcluded))
        hooksExcluded = true
        #expect(DeletionSafetyPolicy.prekToolsRefuseDeletion(path, home: home.path, isExcluded: isExcluded))
        hooksExcluded = false
        #expect(!DeletionSafetyPolicy.prekToolsRefuseDeletion(path, home: home.path, isExcluded: isExcluded))
    }

    @Test(arguments: ["repos", "hooks", "cache", "patches", "tools-backup", "../prek-backup/tools"])
    func prekToolsDependencyGuardLeavesOtherPathsAlone(relative: String) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("prek-\(UUID().uuidString)", isDirectory: true)
        let path = home.appendingPathComponent(".cache/prek/\(relative)")
        #expect(!DeletionSafetyPolicy.prekToolsRefuseDeletion(path, home: home.path, isExcluded: { _ in true }))
    }

    // The allowlist accepts `.cache/prek/repos` by its text, so a store that is a link
    // to another folder is caught only by this recheck.
    @Test(arguments: [true, false])
    func prekStoreReachedThroughALinkIsRefused(storeIsLink: Bool) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("prek-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let store = home.appendingPathComponent(".cache/prek", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Developer", isDirectory: true)
        let folders = ["repos", "hooks", "tools", "cache"]
        if storeIsLink {
            try fm.createDirectory(at: home.appendingPathComponent(".cache", isDirectory: true), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: store, withDestinationURL: elsewhere)
        }
        for folder in folders {
            try fm.createDirectory(at: (storeIsLink ? elsewhere : store).appendingPathComponent(folder, isDirectory: true),
                                   withIntermediateDirectories: true)
        }
        for folder in folders {
            let url = store.appendingPathComponent(folder, isDirectory: true)
            #expect(fm.fileExists(atPath: url.path))
            #expect(DeletionSafetyPolicy.prekStoreLinkRefusesDeletion(url, home: home.path) == storeIsLink, "\(folder)")
        }
    }

    @Test(arguments: [
        ("Device Software Updates", SafetyLevel.safe),
        ("CacheClip", .safe),
        ("Aerial Wallpaper Videos", .medium),
        ("Messages Previews", .safe),
        ("Mail Downloads", .medium),
        ("Unfinished Downloads", .medium),
        ("Electron Updater Downloads", .safe),
        ("Unsent Crash Reports", .medium),
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
        #expect(SafetyTierList.evaluate(folderName: "Recordly", path: chromium) == nil)
        try Data().write(to: support.appendingPathComponent("Recordly/Network Persistent State"))
        try Data().write(to: support.appendingPathComponent("SomeApp/Network Persistent State"))
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

    /// Only Safari writes a download as a folder. A week-old folder named like
    /// a Chrome, Firefox or Parallels download is the user's and stays out.
    @Test
    func onlySafariDownloadsMayBeFolders() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let longAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        for name in ["Notes.part", "X.prlupd-part", "Y.crdownload", "Z.zip.download"] {
            let folder = downloads.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("inner.bin"))
            try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: folder.path)
        }

        let found = CacheDiscoveryPaths.unfinishedDownloadURLs(home: home).map(\.lastPathComponent)
        #expect(found == ["Z.zip.download"])
    }
}

@Suite("Editor workspace storage: unreachable is not missing")
struct EditorWorkspaceStorageLookupTests {
    @Test
    func onlyANoSuchFileAnswerCountsAsMissing() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let locked = base.appendingPathComponent("locked", isDirectory: true)
        let project = locked.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("file")
        try Data().write(to: file)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: base)
        }

        #expect(EditorWorkspaceStoragePolicy.isConfirmedMissing(base.appendingPathComponent("gone").path))
        // A path through a file is ENOTDIR: it cannot exist either.
        #expect(EditorWorkspaceStoragePolicy.isConfirmedMissing(file.appendingPathComponent("child").path))
        #expect(!EditorWorkspaceStoragePolicy.isConfirmedMissing(project.path))

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        #expect(!fm.fileExists(atPath: project.path), "precondition: fileExists is fooled")
        #expect(!EditorWorkspaceStoragePolicy.isConfirmedMissing(project.path))
    }

    @Test
    func genericSimulatorEntryIsCheckFirst() {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "CoreSimulator")?.safetyLevel == .medium)
        let unused = SimulatorDevice.safetyInfo(
            isAvailable: true,
            lastBootedAt: Date().addingTimeInterval(-90 * 24 * 60 * 60),
            deviceName: "iPhone 17",
            runtimeVersion: "iOS 26.5"
        )
        // Simulators are removed for good, so even an unused device is Check First (#136).
        #expect(unused.level == .medium)
    }
}

// MARK: - Part 6: caches the Everything else breakdown found off the list (#222)

@Suite("Allowlist audit: Everything else caches")
struct EverythingElseCacheAuditTests {
    /// Folders directly in `~/Library/Caches` are allowed by the prefix; what
    /// decides whether a row appears is the entry each name resolves to.
    @Test(arguments: [
        ("Dia", SafetyLevel.safe),
        ("company.thebrowser.dia", .safe),
        ("Codex", .safe),
        ("com.openai.codex", .safe),
        ("EffectCraft", .safe),
        ("ai.storyteller.effectcraft", .safe),
    ])
    func appCacheFoldersResolve(name: String, level: SafetyLevel) {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: name)?.safetyLevel == level, "\(name)")
        #expect(AuditPaths.evaluate("Library/Caches/\(name)") == .allow, "\(name)")
    }

    @Test(arguments: [
        ("Dart Analysis Cache", SafetyLevel.safe),
        ("Hermes Agent Cache", .medium),
        ("opencode Cache", .medium),
        ("Antigravity Browser Cache", .safe),
        ("Gradle Cache", .medium),
    ])
    func newDevToolRowsResolve(label: String, level: SafetyLevel) {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: label, primaryPath: nil)
        #expect(info.level == level, "\(label) is \(info.level)")
    }

    @Test(arguments: [
        ".dartServer/.analysis-driver",
        ".dartServer/.analysis-driver/00/000221a840a7647fa5a6f8c8bca330a6.unlinked2",
        ".hermes/cache",
        ".hermes/cache/uv/archive-v0",
        ".hermes/cache/scratch",
        ".gradle/wrapper/dists",
        ".gradle/wrapper/dists/gradle-8.7-bin/bhs2wmbdwecv87pi65oeuq5iu/gradle-8.7-bin.zip",
    ])
    func newCachesAreOffered(relative: String) {
        #expect(AuditPaths.evaluate(relative) == .allow, "\(relative)")
    }

    /// Everything next to each addition that holds settings, keys, sessions, a
    /// browser's sign-ins, or an installed runtime stays out.
    @Test(arguments: [
        ".dartServer",
        ".dartServer/.prompts/preferences.json",
        ".dartServer/.instrumentation",
        ".dartServer/.pub-package-details-cache",
        ".hermes",
        ".hermes/config.yaml",
        ".hermes/.env",
        ".hermes/auth.json",
        ".hermes/memories",
        ".hermes/sessions",
        ".hermes/state.db",
        ".hermes/skills",
        ".hermes/hermes-agent",
        ".hermes/bin/lightpanda",
        ".gradle/wrapper",
        ".gradle/wrapper/gradle-wrapper.properties",
        ".gradle/jdks",
        ".gradle/gradle.properties",
        ".gradle/init.d",
        ".gradle/daemon",
        ".gemini",
        ".gemini/settings.json",
        ".gemini/antigravity",
        ".gemini/antigravity-ide",
        ".gemini/antigravity-browser-profile",
        ".gemini/antigravity-browser-profile/Local State",
        ".gemini/antigravity-browser-profile/Default",
        ".gemini/antigravity-browser-profile/Default/Login Data",
        ".gemini/antigravity-browser-profile/Default/Cookies",
        ".gemini/antigravity-browser-profile/Default/History",
        ".gemini/antigravity-browser-profile/Default/Preferences",
        ".gemini/antigravity-browser-profile/Default/Extensions",
        ".gemini/antigravity-browser-profile/Default/IndexedDB",
        ".gemini/antigravity-browser-profile/Default/Local Storage",
        ".gemini/antigravity-browser-profile/Default/Service Worker",
        ".gemini/antigravity-browser-profile/Default/Service Worker/Database",
        ".gemini/antigravity-browser-profile/Safe Browsing",
        ".gemini/other-browser-profile/Default/Cache",
        ".cache/codex-runtimes",
        ".cache/codex-runtimes/codex-primary-runtime/dependencies/node",
        ".cache/codex-runtimes/codex-runtime-install-8XQiDN/node-runtime.tar.xz",
    ])
    func neighboursStayOut(relative: String) {
        #expect(AuditPaths.evaluate(relative) != .allow, "\(relative)")
    }

    /// A browser profile's Service Worker caches are refused wherever the
    /// browser keeps them. Losing `ScriptCache` makes Chromium delete each
    /// site's registration and its web push subscription, and `CacheStorage`
    /// holds installed web apps' offline content. On a Mac with these browsers
    /// the shape rules see the real folders; elsewhere they are missing.
    @Test(arguments: [
        "Library/Application Support/Google/Chrome/Default/Service Worker/ScriptCache",
        "Library/Application Support/Google/Chrome Beta/Default/Service Worker/ScriptCache",
        "Library/Application Support/Google/Chrome Beta/Default/Service Worker/CacheStorage",
        "Library/Application Support/BraveSoftware/Brave-Browser/Default/Service Worker/ScriptCache",
        "Library/Application Support/Microsoft Edge/Default/Service Worker/ScriptCache",
        "Library/Application Support/Dia/User Data/Default/Service Worker/ScriptCache",
        "Library/Application Support/Dia/User Data/Default/Service Worker/CacheStorage",
        "Library/Application Support/Arc/User Data/Default/Service Worker/CacheStorage",
        ".gemini/antigravity-browser-profile/Default/Service Worker/CacheStorage",
    ])
    func browserServiceWorkerCachesAreRefused(relative: String) {
        #expect(AuditPaths.evaluate(relative) != .allow, "\(relative)")
        #expect(AuditPaths.evaluate(relative + "/index") != .allow, "\(relative)")
        let tier = SafetyTierList.evaluate(folderName: "Dia", path: AuditPaths.url(relative))
        #expect(tier != .safe, "\(relative)")
    }

    /// Discovery lists the same shape the policy allows: the cache folders at the
    /// root and in each profile, never a profile, its Service Worker caches, or
    /// the files beside the caches.
    @Test
    func chromiumUserDataDiscoveryListsOnlyCaches() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userData = base.appendingPathComponent("browser-profile", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        for folder in [
            "Default/Cache/Cache_Data", "Default/Code Cache/js", "Default/Service Worker/CacheStorage",
            "Default/Service Worker/ScriptCache", "Default/Service Worker/Database", "Default/Extensions",
            "Default/IndexedDB",
            "Profile 1/GPUCache", "Profile 1/Cache", "component_crx_cache", "Safe Browsing", "GraphiteDawnCache",
            "Profile 1/DawnGraphiteCache",
        ] {
            try fm.createDirectory(at: userData.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Local State", "Default/Login Data", "Default/Cookies", "Default/History"] {
            try Data("x".utf8).write(to: userData.appendingPathComponent(file))
        }

        let root = userData.standardizedFileURL.path
        let found = CacheDiscoveryPaths.chromiumUserDataCacheURLs(userData: userData, access: .full)
            .map { String($0.path.dropFirst(root.count + 1)) }
        // `Profile 1/Cache` has no Chromium layout inside, so it is left out.
        #expect(found == [
            "Default/Cache",
            "Default/Code Cache",
            "GraphiteDawnCache",
            "Profile 1/DawnGraphiteCache",
            "Profile 1/GPUCache",
            "component_crx_cache",
        ])

        try fm.removeItem(at: userData.appendingPathComponent("Local State"))
        #expect(CacheDiscoveryPaths.chromiumUserDataCacheURLs(userData: userData, access: .full).isEmpty)
    }

    /// The Antigravity profile's gate allows the same shape discovery lists, and
    /// anything inside one of those caches. A bare `Cache` with nothing of
    /// Chromium's inside is refused, as it is under Application Support.
    @Test
    func antigravityGateMatchesDiscovery() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("purge-test-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let profile = home.appendingPathComponent(".gemini/antigravity-browser-profile", isDirectory: true)
        for folder in [
            "Default/Cache/Cache_Data", "Default/Code Cache", "Default/GPUCache", "Default/ShaderCache",
            "Default/Service Worker/CacheStorage", "Default/Service Worker/ScriptCache", "Profile 1/Cache",
            "component_crx_cache", "ShaderCache", "GraphiteDawnCache",
        ] {
            try fm.createDirectory(at: profile.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data().write(to: profile.appendingPathComponent("Default/Cache/Cache_Data/index"))
        func allowed(_ relative: String) -> Bool {
            DeletionSafetyPolicy.isWhitelistedChromiumUserDataCachePath(profile.path + "/" + relative, home: home.path)
        }

        #expect(!allowed("Default/Cache"))
        try Data().write(to: profile.appendingPathComponent("Local State"))
        for relative in [
            "Default/Cache", "Default/Cache/Cache_Data/index", "Default/Code Cache", "Default/GPUCache",
            "Default/ShaderCache", "component_crx_cache", "ShaderCache", "GraphiteDawnCache",
        ] {
            #expect(allowed(relative), "\(relative)")
        }
        for relative in [
            "Default", "Local State", "Default/Login Data", "Default/Service Worker",
            "Default/Service Worker/CacheStorage", "Default/Service Worker/ScriptCache", "Profile 1/Cache",
        ] {
            #expect(!allowed(relative), "\(relative)")
        }
    }

    /// The store the scanner lists is the one the policy allows.
    @Test
    func antigravityProfileIsTheOnlyChromiumStoreOutsideApplicationSupport() {
        let stores = DeletionSafetyPolicy.chromiumUserDataStores
        #expect(stores.map(\.relative) == [".gemini/antigravity-browser-profile"])
        #expect(stores.map(\.label) == ["Antigravity Browser Cache"])
        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: "Antigravity Browser Cache", primaryPath: nil).level == .safe)
    }
}

// MARK: - uv's package cache

@Suite("uv cache (#345): offered, never Safe")
struct UVCacheTests {
    @Test(arguments: [
        ".cache/uv",
        ".cache/uv/archive-v0/1a2b3c/numpy/__init__.py",
        ".cache/uv/wheels-v7/pypi/numpy",
        ".cache/uv/environments-v2/ruff-0a1b2c",
    ])
    func cacheIsOffered(relative: String) {
        #expect(AuditPaths.evaluate(relative) == .allow, "\(relative)")
    }

    /// The Dev Tools scan lists the folder, so it is a row and not only allowed.
    @Test
    func devToolsScanListsTheFolder() {
        #expect(DevScanner.claimedGlobalCachePaths().contains(AuditPaths.url(".cache/uv").standardizedFileURL.path))
    }

    /// A tool started with `uvx` runs from an environment inside the cache, and
    /// with `link-mode = "symlink"` an environment's packages are links into it.
    /// uv does not put either back by itself, so Clean Safe Items and scheduled
    /// cleans must not take the folder.
    @Test
    func rowIsNeverSafe() {
        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: "uv Package Cache", primaryPath: nil).level == .medium)
        #expect(bundledLevel("uv-cache") == .medium)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "uv")?.safetyLevel == .medium)
    }

    /// Tools from `uv tool install`, uv's Python versions and its settings.
    @Test(arguments: [
        ".local/share/uv",
        ".local/share/uv/tools",
        ".local/share/uv/tools/ruff",
        ".local/share/uv/python/cpython-3.13.1-macos-aarch64-none",
        ".config/uv",
        ".config/uv/uv.toml",
        ".cache",
    ])
    func installsAndSettingsStayOut(relative: String) {
        #expect(AuditPaths.evaluate(relative) != .allow, "\(relative)")
    }
}

// MARK: - Rows under ~/.cache reached through a link (#420)

/// The allowlist accepts `.cache/uv` by its text. With `~/.cache`, the folder
/// itself or a folder between them a link to `~/Developer`, a move would take
/// `~/Developer/uv`, so only `dotCacheLinkRefusesDeletion` catches it.
@Suite("~/.cache rows reached through a link (#420)")
struct DotCacheLinkTests {
    /// A temporary home, with a `Developer` folder beside it for links to point at.
    private static func makeHome() throws -> (base: URL, home: URL, elsewhere: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("dot-cache-link-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Developer", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        return (base, home, elsewhere)
    }

    /// The allowlist's own entries under `.cache`, relative to home.
    private static func entries(_ home: URL) -> [String] {
        DeletionSafetyPolicy.dotCacheEntries(home: home.path).map { String($0.dropFirst(home.path.count + 1)) }
    }

    private static func refuses(_ relative: String, home: URL) -> Bool {
        DeletionSafetyPolicy.dotCacheLinkRefusesDeletion(home.appendingPathComponent(relative), home: home.path)
    }

    @Test
    func entriesAreTheAllowlistRowsUnderDotCache() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let entries = Set(Self.entries(home))
        for expected in [
            ".cache/node/corepack", ".cache/act", ".cache/rebar3", ".cache/bazel", ".cache/go-build",
            ".cache/pre-commit", ".cache/prek/repos", ".cache/prek/hooks", ".cache/prek/tools", ".cache/prek/cache",
            ".cache/prisma", ".cache/puppeteer", ".cache/giget", ".cache/firebase/emulators", ".cache/uv",
            ".cache/opencode",
        ] {
            #expect(entries.contains(expected), "\(expected)")
        }
        #expect(entries.allSatisfy { $0.hasPrefix(".cache/") })
    }

    @Test
    func everyEntryIsRefusedWhenDotCacheIsALink() throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        try fm.createSymbolicLink(at: home.appendingPathComponent(".cache"), withDestinationURL: elsewhere)
        let entries = Self.entries(home)
        #expect(!entries.isEmpty)
        for relative in entries {
            // The folder a move would really take.
            let behind = elsewhere.appendingPathComponent(String(relative.dropFirst(".cache/".count)), isDirectory: true)
            try fm.createDirectory(at: behind.appendingPathComponent("inner", isDirectory: true), withIntermediateDirectories: true)
            for path in [relative, "\(relative)/inner"] {
                #expect(fm.fileExists(atPath: home.appendingPathComponent(path).path))
                #expect(Self.refuses(path, home: home), "\(path)")
            }
        }
    }

    @Test
    func everyEntryIsRefusedWhenItsOwnFolderIsALink() throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        for (index, relative) in Self.entries(home).enumerated() {
            let entry = home.appendingPathComponent(relative)
            let behind = elsewhere.appendingPathComponent("target-\(index)", isDirectory: true)
            try fm.createDirectory(at: behind.appendingPathComponent("inner", isDirectory: true), withIntermediateDirectories: true)
            try fm.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: entry, withDestinationURL: behind)
            for path in [relative, "\(relative)/inner"] {
                #expect(fm.fileExists(atPath: home.appendingPathComponent(path).path))
                #expect(Self.refuses(path, home: home), "\(path)")
            }
        }
    }

    @Test
    func aLinkedFolderRefusesOnlyItsOwnRow() throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: home.appendingPathComponent(".cache/giget/inner", isDirectory: true), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".cache/uv"), withDestinationURL: elsewhere)
        #expect(Self.refuses(".cache/uv", home: home))
        #expect(!Self.refuses(".cache/giget", home: home))
        #expect(!Self.refuses(".cache/giget/inner", home: home))
    }

    @Test(arguments: [
        (".cache/firebase", ".cache/firebase/emulators"),
        (".cache/node", ".cache/node/corepack"),
        (".cache/prek", ".cache/prek/repos"),
    ])
    func aLinkedFolderOnTheWayRefusesTheEntry(link: String, entry: String) throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: elsewhere.appendingPathComponent((entry as NSString).lastPathComponent, isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".cache/uv", isDirectory: true), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent(link), withDestinationURL: elsewhere)
        #expect(fm.fileExists(atPath: home.appendingPathComponent(entry).path))
        #expect(Self.refuses(entry, home: home))
        #expect(!Self.refuses(".cache/uv", home: home))
    }

    /// An unlinked `~/.cache` offers what it did before, whether or not the
    /// folders are on disk.
    @Test(arguments: [true, false])
    func nothingIsRefusedWithoutALink(foldersExist: Bool) throws {
        let fm = FileManager.default
        let (base, home, _) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        let entries = Self.entries(home)
        #expect(!entries.isEmpty)
        for relative in entries {
            if foldersExist {
                try fm.createDirectory(at: home.appendingPathComponent("\(relative)/inner", isDirectory: true),
                                       withIntermediateDirectories: true)
            }
            for path in [relative, "\(relative)/inner"] {
                #expect(!Self.refuses(path, home: home), "\(path)")
            }
        }
    }

    /// A link inside the cache moves to the Trash as a link, so it refuses nothing.
    @Test
    func aLinkInsideTheFolderRefusesNothing() throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: home.appendingPathComponent(".cache/uv/archive-v0", isDirectory: true), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".cache/uv/archive-v0/link"), withDestinationURL: elsewhere)
        for path in [".cache/uv", ".cache/uv/archive-v0", ".cache/uv/archive-v0/link"] {
            #expect(!Self.refuses(path, home: home), "\(path)")
        }
    }

    /// The guard answers only for the allowlist's `~/.cache` entries. Every other
    /// path is left to `evaluate` and the other guards, linked or not.
    @Test(arguments: [true, false])
    func otherPathsAreLeftAlone(dotCacheIsLink: Bool) throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        if dotCacheIsLink {
            try fm.createSymbolicLink(at: home.appendingPathComponent(".cache"), withDestinationURL: elsewhere)
        } else {
            try fm.createDirectory(at: home.appendingPathComponent(".cache", isDirectory: true), withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: home.appendingPathComponent(".npm"), withDestinationURL: elsewhere)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".cache-link"), withDestinationURL: elsewhere)
        for path in [
            ".cache", ".cache/uv-old", ".cache/unknown", ".cache/unknown/inner", ".cache/firebase", ".cache/prek/patches",
            ".cachette/uv", ".nvm/.cache", ".npm", ".npm/_cacache", ".cache-link", ".cache-link/uv",
            "Developer/app/.cache", "Library/Caches/uv",
        ] {
            #expect(!Self.refuses(path, home: home), "\(path)")
        }
        #expect(!DeletionSafetyPolicy.dotCacheLinkRefusesDeletion(elsewhere.appendingPathComponent(".cache/uv"), home: home.path))
    }
}

// MARK: - opencode's cache

@Suite("opencode cache (#399): offered, never Safe")
struct OpencodeCacheTests {
    /// The current layout (`npm`, `bin`, `models.json`) and the older one
    /// (`packages`, `bun.lock`), plus a model list write that didn't finish.
    @Test(arguments: [
        ".cache/opencode",
        ".cache/opencode/npm/@ai-sdk/anthropic@latest/1/node_modules/@ai-sdk/anthropic/package.json",
        ".cache/opencode/packages/opencode-anthropic-auth@latest",
        ".cache/opencode/bin/rg",
        ".cache/opencode/models.json",
        ".cache/opencode/models.json.1a2b3c.tmp",
        ".cache/opencode/bun.lock",
    ])
    func cacheIsOffered(relative: String) {
        #expect(AuditPaths.evaluate(relative) == .allow, "\(relative)")
    }

    /// The Dev Tools scan lists the folder, so it is a row and not only allowed.
    /// A throwaway home, so the row list reads no real folder.
    @Test
    func devToolsScanListsTheFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let claimed = DevScanner.claimedGlobalCachePaths(home: home)
        #expect(claimed.contains(home.appendingPathComponent(".cache/opencode").standardizedFileURL.path))
    }

    /// A running session loads its provider and plugin packages from the cache,
    /// and `bin` holds tools opencode downloaded, so Clean Safe Items and
    /// scheduled cleans must not take the folder.
    @Test
    func rowIsNeverSafe() {
        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: "opencode Cache", primaryPath: nil).level == .medium)
        #expect(bundledLevel("opencode-cache") == .medium)
    }

    /// No alias, so a folder that is only named `opencode` somewhere else is not
    /// this row.
    @Test
    func nameAloneMatchesNothing() {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "opencode") == nil)
    }

    /// Sessions, undo snapshots, logins, settings and the install itself.
    @Test(arguments: [
        ".local/share/opencode",
        ".local/share/opencode/auth.json",
        ".local/share/opencode/opencode.db",
        ".local/share/opencode/snapshot",
        ".local/share/opencode/storage",
        ".local/share/opencode/log",
        ".local/state/opencode",
        ".config/opencode",
        ".config/opencode/opencode.json",
        ".opencode",
        ".opencode/bin/opencode",
        ".cache",
    ])
    func dataSettingsAndInstallStayOut(relative: String) {
        #expect(AuditPaths.evaluate(relative) != .allow, "\(relative)")
    }

    /// The allowlist accepts `.cache/opencode` by its text. With `~/.cache` or the
    /// folder itself a link to `~/Developer`, a move would take
    /// `~/Developer/opencode`, so only this recheck catches it.
    @Test(arguments: ["none", ".cache", ".cache/opencode"])
    func cacheReachedThroughALinkIsRefused(link: String) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("opencode-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let cache = home.appendingPathComponent(".cache/opencode", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Developer", isDirectory: true)
        switch link {
        case ".cache":
            try fm.createDirectory(at: elsewhere.appendingPathComponent("opencode/bin", isDirectory: true), withIntermediateDirectories: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: home.appendingPathComponent(".cache"), withDestinationURL: elsewhere)
        case ".cache/opencode":
            try fm.createDirectory(at: elsewhere.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
            try fm.createDirectory(at: home.appendingPathComponent(".cache", isDirectory: true), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: cache, withDestinationURL: elsewhere)
        default:
            try fm.createDirectory(at: cache.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        }
        for url in [cache, cache.appendingPathComponent("bin", isDirectory: true)] {
            #expect(fm.fileExists(atPath: url.path))
            #expect(DeletionSafetyPolicy.dotCacheLinkRefusesDeletion(url, home: home.path) == (link != "none"), "\(url.path)")
        }
    }

    /// A link inside the cache moves to the Trash as a link, so it refuses
    /// nothing, and the guard refuses no unlinked folder beside it.
    @Test
    func linkGuardCoversOnlyTheWayDownToTheCache() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("opencode-inner-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let cache = home.appendingPathComponent(".cache/opencode", isDirectory: true)
        try fm.createDirectory(at: cache.appendingPathComponent("npm", isDirectory: true), withIntermediateDirectories: true)
        let inner = cache.appendingPathComponent("npm/link")
        try fm.createSymbolicLink(at: inner, withDestinationURL: base)
        #expect(!DeletionSafetyPolicy.dotCacheLinkRefusesDeletion(cache, home: home.path))
        #expect(!DeletionSafetyPolicy.dotCacheLinkRefusesDeletion(inner, home: home.path))

        let other = home.appendingPathComponent(".cache-link", isDirectory: false)
        try fm.createSymbolicLink(at: other, withDestinationURL: base)
        for url in [other, home.appendingPathComponent(".cache/uv"), home.appendingPathComponent(".cache/opencode-old")] {
            #expect(!DeletionSafetyPolicy.dotCacheLinkRefusesDeletion(url, home: home.path), "\(url.path)")
        }
    }
}

// MARK: - Allowlisted rows reached through a link (#422)

/// The allowlist accepts `.gradle/caches` by its text. With `~/.gradle` a link
/// to `~/Developer`, a move would take `~/Developer/caches`, so only
/// `allowlistLinkRefusesDeletion` catches it. Every test builds its own home.
@Suite("Allowlisted rows reached through a link (#422)")
struct AllowlistLinkTests {
    /// A temporary home, with a `Developer` folder beside it for links to point at.
    private static func makeHome() throws -> (base: URL, home: URL, elsewhere: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("allowlist-link-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Developer", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        return (base, home, elsewhere)
    }

    /// Every allowlist entry, relative to home.
    private static func entries(_ home: URL) -> [String] {
        DeletionSafetyPolicy.whitelistedAbsolutePrefixes(home: home.path).map { String($0.dropFirst(home.path.count + 1)) }
    }

    private static func refuses(_ relative: String, home: URL) -> Bool {
        DeletionSafetyPolicy.allowlistLinkRefusesDeletion(home.appendingPathComponent(relative), home: home.path)
    }

    private static func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Where `relative` lands when `link`, a folder at or above it, points at `target`.
    private static func behind(_ relative: String, link: String, target: URL) -> URL {
        let rest = relative.dropFirst(link.count).drop { $0 == "/" }
        return rest.isEmpty ? target : target.appendingPathComponent(String(rest), isDirectory: true)
    }

    /// The guard starts from the list itself, so a new entry is covered the day
    /// it is added.
    @Test
    func everyEntryIsFoundByItsText() {
        let home = "/Users/someone"
        let entries = DeletionSafetyPolicy.whitelistedAbsolutePrefixes(home: home)
        #expect(entries.count > 80)
        for entry in entries {
            #expect(DeletionSafetyPolicy.allowlistEntry(containing: entry, home: home) == entry, "\(entry)")
            #expect(DeletionSafetyPolicy.allowlistEntry(containing: "\(entry)/a/b", home: home) == entry, "\(entry)")
            #expect(DeletionSafetyPolicy.allowlistEntry(containing: "\(entry)-old", home: home) == nil, "\(entry)")
        }
        for other in [
            home, "\(home)/", "\(home)/.gradle", "\(home)/.gradle/jdks", "\(home)/Library", "\(home)/Library/CachesX/a",
            "\(home)/.cache/unknown", "\(home)2/.npm", "/Users/other/.npm", "/Library/Caches/a", "",
        ] {
            #expect(DeletionSafetyPolicy.allowlistEntry(containing: other, home: home) == nil, "\(other)")
        }
    }

    /// `~/.gradle`, `~/Library` or `~/Movies` as a link: the move would take the
    /// folder behind it.
    @Test
    func everyEntryIsRefusedWhenItsFirstFolderIsALink() throws {
        let fm = FileManager.default
        let byFirstFolder = Dictionary(grouping: Self.entries(URL(fileURLWithPath: "/Users/someone"))) {
            String($0.split(separator: "/")[0])
        }
        #expect(byFirstFolder.count > 30)
        for (first, entries) in byFirstFolder {
            let (base, home, elsewhere) = try Self.makeHome()
            defer { try? fm.removeItem(at: base) }
            try fm.createSymbolicLink(at: home.appendingPathComponent(first), withDestinationURL: elsewhere)
            for relative in entries {
                // The folder a move would really take.
                let behind = Self.behind(relative, link: first, target: elsewhere)
                try Self.makeFolder(behind.appendingPathComponent("inner", isDirectory: true))
                for path in [relative, "\(relative)/inner", "\(relative)/inner/deeper"] {
                    #expect(Self.refuses(path, home: home), "\(path)")
                }
                #expect(fm.fileExists(atPath: home.appendingPathComponent("\(relative)/inner").path))
            }
        }
    }

    /// `~/.npm` or `DerivedData` as a link: its own row would only move the
    /// link, and a row inside it would take what is behind.
    @Test
    func everyEntryIsRefusedWhenItsOwnFolderIsALink() throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        for (index, relative) in Self.entries(home).enumerated() {
            let entry = home.appendingPathComponent(relative)
            let behind = elsewhere.appendingPathComponent("target-\(index)", isDirectory: true)
            try Self.makeFolder(behind.appendingPathComponent("inner", isDirectory: true))
            try Self.makeFolder(entry.deletingLastPathComponent())
            try fm.createSymbolicLink(at: entry, withDestinationURL: behind)
            for path in [relative, "\(relative)/inner", "\(relative)/inner/deeper"] {
                #expect(Self.refuses(path, home: home), "\(path)")
            }
            #expect(fm.fileExists(atPath: home.appendingPathComponent("\(relative)/inner").path))
        }
    }

    @Test(arguments: [
        (".gradle", ".gradle/caches"),
        (".m2", ".m2/repository"),
        ("Library/Developer", "Library/Developer/Xcode/DerivedData"),
        ("Library/Developer/Xcode", "Library/Developer/Xcode/Archives"),
        ("Library/Developer/CoreSimulator", "Library/Developer/CoreSimulator/Caches"),
        ("Library/Application Support/Adobe", "Library/Application Support/Adobe/Common/Media Cache"),
        ("Library/Containers/com.apple.mail/Data", "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
        ("Movies", "Movies/CacheClip"),
        ("opt", "opt/anaconda3/pkgs"),
        ("Library", "Library/Logs"),
    ])
    func aLinkedFolderOnTheWayRefusesTheEntry(link: String, entry: String) throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        try Self.makeFolder(Self.behind(entry, link: link, target: elsewhere).appendingPathComponent("inner", isDirectory: true))
        try Self.makeFolder(home.appendingPathComponent(link).deletingLastPathComponent())
        try Self.makeFolder(home.appendingPathComponent(".npm/_cacache", isDirectory: true))
        try fm.createSymbolicLink(at: home.appendingPathComponent(link), withDestinationURL: elsewhere)
        #expect(fm.fileExists(atPath: home.appendingPathComponent("\(entry)/inner").path))
        #expect(Self.refuses(entry, home: home))
        #expect(Self.refuses("\(entry)/inner", home: home))
        // An entry no link leads to keeps its rows.
        #expect(!Self.refuses(".npm", home: home))
        #expect(!Self.refuses(".npm/_cacache", home: home))
    }

    /// Rows inside an entry: the children of `~/Library/Caches` and
    /// `~/Library/Logs`, npm's folders, a JetBrains IDE's caches. A linked
    /// folder between the entry and the row sends the move elsewhere. A row
    /// whose own last part is the link moves as a link, as before.
    @Test(arguments: [
        ("Library/Caches/JetBrains", "Library/Caches/JetBrains/IntelliJIdea2026.2", "Library/Caches/com.example.app"),
        ("Library/Caches/JetBrains/IntelliJIdea2026.2", "Library/Caches/JetBrains/IntelliJIdea2026.2/caches", "Library/Caches/JetBrains/GoLand2026.2/caches"),
        ("Library/Logs/Example", "Library/Logs/Example/2026", "Library/Logs/DiagnosticReports"),
        (".npm/_cacache", ".npm/_cacache/index-v5", ".npm/_logs"),
    ])
    func aLinkedFolderBetweenAnEntryAndARowRefusesTheRow(link: String, row: String, sibling: String) throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        try Self.makeFolder(Self.behind(row, link: link, target: elsewhere))
        try Self.makeFolder(home.appendingPathComponent(link).deletingLastPathComponent())
        try Self.makeFolder(home.appendingPathComponent(sibling, isDirectory: true))
        try fm.createSymbolicLink(at: home.appendingPathComponent(link), withDestinationURL: elsewhere)
        #expect(fm.fileExists(atPath: home.appendingPathComponent(row).path))
        #expect(Self.refuses(row, home: home))
        #expect(Self.refuses("\(row)/inner", home: home))
        #expect(!Self.refuses(link, home: home))
        #expect(!Self.refuses(sibling, home: home))
        #expect(!Self.refuses((link as NSString).deletingLastPathComponent, home: home))
    }

    /// A home with no link offers what it did before, whether or not the
    /// folders are on disk.
    @Test(arguments: [true, false])
    func nothingIsRefusedWithoutALink(foldersExist: Bool) throws {
        let fm = FileManager.default
        let (base, home, _) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        let entries = Self.entries(home)
        #expect(entries.count > 80)
        for relative in entries {
            if foldersExist {
                try Self.makeFolder(home.appendingPathComponent("\(relative)/inner/deeper", isDirectory: true))
            }
            for path in [relative, "\(relative)/inner", "\(relative)/inner/deeper", "\(relative)/inner/deeper/file"] {
                #expect(!Self.refuses(path, home: home), "\(path)")
                #expect(!DeletionSafetyPolicy.allowlistLinkRefusesDeletion(
                    standardizedPath: home.appendingPathComponent(path).standardizedFileURL.path,
                    home: home.path,
                    reuseRecentRead: true
                ), "\(path)")
            }
        }
    }

    /// A link inside a folder goes to the Trash with it, as a link, so it
    /// refuses nothing.
    @Test
    func aLinkInsideTheFolderRefusesNothing() throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        try Self.makeFolder(home.appendingPathComponent(".gradle/caches/modules-2", isDirectory: true))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".gradle/caches/modules-2/link"), withDestinationURL: elsewhere)
        try Self.makeFolder(home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/Homebrew/wget--1.25"), withDestinationURL: elsewhere)
        for path in [
            ".gradle/caches", ".gradle/caches/modules-2", ".gradle/caches/modules-2/link",
            "Library/Caches/Homebrew", "Library/Caches/Homebrew/wget--1.25",
        ] {
            #expect(!Self.refuses(path, home: home), "\(path)")
        }
    }

    /// `simctl delete` removes a device by its UDID and Purge never moves the
    /// path, so a linked `Devices` folder keeps its device rows. Everything
    /// else there moves by path and is refused.
    @Test(arguments: ["Library/Developer", "Library/Developer/CoreSimulator", "Library/Developer/CoreSimulator/Devices"])
    func simulatorDevicesAreLeftAlone(link: String) throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        let devices = "Library/Developer/CoreSimulator/Devices"
        let udid = "5A1B2C3D-0000-4000-8000-00000000ABCD"
        try Self.makeFolder(Self.behind("\(devices)/\(udid)/data", link: link, target: elsewhere))
        try Self.makeFolder(home.appendingPathComponent(link).deletingLastPathComponent())
        try fm.createSymbolicLink(at: home.appendingPathComponent(link), withDestinationURL: elsewhere)
        #expect(fm.fileExists(atPath: home.appendingPathComponent("\(devices)/\(udid)/data").path))

        let byPath = [devices, "\(devices)/\(udid)/data", "\(devices)/unavailable/\(udid)", "\(devices)/device_set.plist", "\(devices)/not-a-udid"]
        #expect(!Self.refuses("\(devices)/\(udid)", home: home))
        #expect(FileDeleter.removesDirectly(home.appendingPathComponent("\(devices)/\(udid)"), simulatorRuntimePaths: []))
        for path in byPath {
            #expect(Self.refuses(path, home: home), "\(path)")
            #expect(!FileDeleter.removesDirectly(home.appendingPathComponent(path), simulatorRuntimePaths: []), "\(path)")
        }
        // A folder that only looks like a device, in another entry, moves by path.
        #expect(Self.refuses("Library/Developer/XCTestDevices/\(udid)", home: home) == (link == "Library/Developer"))
    }

    /// A folder on the way that can't be read is refused. One that is missing
    /// is not.
    @Test
    func aFolderThatCannotBeReadIsRefused() throws {
        let fm = FileManager.default
        let (base, home, _) = try Self.makeHome()
        let locked = home.appendingPathComponent(".m2", isDirectory: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? fm.removeItem(at: base)
        }
        try Self.makeFolder(locked.appendingPathComponent("repository/inner", isDirectory: true))
        #expect(!Self.refuses(".m2/repository", home: home))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        #expect(Self.refuses(".m2/repository", home: home))
        #expect(Self.refuses(".m2/repository/inner", home: home))
        #expect(!Self.refuses(".ivy2/cache", home: home))
    }

    /// The on-screen filter may answer from a read of the last few seconds. A
    /// move never does.
    @Test
    func onlyTheOnScreenFilterReusesARecentRead() throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        let tool = home.appendingPathComponent(".gradle", isDirectory: true)
        try Self.makeFolder(tool.appendingPathComponent("caches", isDirectory: true))
        try Self.makeFolder(elsewhere.appendingPathComponent("caches", isDirectory: true))
        let path = tool.appendingPathComponent("caches").standardizedFileURL.path
        func refuses(reuse: Bool) -> Bool {
            DeletionSafetyPolicy.allowlistLinkRefusesDeletion(standardizedPath: path, home: home.path, reuseRecentRead: reuse)
        }
        #expect(!refuses(reuse: true))
        try fm.removeItem(at: tool)
        try fm.createSymbolicLink(at: tool, withDestinationURL: elsewhere)
        #expect(refuses(reuse: false))
        #expect(!refuses(reuse: true))
        #expect(DeletionSafetyPolicy.linkReadLifetime <= 10)
    }

    /// The guard answers only for paths in an allowlist entry. Every other path
    /// is left to `evaluate` and the other guards, linked or not: a project on
    /// a linked drive still cleans (#190), and Gradle's own folder is refused
    /// elsewhere.
    @Test
    func otherPathsAreLeftAlone() throws {
        let fm = FileManager.default
        let (base, home, elsewhere) = try Self.makeHome()
        defer { try? fm.removeItem(at: base) }
        for link in [".gradle", "Developer", ".gem", ".local", "Library"] {
            try fm.createSymbolicLink(at: home.appendingPathComponent(link), withDestinationURL: elsewhere)
        }
        for path in [
            ".gradle", ".gradle/jdks", ".gradle/daemon/8.5", ".gradle/caches-old", "Developer", "Developer/app/node_modules",
            "Developer/app/.gradle", ".gem/ruby/3.3.0/cache", ".local/share/uv", "Library", "Library/Application Support/Code/Cache",
            "Library/Containers/com.example.app/Data/Library/Caches", "Library/CachesX/a", ".npmrc", "",
        ] {
            #expect(!Self.refuses(path, home: home), "\(path)")
        }
        #expect(!DeletionSafetyPolicy.allowlistLinkRefusesDeletion(elsewhere.appendingPathComponent(".gradle/caches"), home: home.path))
        #expect(!DeletionSafetyPolicy.allowlistLinkRefusesDeletion(URL(fileURLWithPath: "/Library/Caches/a"), home: home.path))
    }
}

// MARK: - The list itself

@Suite("Allowlist audit: one entry per place")
struct AllowlistEntryShapeTests {
    /// A second copy, or an entry inside another, changes nothing `evaluate`
    /// decides, so it only hides what the list really allows (#185).
    @Test
    func noEntryRepeatsOrSitsInsideAnother() {
        let entries = DeletionSafetyPolicy.whitelistedAbsolutePrefixes(home: AuditPaths.home)
        #expect(Set(entries).count == entries.count)
        for entry in entries {
            let outer = entries.filter { $0 != entry && PathContainment.isInside(entry, $0) }
            #expect(outer.isEmpty, "\(entry) is inside \(outer)")
        }
    }

    @Test
    func droppedEntriesAreStillAllowedThroughTheirParent() {
        for relative in [
            ".npm/_npx", ".npm/_logs", ".zcompdump", "Library/Caches/org.swift.swiftpm",
            "Library/Logs/DiagnosticReports", "Library/Caches/Zed", "Library/Caches/ms-playwright",
        ] {
            #expect(AuditPaths.evaluate(relative) == .allow, "\(relative)")
        }
    }
}
