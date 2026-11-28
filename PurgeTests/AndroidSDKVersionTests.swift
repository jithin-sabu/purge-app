import Foundation
import Testing
@testable import Purge

/// Old Android build-tools and SDK platform versions (#467). Each rule is
/// pinned by what is offered, by what must stay next to it, and by the Gradle
/// files and links that keep a version. Every fixture is a throwaway home folder.
private enum SDK {
    typealias Policy = AndroidSDKVersionPolicy

    static let root = "Library/Android/sdk"
    static let buildTools = "\(root)/build-tools"
    static let platforms = "\(root)/platforms"

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-467-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    /// Finished installs have `source.properties`. Unfinished ones have only `.installer`.
    static func install(_ home: URL, in folder: String, complete: [String], partial: [String] = []) throws {
        for name in complete {
            try write("Pkg.Revision=1\n", home, "\(folder)/\(name)/source.properties")
        }
        for name in partial {
            try write("x", home, "\(folder)/\(name)/.installer/state")
        }
    }

    /// The SDK on the issue's Mac, plus an unfinished newer build-tools.
    static func typicalSDK() throws -> URL {
        let home = try makeHome()
        try install(home, in: buildTools, complete: ["34.0.0", "35.0.0", "35.0.1", "36.0.0"], partial: ["37.0.0"])
        try install(home, in: platforms, complete: ["android-33", "android-34", "android-35"])
        return home
    }

    static func write(_ text: String, _ home: URL, _ relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func link(_ home: URL, _ relative: String, to destination: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    /// No recorded Gradle file, an empty `lsof` listing and one link folder,
    /// unless a test says otherwise. `files` are relative to `home`.
    static func context(
        _ home: URL,
        files: [String]? = [],
        lsof: String? = "",
        linkFolders: [String] = [".local/bin"],
        unreadable: Set<String> = []
    ) -> Policy.Context {
        let paths = files.map { $0.map { home.appendingPathComponent($0).path } }
        let blocked = Set(unreadable.map { home.appendingPathComponent($0).path })
        return Policy.Context(
            gradleFiles: { paths },
            mayRead: { !blocked.contains($0) },
            openFiles: { lsof },
            linkFolders: linkFolders
        )
    }

    static func offered(
        _ home: URL,
        _ relative: String,
        _ context: Policy.Context,
        check: NvmNodeVersionPolicy.Check = .scan
    ) -> Bool {
        Policy.isOffered(home.appendingPathComponent(relative).path, home: home.path, context: context, check: check)
    }

    /// What the Gradle files at `relative` paths say, after writing `files`.
    static func pins(_ home: URL, _ files: [String: String], read relative: [String]? = nil) throws -> AndroidGradlePins.Pins {
        for (path, text) in files { try write(text, home, path) }
        let paths = (relative ?? files.keys.filter { $0.hasSuffix(".gradle") || $0.hasSuffix(".gradle.kts") })
            .map { home.appendingPathComponent($0).path }
        return AndroidGradlePins.pins(in: paths, home: home.path, mayRead: { _ in true })
    }

    static let noAVD = OldToolVersionScanPolicy.AndroidContext(
        avdHomes: [], ndkEnvironmentPaths: [], emulatorIsRunning: { false }
    )
}

// MARK: - Shape

@Suite("Android SDK versions (#467): shapes")
struct AndroidSDKVersionShapeTests {
    typealias Policy = AndroidSDKVersionPolicy
    private let home = "/Users/someone"

    @Test
    func onlyVersionFoldersHaveAShape() {
        let sdk = "\(home)/Library/Android/sdk"
        let cases: [(String, Policy.Folder?)] = [
            ("\(sdk)/build-tools/35.0.1", .buildTools),
            ("\(sdk)/build-tools/36.0.0-rc1", nil),
            ("\(sdk)/build-tools/android-4.4W", nil),
            ("\(sdk)/build-tools/.temp", nil),
            ("\(sdk)/build-tools", nil),
            ("\(sdk)/build-tools/35.0.1/apksigner", nil),
            ("\(sdk)/platforms/android-34", .platform),
            ("\(sdk)/platforms/android-9", .platform),
            ("\(sdk)/platforms/android-34-ext10", nil),
            ("\(sdk)/platforms/android-36.1", nil),
            ("\(sdk)/platforms/android-UpsideDownCake", nil),
            ("\(sdk)/platforms/android-034", nil),
            ("\(sdk)/platforms/android-34/android.jar", nil),
            ("\(sdk)/platforms", nil),
            ("\(sdk)/sources/android-34", nil),
            ("\(sdk)/cmake/3.22.1", nil),
            ("\(home)/sdk/build-tools/35.0.1", nil)
        ]
        for (path, expected) in cases {
            #expect(Policy.folder(of: path, home: home) == expected, "\(path)")
        }
        #expect(OldToolVersionScanPolicy.kind(of: "\(sdk)/build-tools/35.0.1", home: home) == .androidBuildTools)
        #expect(OldToolVersionScanPolicy.kind(of: "\(sdk)/platforms/android-34", home: home) == .androidPlatform)
        #expect(OldToolVersionScanPolicy.isWhitelistedPath("\(sdk)/platforms/android-34", home: home))
        #expect(!OldToolVersionScanPolicy.isWhitelistedPath("\(sdk)/platforms/android-34-ext10", home: home))
    }

    @Test
    func labelsCarryTheVersion() {
        #expect(Policy.buildToolsVersion(inLabel: "Android SDK Build-Tools 35.0.1") == "35.0.1")
        #expect(Policy.buildToolsVersion(inLabel: "Android SDK Build-Tools") == nil)
        #expect(Policy.buildToolsVersion(inLabel: "Android SDK Build-Tools latest") == nil)
        #expect(Policy.platformLevel(inLabel: "Android SDK Platform 34") == "34")
        #expect(Policy.platformLevel(inLabel: "Android SDK Platform 34-ext10") == nil)
        #expect(Policy.platformLevel(inLabel: "Android NDK 27.0.12077973") == nil)
        #expect(BrandIconMapping.slug(forDefinitionKey: "Android SDK Build-Tools 35.0.1") == "androidstudio")
        #expect(BrandIconMapping.slug(forDefinitionKey: "Android SDK Platform 34") == "androidstudio")
    }

    @Test
    func rowsAreCheckFirstAndNameTheVersion() {
        let tools = DevScanner.automaticSafetyInfo(forDevToolLabel: "Android SDK Build-Tools 35.0.1", primaryPath: nil)
        #expect(tools.level == .medium)
        #expect(tools.headline.contains("35.0.1"))
        let platform = DevScanner.automaticSafetyInfo(forDevToolLabel: "Android SDK Platform 34", primaryPath: nil)
        #expect(platform.level == .medium)
        #expect(platform.headline.contains("34"))
        #expect(!platform.explanation.isEmpty)
    }
}

// MARK: - What stays

@Suite("Android SDK versions (#467): newest and finished")
struct AndroidSDKVersionNewestTests {

    @Test
    func theNewestFinishedVersionAndAnythingNewerStay() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        try SDK.install(home, in: SDK.buildTools, complete: ["36.1.0-rc1"], partial: ["33.0.0"])
        let context = SDK.context(home)
        for version in ["34.0.0", "35.0.0", "35.0.1"] {
            #expect(SDK.offered(home, "\(SDK.buildTools)/\(version)", context), "\(version)")
        }
        #expect(!SDK.offered(home, "\(SDK.buildTools)/36.0.0", context))
        // Unfinished, one older and one newer than the newest finished.
        #expect(!SDK.offered(home, "\(SDK.buildTools)/33.0.0", context))
        #expect(!SDK.offered(home, "\(SDK.buildTools)/37.0.0", context))
        #expect(!SDK.offered(home, "\(SDK.buildTools)/36.1.0-rc1", context))
        #expect(SDK.offered(home, "\(SDK.platforms)/android-33", context))
        #expect(SDK.offered(home, "\(SDK.platforms)/android-34", context))
        #expect(!SDK.offered(home, "\(SDK.platforms)/android-35", context))
    }

    /// `android-9` sorts after `android-33` as text. The level decides.
    @Test
    func platformsCompareByLevel() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try SDK.install(home, in: SDK.platforms, complete: [
            "android-9", "android-10", "android-33", "android-34-ext10", "android-36.1", "android-UpsideDownCake"
        ])
        let context = SDK.context(home)
        #expect(SDK.offered(home, "\(SDK.platforms)/android-9", context))
        #expect(SDK.offered(home, "\(SDK.platforms)/android-10", context))
        #expect(!SDK.offered(home, "\(SDK.platforms)/android-33", context))
        for other in ["android-34-ext10", "android-36.1", "android-UpsideDownCake"] {
            #expect(!SDK.offered(home, "\(SDK.platforms)/\(other)", context), "\(other)")
        }
        let offered = AndroidSDKVersionPolicy.offeredFolders(home: home.path, context: context)
        #expect(offered.platforms == ["android-9", "android-10"].map { home.appendingPathComponent("\(SDK.platforms)/\($0)").path })
    }

    @Test
    func aLoneVersionStays() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try SDK.install(home, in: SDK.buildTools, complete: ["35.0.0"])
        try SDK.install(home, in: SDK.platforms, complete: ["android-34"], partial: ["android-35"])
        let context = SDK.context(home)
        #expect(!SDK.offered(home, "\(SDK.buildTools)/35.0.0", context))
        #expect(!SDK.offered(home, "\(SDK.platforms)/android-34", context))
    }

    /// Nothing is offered until a walk with Full Disk Access saved the Gradle files.
    @Test
    func noRecordedGradleFilesKeepsEverything() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        let unknown = SDK.context(home, files: nil)
        for check in [NvmNodeVersionPolicy.Check.quick, .scan, .move] {
            #expect(!SDK.offered(home, "\(SDK.buildTools)/34.0.0", unknown, check: check))
            #expect(!SDK.offered(home, "\(SDK.platforms)/android-33", unknown, check: check))
        }
        #expect(AndroidSDKVersionPolicy.offeredFolders(home: home.path, context: unknown) == ([], []))
        #expect(SDK.offered(home, "\(SDK.buildTools)/34.0.0", SDK.context(home), check: .quick))
    }

    @Test
    func aLinkedSDKIsNotOffered() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: home.appendingPathComponent(SDK.root),
            to: home.appendingPathComponent("Documents/sdk")
        )
        try SDK.link(home, SDK.root, to: home.appendingPathComponent("Documents/sdk").path)
        let context = SDK.context(home)
        #expect(!SDK.offered(home, "\(SDK.buildTools)/34.0.0", context))
        #expect(!SDK.offered(home, "\(SDK.platforms)/android-33", context))
    }

    /// A version folder that is itself a link is never offered: the move would
    /// take whatever it leads to.
    @Test
    func aLinkedVersionFolderIsNotOffered() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        for relative in ["\(SDK.buildTools)/34.0.0", "\(SDK.platforms)/android-33"] {
            let real = home.appendingPathComponent("Documents/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: home.appendingPathComponent(relative), to: real)
            try SDK.link(home, relative, to: real.path)
            #expect(!SDK.offered(home, relative, SDK.context(home)), "\(relative)")
            #expect(!SDK.offered(home, relative, SDK.context(home), check: .quick), "\(relative)")
        }
    }

    /// `lsof` runs only right before the move, and a listing that can't be read refuses.
    @Test
    func theMoveChecksOpenFiles() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = "\(SDK.platforms)/android-33"
        let jar = home.appendingPathComponent("\(old)/android.jar").path
        #expect(SDK.offered(home, old, SDK.context(home, lsof: nil), check: .scan))
        #expect(!SDK.offered(home, old, SDK.context(home, lsof: nil), check: .move))
        #expect(!SDK.offered(home, old, SDK.context(home, lsof: "p41\ncjava\nn\(jar)\n"), check: .move))
        #expect(SDK.offered(home, old, SDK.context(home), check: .move))
    }

    @Test
    func theDefaultMoveCheckRunsTheAndroidRule() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appendingPathComponent("\(SDK.buildTools)/34.0.0")
        let free = FileDeleter.defaultImmediateMoveCheck(home: home.path, androidSDKVersions: SDK.context(home))
        #expect(free(old))
        let busy = FileDeleter.defaultImmediateMoveCheck(home: home.path, androidSDKVersions: SDK.context(home, lsof: nil))
        #expect(!busy(old), "the Android part runs")
        #expect(busy(home.appendingPathComponent("Library/Caches/Homebrew")))
        #expect(AndroidSDKVersionPolicy.passesImmediateTrashBoundary(
            home.appendingPathComponent("\(SDK.root)/ndk/27.0.12077973"), home: home.path, context: SDK.context(home, lsof: nil)
        ))
    }

    @Test
    func rowsListOneVersionEach() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        let prefix = home.path + "/"
        var rows: [String: [String]] = [:]
        for row in OldToolVersionScanPolicy.definitions(home: home, android: SDK.noAVD, androidSDKVersions: SDK.context(home)) {
            rows[row.label] = row.paths.map { String($0.standardizedFileURL.path.dropFirst(prefix.count)) }
        }
        #expect(rows["Android SDK Build-Tools 34.0.0"] == ["\(SDK.buildTools)/34.0.0"])
        #expect(rows["Android SDK Build-Tools 35.0.0"] == ["\(SDK.buildTools)/35.0.0"])
        #expect(rows["Android SDK Build-Tools 35.0.1"] == ["\(SDK.buildTools)/35.0.1"])
        #expect(rows["Android SDK Platform 33"] == ["\(SDK.platforms)/android-33"])
        #expect(rows["Android SDK Platform 34"] == ["\(SDK.platforms)/android-34"])
        #expect(rows.keys.filter { $0.hasPrefix("Android SDK") }.count == 5)
        // The main-thread gate agrees, and refuses once nothing is recorded.
        let url = home.appendingPathComponent("\(SDK.buildTools)/34.0.0")
        #expect(!OldToolVersionScanPolicy.refusesDeletion(url, home: home.path, android: SDK.noAVD, androidSDKVersions: SDK.context(home)))
        #expect(OldToolVersionScanPolicy.refusesDeletion(
            url, home: home.path, android: SDK.noAVD, androidSDKVersions: SDK.context(home, files: nil)
        ))
    }
}

// MARK: - Projects and links

@Suite("Android SDK versions (#467): what keeps a version")
struct AndroidSDKVersionKeepTests {

    @Test
    func aProjectKeepsTheVersionsItNames() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        try SDK.write("""
        android {
            compileSdk = 33
            buildToolsVersion = "35.0.0"
            defaultConfig { targetSdk = 34 }
        }
        """, home, "code/app/app/build.gradle.kts")
        let context = SDK.context(home, files: ["code/app/build.gradle.kts", "code/app/app/build.gradle.kts"])
        #expect(!SDK.offered(home, "\(SDK.platforms)/android-33", context))
        #expect(SDK.offered(home, "\(SDK.platforms)/android-34", context), "targetSdk needs no platform")
        #expect(!SDK.offered(home, "\(SDK.buildTools)/35.0.0", context))
        #expect(SDK.offered(home, "\(SDK.buildTools)/34.0.0", context))
        #expect(SDK.offered(home, "\(SDK.buildTools)/35.0.1", context))
    }

    /// A value Purge can't read keeps every version of its kind, and only that kind.
    @Test
    func anUnreadValueKeepsItsWholeKind() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        try SDK.write("android {\n    compileSdk = flutter.compileSdkVersion\n}\n", home, "code/flutter_app/android/app/build.gradle.kts")
        let context = SDK.context(home, files: ["code/flutter_app/android/app/build.gradle.kts"])
        #expect(!SDK.offered(home, "\(SDK.platforms)/android-33", context))
        #expect(!SDK.offered(home, "\(SDK.platforms)/android-34", context))
        #expect(SDK.offered(home, "\(SDK.buildTools)/34.0.0", context))
    }

    @Test
    func aFileThatCantBeReadKeepsEverything() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        try SDK.write("android { compileSdk = 33 }\n", home, "Documents/app/build.gradle")
        let context = SDK.context(home, files: ["Documents/app/build.gradle"], unreadable: ["Documents/app/build.gradle"])
        #expect(!SDK.offered(home, "\(SDK.platforms)/android-34", context))
        #expect(!SDK.offered(home, "\(SDK.buildTools)/34.0.0", context))
    }

    @Test
    func aLinkInABinFolderKeepsItsBuildTools() throws {
        let home = try SDK.typicalSDK()
        defer { try? FileManager.default.removeItem(at: home) }
        try SDK.write("#!/bin/sh\n", home, "\(SDK.buildTools)/34.0.0/apksigner")
        try SDK.link(home, ".local/bin/apksigner", to: home.appendingPathComponent("\(SDK.buildTools)/34.0.0/apksigner").path)
        try SDK.link(home, ".local/bin/zipalign", to: "../../\(SDK.buildTools)/35.0.0/zipalign")
        let context = SDK.context(home)
        #expect(!SDK.offered(home, "\(SDK.buildTools)/34.0.0", context))
        #expect(!SDK.offered(home, "\(SDK.buildTools)/35.0.0", context), "a relative link counts too")
        #expect(SDK.offered(home, "\(SDK.buildTools)/35.0.1", context))
        // A link folder that can't be read keeps every build-tools version.
        let blocked = SDK.context(home, unreadable: [".local/bin"])
        #expect(!SDK.offered(home, "\(SDK.buildTools)/35.0.1", blocked))
        #expect(SDK.offered(home, "\(SDK.platforms)/android-33", blocked), "platforms don't read links")
    }

    @Test
    func theLedgerListsAndroidBuildFiles() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for file in ["native/app/build.gradle.kts", "native/lib/build.gradle", "native/.idea/build.gradle",
                     "rn/android/app/build.gradle", "jvm/server/build.gradle"] {
            try SDK.write("", home, file)
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("native/docs"), withIntermediateDirectories: true)
        let roots: [(URL, [ProjectType])] = [
            (home.appendingPathComponent("native"), [.androidGradle]),
            (home.appendingPathComponent("rn"), [.androidGradle, .node]),
            (home.appendingPathComponent("jvm"), [.gradleJVM])
        ]
        let files = Set(AndroidSDKVersionPolicy.gradleFiles(inProjectRoots: roots, mayRead: { _ in true })
            .map { String($0.dropFirst(home.path.count + 1)) })
        #expect(files == [
            "native/build.gradle", "native/build.gradle.kts", "native/app/build.gradle.kts", "native/lib/build.gradle",
            "native/android/build.gradle", "native/android/build.gradle.kts",
            "rn/build.gradle", "rn/build.gradle.kts", "rn/android/build.gradle", "rn/android/build.gradle.kts",
            "rn/android/app/build.gradle"
        ])
    }
}

// MARK: - Reading Gradle files

@Suite("Android SDK versions (#467): Gradle values")
struct AndroidGradlePinsTests {
    typealias Pins = AndroidGradlePins.Pins

    @Test
    func writtenOutValuesPin() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pins = try SDK.pins(home, [
            "a/build.gradle": """
            android {
                compileSdkVersion 30
                buildToolsVersion "30.0.3"
            }
            """,
            "b/build.gradle": "android {\n  compileSdkVersion 'android-31'\n  buildToolsVersion('31.0.0')\n}\n",
            "c/build.gradle.kts": "android { compileSdk = 32; buildToolsVersion = \"32.0.0\" }\n",
            "d/build.gradle.kts": """
            android {
                compileSdk {
                    version = release(36) { minorApiLevel = 1 }
                }
            }
            """,
            "e/build.gradle": "android {\n    compileSdkVersion \"Google Inc.:Google APIs:29\"\n    compileSdk(28)\n}\n",
            "f/build.gradle.kts": """
            android {
                // compileSdk = 21
                /* buildToolsVersion = "21.0.0" */
                compileSdkPreview = "UpsideDownCake"
                compileSdkExtension = 10
                defaultConfig { targetSdk = 22; minSdk = 23 }
            }
            """
        ])
        #expect(pins == Pins(
            platforms: ["android-28", "android-29", "android-30", "android-31", "android-32", "android-36"],
            buildTools: ["30.0.3", "31.0.0", "32.0.0"]
        ))
    }

    @Test
    func aPreviewPinsNothingAndKeepsNothing() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pins = try SDK.pins(home, ["a/build.gradle": "android { compileSdkVersion \"android-UpsideDownCake\" }\n"])
        #expect(pins == Pins(platforms: [], buildTools: []))
    }

    @Test
    func aCatalogValueResolves() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pins = try SDK.pins(home, [
            "app/gradle/libs.versions.toml": """
            [versions]
            agp = "8.7.3"
            compileSdk = "34"
            android-buildTools = "34.0.0"   # the tools

            [libraries]
            compileSdk = "not-a-version"
            """,
            "app/app/build.gradle.kts": """
            android {
                compileSdk = libs.versions.compileSdk.get().toInt()
                buildToolsVersion = libs.versions.android.buildTools.get()
            }
            """
        ])
        #expect(pins == Pins(platforms: ["android-34"], buildTools: ["34.0.0"]))
    }

    /// React Native keeps its versions in the root `ext` block under `android/`.
    @Test
    func aRootExtValueResolves() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pins = try SDK.pins(home, [
            "rn/android/build.gradle": """
            buildscript {
                ext {
                    buildToolsVersion = "35.0.0"
                    compileSdkVersion = 35
                    targetSdkVersion = 34
                }
            }
            """,
            "rn/android/app/build.gradle": """
            android {
                compileSdkVersion rootProject.ext.compileSdkVersion
                buildToolsVersion "${rootProject.ext.buildToolsVersion}"
            }
            """
        ])
        #expect(pins == Pins(platforms: ["android-35"], buildTools: ["35.0.0"]))
    }

    @Test
    func propertiesAndExtraValuesResolve() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try SDK.write("android.compileSdk=33\n", home, "p/gradle.properties")
        try SDK.write("tools.version = 33.0.2\n", home, ".gradle/gradle.properties")
        let pins = try SDK.pins(home, [
            "p/app/build.gradle.kts": """
            android {
                compileSdk = providers.gradleProperty("android.compileSdk").get().toInt()
                buildToolsVersion = (findProperty("tools.version") as String)
            }
            """,
            "x/build.gradle.kts": "extra[\"compileSdk\"] = 32\nval buildTools: String = \"32.0.1\"\n",
            "x/lib/build.gradle.kts": """
            android {
                compileSdk = rootProject.extra["compileSdk"] as Int
                buildToolsVersion = buildTools
            }
            """
        ])
        #expect(pins == Pins(platforms: ["android-32", "android-33"], buildTools: ["32.0.1", "33.0.2"]))
    }

    @Test
    func valuesPurgeCantReadKeepTheirKind() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try SDK.pins(home, ["a/build.gradle.kts": "android { compileSdk = if (ci) 34 else 35 }\n"])
            == Pins(platforms: nil, buildTools: []))
        #expect(try SDK.pins(home, ["b/build.gradle": "android { buildToolsVersion versions.buildTools }\n"])
            == Pins(platforms: [], buildTools: nil))
        // A value found by name that is itself not written out keeps its kind too.
        #expect(try SDK.pins(home, [
            "c/build.gradle": "ext { compileSdkVersion = computeSdk() }\n",
            "c/app/build.gradle": "android { compileSdkVersion rootProject.ext.compileSdkVersion }\n"
        ], read: ["c/app/build.gradle"]) == Pins(platforms: nil, buildTools: []))
    }

    @Test
    func aMissingFilePinsNothingAndAHugeOneKeepsEverything() throws {
        let home = try SDK.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try SDK.pins(home, [:], read: ["gone/build.gradle"]) == Pins(platforms: [], buildTools: []))
        let huge = String(repeating: "// padding\n", count: AndroidGradlePins.maximumFileBytes / 10)
        #expect(try SDK.pins(home, ["big/build.gradle": huge + "android { compileSdk = 33 }\n"]) == .unknown)
    }
}
