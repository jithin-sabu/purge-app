import Foundation
import Testing
@testable import purge

private enum TestPaths {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func homeURL(_ components: String...) -> URL {
        homeURL(components)
    }

    static func homeURL(_ components: [String]) -> URL {
        components.reduce(home) { $0.appendingPathComponent($1) }
    }

    static func absoluteURL(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }
}

// MARK: - Group 1: Never-delete paths

@Suite("Never-delete paths always return .blockedNeverDelete")
struct NeverDeletePathsTests {
    @Test(arguments: [
        (["Library", "Keychains"], "Keychains root"),
        (["Library", "Keychains", "login.keychain-db"], "Keychains file"),
        (["Library", "Preferences"], "Preferences root"),
        (["Library", "Preferences", "com.apple.finder.plist"], "Preferences file"),
        (["Library", "Application Support"], "Application Support root"),
        (["Library", "Mail"], "Mail"),
        (["Documents"], "Documents"),
        (["Desktop"], "Desktop"),
        (["Downloads"], "Downloads"),
        (["Pictures"], "Pictures"),
        (["Music"], "Music"),
        (["Movies"], "Movies"),
        (["System"], "System"),
    ])
    func homeNeverDeletePaths(components: [String], label: String) {
        let url = TestPaths.homeURL(components)
        #expect(
            DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete,
            "\(label): \(url.path)"
        )
    }

    @Test(arguments: [
        ("/usr/bin", "usr bin"),
        ("/bin/bash", "bin bash"),
        ("/etc/hosts", "etc hosts"),
        ("/var/db", "var db"),
        ("/Library", "Library root"),
        ("/sbin", "sbin"),
    ])
    func systemNeverDeletePaths(path: String, label: String) {
        let url = TestPaths.absoluteURL(path)
        #expect(
            DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete,
            "\(label): \(path)"
        )
    }

    @Test
    func neverDeletePrefixEntries() {
        let home = TestPaths.home.standardizedFileURL.path
        for prefix in DeletionSafetyPolicy.neverDeletePrefixes(home: home) {
            let url = URL(fileURLWithPath: prefix)
            #expect(
                DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete,
                "prefix root: \(prefix)"
            )
            let child = URL(fileURLWithPath: prefix + "/nested-item")
            #expect(
                DeletionSafetyPolicy.evaluate(child) == .blockedNeverDelete,
                "prefix child: \(child.path)"
            )
        }
    }

    @Test
    func neverDeleteExactPathEntries() {
        let home = TestPaths.home.standardizedFileURL.path
        for exact in DeletionSafetyPolicy.neverDeleteExactPaths(home: home) {
            let url = URL(fileURLWithPath: exact)
            #expect(
                DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete,
                "exact path: \(exact)"
            )
        }
    }
}

// MARK: - Group 2: Protected system caches

@Suite("Protected system caches return .blockedNeverDelete")
struct ProtectedSystemCachesTests {
    @Test
    func cloudKitCache() {
        let url = TestPaths.homeURL("Library", "Caches", "CloudKit")
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete)
    }

    @Test
    func familyCircleCache() {
        let url = TestPaths.homeURL("Library", "Caches", "FamilyCircle")
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete)
    }

    @Test
    func safariContainerCache() {
        let url = TestPaths.homeURL(
            "Library", "Containers", "com.apple.Safari", "Data", "Library", "Caches"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete)
    }

    @Test(arguments: [
        "com.apple.Home",
        "com.apple.homed",
        "com.apple.HomeKit",
    ])
    func homeKitContainerCaches(bundleID: String) {
        let url = TestPaths.homeURL(
            "Library", "Containers", bundleID, "Data", "Library", "Caches"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete)
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(url))
    }

    @Test
    func diagnosticReportsForNewHardwareIsNeverOffered() {
        // macOS surfaces this sibling of DiagnosticReports inside the Application Logs
        // scan but refuses to delete it, so it must never be offered.
        let folder = TestPaths.homeURL("Library", "Logs", "DiagnosticReportsForNewHardware")
        #expect(DeletionSafetyPolicy.evaluate(folder) == .blockedNeverDelete)
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(folder))

        let child = TestPaths.homeURL(
            "Library", "Logs", "DiagnosticReportsForNewHardware", "report.diag"
        )
        #expect(DeletionSafetyPolicy.evaluate(child) == .blockedNeverDelete)
    }

    @Test
    func diagnosticReportsCrashLogsStillOffered() {
        // The adjacent DiagnosticReports folder remains cleanable as Crash Reports.
        let url = TestPaths.homeURL("Library", "Logs", "DiagnosticReports")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }
}

// MARK: - Group 3: Whitelisted absolute prefixes

@Suite("Whitelisted paths return .allow")
struct WhitelistedAbsolutePrefixesTests {
    @Test
    func safariFlatCache() {
        let url = TestPaths.homeURL("Library", "Caches", "com.apple.Safari")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func xcodeDerivedData() {
        let url = TestPaths.homeURL("Library", "Developer", "Xcode", "DerivedData")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func xcodeDerivedDataBuildSubfolder() {
        let url = TestPaths.homeURL(
            "Library", "Developer", "Xcode", "DerivedData", "MyApp-abcxyz", "Build"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func npmCache() {
        let url = TestPaths.homeURL(".npm", "_cacache")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func gradleCaches() {
        let url = TestPaths.homeURL(".gradle", "caches")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func diagnosticReports() {
        let url = TestPaths.homeURL("Library", "Logs", "DiagnosticReports")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func slackCache() {
        let url = TestPaths.homeURL("Library", "Application Support", "Slack", "Cache")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func cursorCache() {
        let url = TestPaths.homeURL("Library", "Application Support", "Cursor", "Cache")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }
}

// MARK: - Group 3b: Adobe media caches under Application Support

@Suite("Adobe media caches are allowed only at their default locations")
struct AdobeMediaCacheTests {
    @Test
    func mediaCacheFilesRootIsAllowed() {
        let url = TestPaths.homeURL(
            "Library", "Application Support", "Adobe", "Common", "Media Cache Files"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func mediaCacheDatabaseRootIsAllowed() {
        let url = TestPaths.homeURL(
            "Library", "Application Support", "Adobe", "Common", "Media Cache"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func mediaCacheFilesDescendantIsAllowed() {
        let url = TestPaths.homeURL(
            "Library", "Application Support", "Adobe", "Common", "Media Cache Files",
            "1a2b3c.mcdb"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func siblingWithMediaCachePrefixIsNotAllowed() {
        // "Media Cache" must not act as a prefix for an unrelated sibling folder.
        let url = TestPaths.homeURL(
            "Library", "Application Support", "Adobe", "Common", "Media Cache Extras"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNotWhitelisted)
    }

    @Test
    func projectLocalMediaCacheIsNotAllowed() {
        // A media cache the user parked next to a project must never be offered —
        // only the default Application Support locations are whitelisted.
        let url = TestPaths.homeURL(
            "Documents", "MyEdit", "Adobe", "Common", "Media Cache Files"
        )
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNotWhitelisted)
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(url))
    }

    @Test
    func discoveryTargetsOnlyDefaultAppSupportLocations() {
        let appSupportAdobe = TestPaths.homeURL(
            "Library", "Application Support", "Adobe", "Common"
        ).standardizedFileURL.path
        for entry in CacheDiscoveryPaths.adobeMediaCacheEntries {
            #expect(entry.relative.hasPrefix("Adobe/Common/"), "unexpected root: \(entry.relative)")
        }
        // Every URL the discovery would surface must sit under the default location
        // and pass the results-boundary guard.
        for surfaced in CacheDiscoveryPaths.adobeMediaCacheURLs(home: TestPaths.home) {
            #expect(surfaced.url.path.hasPrefix(appSupportAdobe + "/"))
            #expect(DeletionSafetyPolicy.isOfferedForCleanup(surfaced.url))
        }
    }
}

// MARK: - Group 3c: Telegram media cache in the Group Container

@Suite("Telegram media cache is allowed only at .../account-*/postbox/media")
struct TelegramMediaCacheTests {
    private static let container = [
        "Library", "Group Containers", "6N38VWS5BX.ru.keepcoder.Telegram"
    ]

    private static func mediaURL(channel: String, account: String, extra: String...) -> URL {
        TestPaths.homeURL(container + [channel, account, "postbox", "media"] + extra)
    }

    @Test
    func mediaDirectoryItselfIsAllowed() {
        let url = Self.mediaURL(channel: "stable", account: "account-1")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func mediaDescendantIsAllowed() {
        let url = Self.mediaURL(channel: "appstore", account: "account-42", extra: "0", "cached.jpg")
        #expect(DeletionSafetyPolicy.evaluate(url) == .allow)
    }

    @Test
    func postboxDatabaseIsNeverAllowed() {
        // The account database lives directly in `postbox`; nothing shallower
        // than `postbox/media` may ever be authorized for deletion.
        let postbox = TestPaths.homeURL(Self.container + ["stable", "account-1", "postbox"])
        #expect(DeletionSafetyPolicy.evaluate(postbox) != .allow)

        let db = TestPaths.homeURL(Self.container + ["stable", "account-1", "postbox", "db"])
        #expect(DeletionSafetyPolicy.evaluate(db) != .allow)
    }

    @Test
    func accountAndContainerRootsAreNeverAllowed() {
        let account = TestPaths.homeURL(Self.container + ["stable", "account-1"])
        #expect(DeletionSafetyPolicy.evaluate(account) != .allow)

        let channel = TestPaths.homeURL(Self.container + ["stable"])
        #expect(DeletionSafetyPolicy.evaluate(channel) != .allow)

        let root = TestPaths.homeURL(Self.container)
        #expect(DeletionSafetyPolicy.evaluate(root) != .allow)
    }

    @Test
    func siblingOfMediaIsNeverAllowed() {
        // A "media"-prefixed sibling under postbox must not slip through.
        let url = TestPaths.homeURL(
            Self.container + ["stable", "account-1", "postbox", "media-old"]
        )
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
    }

    @Test
    func nonAccountFolderIsNeverAllowed() {
        // The second segment must be `account-*`; a stray folder cannot match.
        let url = TestPaths.homeURL(
            Self.container + ["stable", "notanaccount", "postbox", "media"]
        )
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow)
    }

    @Test
    func onlyTheMediaDirectoryIsClearedContentsOnly() {
        let media = Self.mediaURL(channel: "stable", account: "account-1")
        #expect(DeletionSafetyPolicy.shouldDeleteContentsOnly(media))

        // A descendant is deleted outright (as normal contents), not contents-only.
        let child = Self.mediaURL(channel: "stable", account: "account-1", extra: "0")
        #expect(!DeletionSafetyPolicy.shouldDeleteContentsOnly(child))

        // The postbox directory is never a contents-only target either.
        let postbox = TestPaths.homeURL(Self.container + ["stable", "account-1", "postbox"])
        #expect(!DeletionSafetyPolicy.shouldDeleteContentsOnly(postbox))
    }

    @Test
    func discoverySurfacesOnlyPostboxMediaThatPassesTheGuard() {
        // Whatever discovery surfaces on this machine (possibly nothing) must
        // terminate at `postbox/media` and pass the results-boundary guard.
        for surfaced in CacheDiscoveryPaths.telegramMediaCacheURLs(home: TestPaths.home) {
            #expect(surfaced.url.path.hasSuffix("/postbox/media"))
            #expect(surfaced.key == "Telegram Media Cache")
            #expect(DeletionSafetyPolicy.isOfferedForCleanup(surfaced.url))
        }
    }
}

// MARK: - Group 4: Whitelisted folder names inside home

@Suite("Whitelisted folder names inside home return .allow")
struct WhitelistedFolderNamesTests {
    @Test(arguments: [
        (["Developer", "myproject", "node_modules"], "node_modules"),
        (["Developer", "myproject", "target"], "target"),
        (["Developer", "myproject", "Pods"], "Pods"),
        (["Developer", "myproject", ".gradle"], ".gradle"),
        // Projects kept under Documents/Desktop/Downloads: the folder root is a hard
        // never-delete, but nested whitelisted caches must remain cleanable.
        (["Documents", "myproject", "node_modules"], "node_modules under Documents"),
        (["Desktop", "myproject", "target"], "target under Desktop"),
        (["Downloads", "myproject", ".venv"], ".venv under Downloads"),
    ])
    func whitelistedArtifactFolders(components: [String], label: String) {
        let url = TestPaths.homeURL(components)
        #expect(
            DeletionSafetyPolicy.evaluate(url) == .allow,
            "\(label): \(url.path)"
        )
    }
}

// MARK: - Group 5: Unlisted paths

@Suite("Unlisted paths return .blockedNotWhitelisted or .blockedNeverDelete")
struct UnlistedPathsTests {
    @Test
    func desktopFileIsNotOfferedForCleanup() {
        // The user's own files under Desktop are not whitelisted caches, so they are
        // skipped for safety (never offered for cleanup), but the folder root itself
        // remains a hard never-delete so nested whitelisted caches can pass through.
        let url = TestPaths.homeURL("Desktop", "important-file.txt")
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNotWhitelisted)
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(url))
    }

    @Test
    func documentsProjectIsNotOfferedForCleanup() {
        let url = TestPaths.homeURL("Documents", "my-project")
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNotWhitelisted)
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(url))
    }

    @Test
    func sourceCodeFolderIsNotWhitelisted() {
        let url = TestPaths.homeURL("Developer", "myproject", "src")
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNotWhitelisted)
    }

    @Test
    func moviesFileIsNeverDelete() {
        let url = TestPaths.homeURL("Movies", "myvideo.mp4")
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete)
    }

    @Test
    func appSupportRootIsNotWhitelisted() {
        let url = TestPaths.homeURL("Library", "Application Support", "MyApp")
        #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNotWhitelisted)
    }
}

// MARK: - Group 6: Admin-gated system paths

@Suite("requiresAdminPrivileges gates system paths")
struct AdminGatedSystemPathsTests {
    @Test(arguments: [
        "/Library/Caches",
        "/Library/Caches/anything",
        "/Library/Updates",
        "/private/var/log",
        "/private/var/log/system.log",
        "/Library/Logs/DiagnosticReports",
    ])
    func requiresAdmin(path: String) {
        let url = TestPaths.absoluteURL(path)
        #expect(DeletionSafetyPolicy.requiresAdminPrivileges(for: url))
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(url))
    }
}

// MARK: - Group 7: Contents-only deletion

@Suite("shouldDeleteContentsOnly fires for the right paths")
struct ContentsOnlyDeletionTests {
    @Test
    func libraryLogs() {
        let url = TestPaths.homeURL("Library", "Logs")
        #expect(DeletionSafetyPolicy.shouldDeleteContentsOnly(url))
    }

    @Test
    func libraryLogsDiagnosticReports() {
        let url = TestPaths.homeURL("Library", "Logs", "DiagnosticReports")
        #expect(DeletionSafetyPolicy.shouldDeleteContentsOnly(url))
    }

    @Test
    func libraryCaches() {
        let url = TestPaths.homeURL("Library", "Caches")
        #expect(DeletionSafetyPolicy.shouldDeleteContentsOnly(url))
    }

    @Test
    func derivedDataIsNotContentsOnly() {
        let url = TestPaths.homeURL("Library", "Developer", "Xcode", "DerivedData")
        #expect(!DeletionSafetyPolicy.shouldDeleteContentsOnly(url))
    }

    @Test
    func npmCacheIsNotContentsOnly() {
        let url = TestPaths.homeURL(".npm", "_cacache")
        #expect(!DeletionSafetyPolicy.shouldDeleteContentsOnly(url))
    }
}

// MARK: - Group 8: Music and Movies are fully protected

@Suite("Music and Movies are protected at every depth")
struct MediaFolderProtectionTests {
    @Test(arguments: [
        (["Music"], "Music root"),
        (["Movies"], "Movies root"),
        (["Music", "song.mp3"], "Music file"),
        (["Movies", "clip.mov"], "Movies file"),
        (["Music", "node_modules"], "Music whitelisted-name folder"),
        (["Movies", "build"], "Movies whitelisted-name folder"),
        (["Music", "project", "target"], "Music nested whitelisted-name folder"),
    ])
    func mediaPathsAreNeverDelete(components: [String], label: String) {
        let url = TestPaths.homeURL(components)
        #expect(
            DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete,
            "\(label): \(url.path)"
        )
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(url))
    }
}
