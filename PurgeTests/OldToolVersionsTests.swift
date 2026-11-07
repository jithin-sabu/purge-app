import Foundation
import Testing
@testable import Purge

/// Old tool versions kept next to the one in use (#324). Each kind is pinned by
/// what is offered, by what next to it must stay, and by the delete-time gate
/// reading the disk again. Every fixture is a throwaway home folder.
private enum OldVersions {
    typealias Policy = OldToolVersionScanPolicy

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-324-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    /// Folders and small files under `home`.
    static func lay(_ home: URL, folders: [String] = [], files: [String] = []) throws {
        let fm = FileManager.default
        for folder in folders {
            try fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in files {
            let url = home.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    static func age(_ home: URL, _ relative: String, by seconds: TimeInterval, now: Date = Date()) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-seconds)],
            ofItemAtPath: home.appendingPathComponent(relative).path
        )
    }

    static func link(_ home: URL, _ relative: String, to destination: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    /// No AVD home and no emulator, unless a test says otherwise.
    static func android(avdHomes: [String] = [], emulator: Bool = false) -> Policy.AndroidContext {
        Policy.AndroidContext(avdHomes: avdHomes, emulatorIsRunning: { emulator })
    }

    /// Whether the delete-time gate lets `relative` go.
    static func offered(
        _ home: URL,
        _ relative: String,
        now: Date = Date(),
        android: Policy.AndroidContext = android()
    ) -> Bool {
        !Policy.refusesDeletion(
            home.appendingPathComponent(relative),
            home: home.path,
            now: now,
            android: android
        )
    }

    /// The paths each row lists, relative to `home`, by label.
    static func rows(
        _ home: URL,
        now: Date = Date(),
        android: Policy.AndroidContext = android()
    ) -> [String: [String]] {
        let prefix = home.path + "/"
        var result: [String: [String]] = [:]
        for row in Policy.definitions(home: home, now: now, android: android) {
            result[row.label] = row.paths.map { String($0.standardizedFileURL.path.dropFirst(prefix.count)) }
        }
        return result
    }

    static let day: TimeInterval = 24 * 60 * 60
    static let cursorCLI = DeletionSafetyPolicy.cursorAgentWorkerCLI
    static let cursorVersions = "\(cursorCLI)/.local/share/cursor-agent/versions"
}

// MARK: - Shape

@Suite("Old tool versions (#324): shapes")
struct OldToolVersionShapeTests {
    typealias Policy = OldToolVersionScanPolicy
    private let home = "/Users/someone"

    @Test(arguments: [
        ("\(OldVersions.cursorVersions)/.tmp-2026.09.15-d2fe57e-31383-1789734822453", Policy.Kind.cursorInstallLeftover),
        (".local/share/cursor-agent/versions/.tmp-2026.10.01-abc", .cursorInstallLeftover),
        ("\(OldVersions.cursorCLI)/cursor-agent-2026.09.15-d2fe57e-31383-1789734822453.tar.gz", .cursorInstallLeftover),
        (".claude/downloads/claude-2.1.44-darwin-arm64", .claudeCodeDownload),
        ("Library/Android/sdk/ndk/27.0.12077973", .androidNDK),
        ("Library/Android/sdk/system-images/android-36/google_apis/arm64-v8a", .androidSystemImage),
        ("Library/Application Support/Figma/DesktopProfile/v42", .figmaProfile),
    ])
    func acceptsEachShape(relative: String, kind: Policy.Kind) {
        #expect(Policy.kind(of: "\(home)/\(relative)", home: home) == kind)
    }

    @Test(arguments: [
        // The folders that hold them, and anything inside one.
        OldVersions.cursorVersions,
        "\(OldVersions.cursorVersions)/.tmp-",
        "\(OldVersions.cursorVersions)/.tmp-2026.09.15-d2fe57e/cursor-agent",
        "\(OldVersions.cursorVersions)/2026.10.01-e373342",
        "\(OldVersions.cursorCLI)/.local",
        "\(OldVersions.cursorCLI)/cursor-agent-.tar.gz",
        "\(OldVersions.cursorCLI)/notes.tar.gz",
        ".claude/downloads",
        ".claude/downloads/claude",
        ".claude/downloads/claude-latest-darwin-arm64",
        ".claude/downloads/claude-2.1.44",
        ".claude/downloads/claude-2.1.44-darwin arm64",
        ".claude/downloads/sub/claude-2.1.44-darwin-arm64",
        ".claude/settings.json",
        "Library/Android/sdk/ndk",
        "Library/Android/sdk/ndk/27",
        "Library/Android/sdk/ndk/27.0.12077973/build",
        "Library/Android/sdk/ndk/.installer",
        "Library/Android/sdk/platforms/android-36",
        "Library/Android/sdk/system-images/android-36",
        "Library/Android/sdk/system-images/android-36/google_apis",
        "Library/Android/sdk/system-images/android-36/google_apis/arm64-v8a/system.img",
        "Library/Android/sdk/system-images/android-36/.temp/arm64-v8a",
        "Library/Application Support/Figma/DesktopProfile",
        "Library/Application Support/Figma/DesktopProfile/v",
        "Library/Application Support/Figma/DesktopProfile/v42/Cookies",
        "Library/Application Support/Figma/DesktopProfile/beta",
        "Library/Application Support/Figma/DesktopBeta/Profile/v42",
        ".android/avd/Pixel.avd",
    ])
    func rejectsEverythingElse(relative: String) {
        #expect(Policy.kind(of: "\(home)/\(relative)", home: home) == nil)
    }

    @Test
    func ndkLabelsCarryTheirVersion() {
        #expect(Policy.ndkVersion(inLabel: "Android NDK 27.0.12077973") == "27.0.12077973")
        #expect(Policy.ndkVersion(inLabel: "Android NDK") == nil)
        #expect(Policy.ndkVersion(inLabel: "Android NDK latest") == nil)
        #expect(Policy.ndkVersion(inLabel: "Old Figma Profiles") == nil)
    }

    /// `evaluate` allows the shapes, so the gate in `isOfferedForCleanup` is what
    /// decides. Neither lets through a path next to them.
    @Test
    func evaluateAllowsOnlyTheShapes() {
        let home = DeletionSafetyPolicy.cachedHomePath
        func decision(_ relative: String) -> DeletionSafetyDecision {
            DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "\(home)/\(relative)"))
        }
        #expect(decision(".claude/downloads/claude-2.1.44-darwin-arm64") == .allow)
        #expect(decision("Library/Android/sdk/ndk/27.0.12077973") == .allow)
        #expect(decision("Library/Application Support/Figma/DesktopProfile/v42") == .allow)
        #expect(decision(".claude/downloads") != .allow)
        #expect(decision("Library/Android/sdk/ndk") != .allow)
        #expect(decision("Library/Android/sdk") != .allow)
        #expect(decision("Library/Application Support/Figma/DesktopProfile") != .allow)
    }

    /// Paths that don't exist pass `evaluate` by shape, and `isOfferedForCleanup`,
    /// which `FileDeleter` asks before every move, still refuses them.
    @Test
    func missingPathsAreNeverOffered() {
        let home = DeletionSafetyPolicy.cachedHomePath
        for relative in [
            ".claude/downloads/claude-0.0.1-purge-test-324",
            "Library/Android/sdk/ndk/0.0.324",
            "Library/Android/sdk/system-images/purge-test-324/none/none",
            "Library/Application Support/Figma/DesktopProfile/v0",
            "\(OldVersions.cursorVersions)/.tmp-purge-test-324",
        ] {
            #expect(!DeletionSafetyPolicy.isOfferedForCleanup(URL(fileURLWithPath: "\(home)/\(relative)")), "\(relative)")
        }
    }

    /// The #323 version rule took any name in a versions folder, hidden ones too,
    /// so `evaluate` allowed `.tmp-*` with no age check. Hidden names are never a
    /// version now.
    @Test
    func versionRuleSkipsHiddenNames() {
        let home = "/Users/someone"
        let root = "\(home)/.local/share/cursor-agent/versions"
        #expect(DeletionSafetyPolicy.cliVersion(containing: "\(root)/2026.10.01-e373342", home: home) != nil)
        #expect(DeletionSafetyPolicy.cliVersion(containing: "\(root)/.tmp-2026.10.01-abc", home: home) == nil)
        #expect(DeletionSafetyPolicy.cliVersion(containing: "\(root)/.DS_Store", home: home) == nil)
    }
}

// MARK: - Cursor and Claude Code

@Suite("Old tool versions (#324): Cursor and Claude Code")
struct OldToolVersionDownloadTests {
    @Test
    func cursorLeftoversWaitADay() throws {
        let home = try OldVersions.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let versions = OldVersions.cursorVersions
        let old = "\(versions)/.tmp-2026.09.15-d2fe57e-1"
        let busy = "\(versions)/.tmp-2026.10.22-27dcf5f-2"
        let fresh = "\(versions)/.tmp-2026.10.22-27dcf5f-3"
        let oldTar = "\(OldVersions.cursorCLI)/cursor-agent-2026.09.15-d2fe57e-1.tar.gz"
        let newTar = "\(OldVersions.cursorCLI)/cursor-agent-2026.10.22-27dcf5f-2.tar.gz"
        try OldVersions.lay(
            home,
            folders: [fresh, "\(versions)/2026.10.01-e373342"],
            files: ["\(old)/cursor-agent", "\(busy)/old-file", "\(busy)/new-file", oldTar, newTar]
        )
        for path in [old, "\(old)/cursor-agent", busy, "\(busy)/old-file", oldTar] {
            try OldVersions.age(home, path, by: 2 * OldVersions.day)
        }
        try OldVersions.age(home, newTar, by: 60 * 60)

        #expect(OldVersions.offered(home, old))
        #expect(OldVersions.offered(home, oldTar))
        // A file changed an hour ago inside keeps the folder.
        #expect(!OldVersions.offered(home, busy))
        #expect(!OldVersions.offered(home, fresh))
        #expect(!OldVersions.offered(home, newTar))

        let rows = OldVersions.rows(home)
        #expect(rows[OldToolVersionScanPolicy.cursorLeftoverLabel]?.sorted() == [oldTar, old].sorted())
    }

    @Test
    func cursorLeftoversMustBeTheRightType() throws {
        let home = try OldVersions.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileNamedLikeFolder = "\(OldVersions.cursorVersions)/.tmp-a"
        let folderNamedLikeTar = "\(OldVersions.cursorCLI)/cursor-agent-a.tar.gz"
        let linkedTmp = "\(OldVersions.cursorVersions)/.tmp-b"
        try OldVersions.lay(home, folders: [folderNamedLikeTar, "Documents/work"], files: [fileNamedLikeFolder])
        try OldVersions.link(home, linkedTmp, to: home.appendingPathComponent("Documents/work").path)
        for path in [fileNamedLikeFolder, folderNamedLikeTar, "Documents/work"] {
            try OldVersions.age(home, path, by: 2 * OldVersions.day)
        }
        #expect(!OldVersions.offered(home, fileNamedLikeFolder))
        #expect(!OldVersions.offered(home, folderNamedLikeTar))
        #expect(!OldVersions.offered(home, linkedTmp))
        #expect(OldVersions.rows(home)[OldToolVersionScanPolicy.cursorLeftoverLabel] == nil)
    }

    private func claudeHome(link: String?) throws -> URL {
        let home = try OldVersions.makeHome()
        try OldVersions.lay(home, files: [
            ".local/share/claude/versions/2.1.302",
            ".claude/downloads/claude-2.1.44-darwin-arm64",
            ".claude/downloads/claude-2.1.76-darwin-arm64",
            ".claude/downloads/claude-2.1.302-darwin-arm64",
            ".claude/downloads/claude-2.1.400-darwin-arm64",
        ])
        for name in ["2.1.44", "2.1.76", "2.1.302", "2.1.400"] {
            try OldVersions.age(home, ".claude/downloads/claude-\(name)-darwin-arm64", by: 30 * OldVersions.day)
        }
        if let link { try OldVersions.link(home, ".local/bin/claude", to: link) }
        return home
    }

    @Test
    func claudeDownloadsBelowTheVersionInUse() throws {
        let home = try claudeHome(link: "../share/claude/versions/2.1.302")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(OldVersions.offered(home, ".claude/downloads/claude-2.1.44-darwin-arm64"))
        #expect(OldVersions.offered(home, ".claude/downloads/claude-2.1.76-darwin-arm64"))
        // The version in use and a newer one an update may be about to install.
        #expect(!OldVersions.offered(home, ".claude/downloads/claude-2.1.302-darwin-arm64"))
        #expect(!OldVersions.offered(home, ".claude/downloads/claude-2.1.400-darwin-arm64"))
        #expect(OldVersions.rows(home)[OldToolVersionScanPolicy.claudeDownloadLabel] == [
            ".claude/downloads/claude-2.1.44-darwin-arm64",
            ".claude/downloads/claude-2.1.76-darwin-arm64",
        ])
    }

    @Test
    func claudeDownloadsNeedTheLink() throws {
        let noLink = try claudeHome(link: nil)
        defer { try? FileManager.default.removeItem(at: noLink) }
        #expect(!OldVersions.offered(noLink, ".claude/downloads/claude-2.1.44-darwin-arm64"))
        #expect(OldVersions.rows(noLink)[OldToolVersionScanPolicy.claudeDownloadLabel] == nil)

        // A command pointing anywhere but the versions folder says nothing.
        let elsewhere = try claudeHome(link: "/opt/homebrew/bin/claude-3.0.0")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        #expect(!OldVersions.offered(elsewhere, ".claude/downloads/claude-2.1.44-darwin-arm64"))
    }

    @Test
    func claudeDownloadsMustBeOldFiles() throws {
        let home = try claudeHome(link: "../share/claude/versions/2.1.302")
        defer { try? FileManager.default.removeItem(at: home) }
        try OldVersions.lay(home, folders: [".claude/downloads/claude-2.1.10-darwin-arm64"],
                            files: [".claude/downloads/claude-2.1.11-darwin-arm64", "Documents/notes.txt"])
        try OldVersions.age(home, ".claude/downloads/claude-2.1.10-darwin-arm64", by: 30 * OldVersions.day)
        try OldVersions.link(home, ".claude/downloads/claude-2.1.12-darwin-arm64",
                             to: home.appendingPathComponent("Documents/notes.txt").path)
        #expect(!OldVersions.offered(home, ".claude/downloads/claude-2.1.10-darwin-arm64"))
        // Written just now.
        #expect(!OldVersions.offered(home, ".claude/downloads/claude-2.1.11-darwin-arm64"))
        #expect(!OldVersions.offered(home, ".claude/downloads/claude-2.1.12-darwin-arm64"))
    }
}

// MARK: - Android

@Suite("Old tool versions (#324): Android")
struct OldToolVersionAndroidTests {
    private func ndk(_ home: URL, complete: [String], partial: [String]) throws {
        try OldVersions.lay(
            home,
            files: complete.map { "Library/Android/sdk/ndk/\($0)/source.properties" }
                + partial.map { "Library/Android/sdk/ndk/\($0)/.installer/state" }
        )
    }

    @Test
    func ndkKeepsTheNewestFinishedInstall() throws {
        let home = try OldVersions.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try ndk(home, complete: ["25.1.8937393", "27.0.12077973", "28.0.12433566", "28.0.13004108"],
                partial: ["25.2.9519653", "29.0.1"])
        let root = "Library/Android/sdk/ndk"
        #expect(OldVersions.offered(home, "\(root)/25.1.8937393"))
        #expect(OldVersions.offered(home, "\(root)/28.0.12433566"))
        #expect(!OldVersions.offered(home, "\(root)/28.0.13004108"))
        // Unfinished installs, one older and one newer than the newest finished.
        #expect(!OldVersions.offered(home, "\(root)/25.2.9519653"))
        #expect(!OldVersions.offered(home, "\(root)/29.0.1"))

        let rows = OldVersions.rows(home)
        #expect(rows["Android NDK 25.1.8937393"] == ["\(root)/25.1.8937393"])
        #expect(rows["Android NDK 27.0.12077973"] == ["\(root)/27.0.12077973"])
        #expect(rows["Android NDK 28.0.12433566"] == ["\(root)/28.0.12433566"])
        #expect(rows["Android NDK 28.0.13004108"] == nil)
        #expect(rows.keys.filter { $0.hasPrefix("Android NDK") }.count == 3)
    }

    @Test
    func ndkAloneIsKept() throws {
        let home = try OldVersions.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try ndk(home, complete: ["27.0.12077973"], partial: [])
        #expect(!OldVersions.offered(home, "Library/Android/sdk/ndk/27.0.12077973"))
    }

    @Test
    func ndkInALinkedSDKIsNotOffered() throws {
        let home = try OldVersions.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try ndk(home, complete: ["25.1.8937393", "27.0.12077973"], partial: [])
        try OldVersions.lay(home, folders: ["Documents"])
        try FileManager.default.moveItem(
            at: home.appendingPathComponent("Library/Android/sdk"),
            to: home.appendingPathComponent("Documents/sdk")
        )
        try OldVersions.link(home, "Library/Android/sdk", to: home.appendingPathComponent("Documents/sdk").path)
        #expect(!OldVersions.offered(home, "Library/Android/sdk/ndk/25.1.8937393"))
    }

    private let images = "Library/Android/sdk/system-images"
    private var playStore: String { "\(images)/android-36/google_apis_playstore/arm64-v8a" }
    private var apis: String { "\(images)/android-36/google_apis/arm64-v8a" }
    private var beta: String { "\(images)/android-37.0/google_apis_playstore_ps16k/arm64-v8a" }

    private func imagesHome() throws -> URL {
        let home = try OldVersions.makeHome()
        try OldVersions.lay(home, files: [playStore, apis, beta].map { "\($0)/system.img" })
        return home
    }

    @Test
    func imagesWithNoAVDAreOffered() throws {
        let home = try imagesHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = OldVersions.android(avdHomes: [home.appendingPathComponent(".android/avd").path])
        for image in [playStore, apis, beta] {
            #expect(OldVersions.offered(home, image, android: context), "\(image)")
        }
        #expect(OldVersions.rows(home, android: context)[OldToolVersionScanPolicy.systemImagesLabel]?.sorted()
            == [playStore, apis, beta].sorted())
    }

    @Test
    func imagesAnAVDNamesAreKept() throws {
        let home = try imagesHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // One AVD in the AVD home, one elsewhere that a `.ini` points at.
        try OldVersions.lay(home, files: [".android/avd/Pixel.avd/config.ini", "Emulators/Tablet.avd/config.ini",
                                          ".android/avd/Tablet.ini"])
        try "image.sysdir.1=system-images/android-36/google_apis/arm64-v8a/\nhw.ramSize=2048\n"
            .write(to: home.appendingPathComponent(".android/avd/Pixel.avd/config.ini"), atomically: true, encoding: .utf8)
        let absolute = home.appendingPathComponent(beta).path + "/"
        try "image.sysdir.1 = \(absolute)\n"
            .write(to: home.appendingPathComponent("Emulators/Tablet.avd/config.ini"), atomically: true, encoding: .utf8)
        try "avd.ini.encoding=UTF-8\npath=\(home.appendingPathComponent("Emulators/Tablet.avd").path)\n"
            .write(to: home.appendingPathComponent(".android/avd/Tablet.ini"), atomically: true, encoding: .utf8)

        let context = OldVersions.android(avdHomes: [home.appendingPathComponent(".android/avd").path])
        #expect(!OldVersions.offered(home, apis, android: context))
        #expect(!OldVersions.offered(home, beta, android: context))
        #expect(OldVersions.offered(home, playStore, android: context))
        #expect(OldVersions.rows(home, android: context)[OldToolVersionScanPolicy.systemImagesLabel] == [playStore])
    }

    @Test
    func anAVDThatCantBeReadKeepsEveryImage() throws {
        let home = try imagesHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let avdHome = home.appendingPathComponent(".android/avd").path
        let context = OldVersions.android(avdHomes: [avdHome])

        // No config.ini.
        try OldVersions.lay(home, folders: [".android/avd/Broken.avd"])
        #expect(!OldVersions.offered(home, playStore, android: context))

        // A config.ini that names no image.
        try OldVersions.lay(home, files: [".android/avd/Broken.avd/config.ini"])
        #expect(!OldVersions.offered(home, playStore, android: context))
        #expect(OldVersions.rows(home, android: context)[OldToolVersionScanPolicy.systemImagesLabel] == nil)
    }

    @Test
    func aStaleIniWithNoAVDIsIgnored() throws {
        let home = try imagesHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try OldVersions.lay(home, files: [".android/avd/Gone.ini"])
        try "path=\(home.appendingPathComponent(".android/avd/Gone.avd").path)\n"
            .write(to: home.appendingPathComponent(".android/avd/Gone.ini"), atomically: true, encoding: .utf8)
        let context = OldVersions.android(avdHomes: [home.appendingPathComponent(".android/avd").path])
        #expect(OldVersions.offered(home, playStore, android: context))
    }

    @Test
    func aRunningEmulatorKeepsEveryImage() throws {
        let home = try imagesHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = OldVersions.android(emulator: true)
        #expect(!OldVersions.offered(home, playStore, android: context))
        #expect(OldVersions.rows(home, android: context)[OldToolVersionScanPolicy.systemImagesLabel] == nil)
    }

    @Test
    func avdHomesComeFromTheAndroidVariables() {
        let homes = OldToolVersionScanPolicy.defaultAVDHomes(home: "/Users/someone", environment: [
            "ANDROID_AVD_HOME": "/Volumes/Fast/avd",
            "ANDROID_EMULATOR_HOME": "/Users/someone/.android",
            "ANDROID_USER_HOME": "relative/path",
            "ANDROID_SDK_HOME": "/Users/someone/sdkhome",
        ])
        #expect(homes == [
            "/Users/someone/.android/avd",
            "/Volumes/Fast/avd",
            "/Users/someone/sdkhome/.android/avd",
        ])
    }
}

// MARK: - Figma

@Suite("Old tool versions (#324): Figma profiles")
struct OldToolVersionFigmaTests {
    private let profiles = "Library/Application Support/Figma/DesktopProfile"

    private func figmaHome(markerOn: [Int], folders: [Int]) throws -> URL {
        let home = try OldVersions.makeHome()
        try OldVersions.lay(
            home,
            folders: folders.map { "\(profiles)/v\($0)/IndexedDB" },
            files: markerOn.map { "\(profiles)/v\($0)/FigmaProfileMigrated" }
        )
        return home
    }

    @Test
    func profilesBelowTheMigratedOneAreOffered() throws {
        let home = try figmaHome(markerOn: [33, 42, 43], folders: [33, 39, 42, 43])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(OldVersions.offered(home, "\(profiles)/v33"))
        #expect(OldVersions.offered(home, "\(profiles)/v39"))
        #expect(OldVersions.offered(home, "\(profiles)/v42"))
        #expect(!OldVersions.offered(home, "\(profiles)/v43"))
        #expect(OldVersions.rows(home)[OldToolVersionScanPolicy.figmaProfilesLabel]
            == ["\(profiles)/v33", "\(profiles)/v39", "\(profiles)/v42"])
    }

    /// Figma reads the older profile until it has copied it into the new one and
    /// written the marker.
    @Test
    func nothingWhileTheNewestIsNotMigrated() throws {
        let home = try figmaHome(markerOn: [42, 43], folders: [42, 43, 44])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!OldVersions.offered(home, "\(profiles)/v42"))
        #expect(!OldVersions.offered(home, "\(profiles)/v43"))
        #expect(OldVersions.rows(home)[OldToolVersionScanPolicy.figmaProfilesLabel] == nil)
    }

    @Test
    func aMarkerThatIsNotAFileDoesNotCount() throws {
        let home = try figmaHome(markerOn: [], folders: [42, 43])
        defer { try? FileManager.default.removeItem(at: home) }
        try OldVersions.lay(home, folders: ["\(profiles)/v43/FigmaProfileMigrated"])
        #expect(!OldVersions.offered(home, "\(profiles)/v42"))
    }
}

// MARK: - Rows

@Suite("Old tool versions (#324): Dev Tools rows")
struct OldToolVersionRowTests {
    /// None of these may ever be Safe to Clean: Clean Safe Items and scheduled
    /// cleans would take them without asking.
    @Test
    func everyRowIsCheckFirst() {
        let labels = [
            OldToolVersionScanPolicy.cursorLeftoverLabel,
            OldToolVersionScanPolicy.claudeDownloadLabel,
            OldToolVersionScanPolicy.systemImagesLabel,
            OldToolVersionScanPolicy.figmaProfilesLabel,
            "Android NDK 27.0.12077973",
        ]
        // A label with no explanation entry would come back Not Sure, so this
        // also proves each one reaches its entry.
        for label in labels {
            let info = DevScanner.automaticSafetyInfo(forDevToolLabel: label, primaryPath: nil)
            #expect(info.level == .medium, "\(label)")
        }
    }

    @Test
    func ndkRowsNameTheirVersion() {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "Android NDK 27.0.12077973", primaryPath: nil)
        #expect(info.headline.contains("27.0.12077973"))
    }
}
