import Foundation
import Testing
@testable import Purge

/// How the Metal Toolchain row is found (#132): what `xcodebuild -showComponent`
/// says, which `xcodebuild` is run, and that a Mac with nothing to find launches
/// nothing. Nothing here reads Apple's real AssetsV2 or runs a real `xcodebuild`.
@Suite("Xcode components")
struct XcodeComponentTests {
    private static let realRoot = URL(fileURLWithPath: "/System/Library/AssetsV2", isDirectory: true)
    private static let realAssetData = "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/389a215aea89fda945178f9fb8bcdc6aa0e20570.asset/AssetData"

    // MARK: Reading -showComponent

    /// The output Xcode 27.0 printed on the dev Mac with the toolchain installed.
    @Test func readsTheInstalledJSON() throws {
        let json = FakeXcodebuild.installedJSON(assetData: Self.realAssetData)

        let status = try #require(XcodeComponent.parseShowComponent(Data(json.utf8), kind: .metalToolchain, assetsRoot: Self.realRoot))

        #expect(status.build == "27A266a")
        #expect(status.installedAsset?.path == "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/389a215aea89fda945178f9fb8bcdc6aa0e20570.asset")
    }

    /// The plain text form, as older reports show it, reads the same.
    @Test func readsTheTextForm() throws {
        let text = """
        Asset Path: \(Self.realAssetData)
        Build Version: 17C48
        Status: installed
        Toolchain Identifier: com.apple.dt.toolchain.Metal.32023
        Toolchain Search Path: /Volumes/MetalToolchainCryptex
        """

        let status = try #require(XcodeComponent.parseShowComponent(Data(text.utf8), kind: .metalToolchain, assetsRoot: Self.realRoot))

        #expect(status.build == "17C48")
        #expect(status.installedAsset?.lastPathComponent == "389a215aea89fda945178f9fb8bcdc6aa0e20570.asset")
    }

    @Test func uninstalledHasNoAsset() throws {
        let json = FakeXcodebuild.uninstalledJSON()

        let status = try #require(XcodeComponent.parseShowComponent(Data(json.utf8), kind: .metalToolchain, assetsRoot: Self.realRoot))

        #expect(status.installedAsset == nil)
        #expect(status.build == "27A266a")
    }

    /// Output that can't be read is "unknown", never "not installed".
    @Test func unreadableOutputIsUnknown() {
        #expect(XcodeComponent.parseShowComponent(Data("garbage".utf8), kind: .metalToolchain, assetsRoot: Self.realRoot) == nil)
        #expect(XcodeComponent.parseShowComponent(Data(#"{"buildVersion": "27A266a"}"#.utf8), kind: .metalToolchain, assetsRoot: Self.realRoot) == nil)
    }

    /// Purge only offers a download it can place in the component's own AssetsV2
    /// folder. Anything else is never offered or deleted, even when `xcodebuild`
    /// says installed.
    @Test(arguments: [
        "/Users/someone/Library/Developer/MetalToolchain/1.asset/AssetData",
        "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/1.asset/AssetData",
        "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/AssetData",
        "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/nested/1.asset/AssetData",
        "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/../com_apple_MobileAsset_Other/1.asset",
        "System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/1.asset/AssetData",
        ""
    ])
    func anAssetOutsideTheComponentFolderIsNeverPlaced(_ path: String) throws {
        let json = FakeXcodebuild.installedJSON(assetData: path)

        let status = try #require(XcodeComponent.parseShowComponent(Data(json.utf8), kind: .metalToolchain, assetsRoot: Self.realRoot))

        #expect(status.installedAsset == nil)
    }

    // MARK: Safety

    /// `xcodebuild` deletes it permanently, so it is never Safe: Clean Safe Items
    /// and scheduled cleans only move things to the Trash (#136).
    @Test func isAlwaysCheckFirst() {
        let info = XcodeComponent.safetyInfo(kind: .metalToolchain, sizeBytes: 923_582_464)

        #expect(info.level == .medium)
        #expect(info.headline == "Metal Toolchain")
        #expect(info.explanation.contains("xcodebuild -downloadComponent MetalToolchain"))
        #expect(info.explanation.contains("every account on this Mac"))
    }

    /// History names the asset folder by its component, since its own name is a
    /// hash. Only an `.asset` folder directly in the component's folder counts.
    @Test func historyNamesTheAssetFolderByItsComponent() {
        let folder = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/389a.asset")

        #expect(XcodeComponent.Kind(assetFolder: folder) == .metalToolchain)
        #expect(XcodeComponent.Kind(assetFolder: folder)?.displayName == "Metal Toolchain")
        #expect(XcodeComponent.Kind(assetFolder: folder.appendingPathComponent("AssetData")) == nil)
        #expect(XcodeComponent.Kind(assetFolder: URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/1.asset")) == nil)
        #expect(XcodeComponent.Kind(assetFolder: URL(fileURLWithPath: "/Users/me/Library/Caches/389a.asset")) == nil)
    }

    // MARK: Which xcodebuild runs

    /// Never the `/usr/bin` shim, and nothing at all without a full Xcode: the
    /// Command Line Tools carry no `xcodebuild`, and the shim with no developer
    /// directory shows the install dialog (#298).
    @Test func runsOnlyAFullXcodesOwnXcodebuild() {
        let allExecutable: (String) -> Bool = { _ in true }

        #expect(XcodeBuildTool.executablePath(developerDirectory: "/Applications/Xcode.app/Contents/Developer", isExecutable: allExecutable)
            == "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild")
        #expect(XcodeBuildTool.executablePath(developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer/", isExecutable: allExecutable)
            == "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild")
        #expect(XcodeBuildTool.executablePath(developerDirectory: "/Library/Developer/CommandLineTools", isExecutable: allExecutable) == nil)
        #expect(XcodeBuildTool.executablePath(developerDirectory: nil, isExecutable: allExecutable) == nil)
        #expect(XcodeBuildTool.executablePath(developerDirectory: "", isExecutable: allExecutable) == nil)
        #expect(XcodeBuildTool.executablePath(developerDirectory: "/Applications/Xcode.app/Contents/Developer", isExecutable: { _ in false }) == nil)
    }

    // MARK: Discovery

    /// Most Macs have no download, and `-showComponent` can mount the toolchain,
    /// so the scan launches nothing unless an `.asset` folder is there.
    @Test func noDownloadLaunchesNothing() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let xcodebuild = FakeXcodebuild(asset: nil, installed: false)

        let found = await DevScanner().discoverXcodeComponents(assetsRoot: assets.root, run: { xcodebuild.run($0, $1) })

        #expect(found.isEmpty)
        #expect(xcodebuild.arguments.isEmpty)
    }

    @Test func installedToolchainIsFoundAndSized() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let asset = try assets.addDownload(build: nil, folder: XcodeComponent.Kind.metalToolchain.assetTypeFolderName)
        let xcodebuild = FakeXcodebuild(asset: asset)

        let found = await DevScanner().discoverXcodeComponents(
            assetsRoot: assets.root,
            run: { xcodebuild.run($0, $1) },
            measure: { _ in 923_582_464 }
        )

        let component = try #require(found.first)
        #expect(found.count == 1)
        #expect(component.kind == .metalToolchain)
        #expect(component.build == "27A266a")
        #expect(component.assetURL.standardizedFileURL.path == asset.standardizedFileURL.path)
        #expect(component.sizeBytes == 923_582_464)
        #expect(component.safetyInfo.level == .medium)
        #expect(xcodebuild.arguments == [["-showComponent", "metalToolchain", "-json"]])
    }

    /// A download left on disk that `xcodebuild` doesn't list as installed, one
    /// with no full Xcode to ask, and one whose answer can't be read are all left out.
    @Test func noRowWithoutAClearInstalledAnswer() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let asset = try assets.addDownload(build: nil, folder: XcodeComponent.Kind.metalToolchain.assetTypeFolderName)
        let scanner = DevScanner()

        let uninstalled = FakeXcodebuild(asset: asset, installed: false)
        #expect(await scanner.discoverXcodeComponents(assetsRoot: assets.root, run: { uninstalled.run($0, $1) }).isEmpty)

        #expect(await scanner.discoverXcodeComponents(assetsRoot: assets.root, run: { _, _ in nil }).isEmpty)

        let license = FakeXcodebuild(asset: asset)
        license.showFails = true
        #expect(await scanner.discoverXcodeComponents(assetsRoot: assets.root, run: { license.run($0, $1) }).isEmpty)
    }

    /// `-deleteComponent` takes no asset ID, so a second download in the folder
    /// (another Xcode's build, or one left from an update) means the delete may
    /// take more than the row shows. No row then.
    @Test func aSecondDownloadOffersNothing() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let folder = XcodeComponent.Kind.metalToolchain.assetTypeFolderName
        let listed = try assets.addDownload(build: nil, folder: folder)
        _ = try assets.addDownload(build: nil, folder: folder)
        let xcodebuild = FakeXcodebuild(asset: listed)

        let found = await DevScanner().discoverXcodeComponents(
            assetsRoot: assets.root,
            run: { xcodebuild.run($0, $1) },
            measure: { _ in 923_582_464 }
        )

        #expect(found.isEmpty)
        #expect(XcodeComponent.isOnlyDownload(listed, kind: .metalToolchain, in: assets.root) == false)
    }

    /// A size that can't be read, or reads zero, offers nothing.
    @Test func unmeasuredDownloadIsLeftOut() async throws {
        let assets = try FakeAssetsV2()
        defer { assets.cleanUp() }
        let asset = try assets.addDownload(build: nil, folder: XcodeComponent.Kind.metalToolchain.assetTypeFolderName)
        let xcodebuild = FakeXcodebuild(asset: asset)
        let scanner = DevScanner()

        #expect(await scanner.discoverXcodeComponents(assetsRoot: assets.root, run: { xcodebuild.run($0, $1) }, measure: { _ in nil }).isEmpty)
        #expect(await scanner.discoverXcodeComponents(assetsRoot: assets.root, run: { xcodebuild.run($0, $1) }, measure: { _ in 0 }).isEmpty)
    }
}
