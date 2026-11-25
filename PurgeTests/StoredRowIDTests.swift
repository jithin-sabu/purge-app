import Foundation
import Testing
@testable import Purge

/// #457: these rows used to work out `id` from `standardizedFileURL` on every
/// read, which checks the disk, and views read ids per row on every render. The
/// id is now worked out once when the row is made. It must stay the same value,
/// because selection, sizes and the deletion report are keyed by it.
@Suite("Row ids are worked out once and match the standardized path")
struct StoredRowIDTests {
    /// A path with `.` and `..` parts, so standardizing has work to do.
    private let messyBundle = URL(fileURLWithPath: "/Applications/./Utilities/../Rectangle.app")

    @Test
    func installedAppIDIsTheStandardizedBundlePath() {
        let app = InstalledApp(
            name: "Rectangle",
            bundleURL: messyBundle,
            bundleID: "com.knollsoft.Rectangle",
            bundleSizeBytes: 0,
            isRunning: false
        )
        #expect(app.id == messyBundle.standardizedFileURL.path)
        #expect(app.id == "/Applications/Rectangle.app")
    }

    @Test
    func installedAppIDStaysWhenSizeAndDatesChange() {
        var app = InstalledApp(
            name: "Rectangle",
            bundleURL: messyBundle,
            bundleID: nil,
            bundleSizeBytes: 0,
            isRunning: false
        )
        let before = app.id
        app.bundleSizeBytes = 42
        app.lastOpened = Date()
        app.volumeName = "SSD"
        #expect(app.id == before)
    }

    @Test
    func uninstallItemIDIsTheStandardizedPath() {
        let path = URL(fileURLWithPath: "/Users/someone/Library/./Caches/../Caches/com.example.app")
        let item = UninstallItem(
            path: path,
            sizeBytes: 1,
            category: .caches,
            safetyInfo: SafetyInfo(level: .medium, headline: "", explanation: "", recoverySteps: "", reinstallCommand: nil),
            matchReason: .bundleID,
            isSelected: true
        )
        #expect(item.id == path.standardizedFileURL.path)
        #expect(item.id == "/Users/someone/Library/Caches/com.example.app")
    }

    @Test
    func packageManagerToolIDUsesTheFirstLocation() {
        let folder = URL(fileURLWithPath: "/opt/homebrew/./Cellar/../Cellar/wget")
        let tool = PackageManagerTool(
            manager: .homebrew, name: "wget", locations: [folder], context: nil, executable: nil,
            arguments: [], environment: [:]
        )
        #expect(tool.id == PackageManager.homebrew.rawValue + ":/opt/homebrew/Cellar/wget")
    }

    @Test
    func packageManagerToolIDFallsBackToTheName() {
        let tool = PackageManagerTool(
            manager: .homebrew, name: "wget", locations: [], context: nil, executable: nil,
            arguments: [], environment: [:]
        )
        #expect(tool.id == PackageManager.homebrew.rawValue + ":wget")
    }

    @Test
    func xcodeComponentIDIsTheStandardizedAssetPath() {
        let asset = URL(fileURLWithPath: "/System/Library/AssetsV2/./com_apple_MobileAsset_MetalToolchain/389a.asset")
        let component = XcodeComponent(kind: .metalToolchain, build: "27A266a", assetURL: asset, sizeBytes: 1)
        #expect(component.id == "/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/389a.asset")
    }
}
