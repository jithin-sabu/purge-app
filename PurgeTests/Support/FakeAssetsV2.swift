import Foundation

/// A throwaway stand-in for /System/Library/AssetsV2 holding simulator runtime
/// downloads, so the #165 checks never read or touch Apple's real folder.
///
/// Pass `root` to `SimulatorRuntime.downloads(in:)` or to
/// `FileDeleter.removeSimulatorRuntime(assetsRoot:)`, and call `cleanUp()` after.
final class FakeAssetsV2: @unchecked Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PurgeFakeAssetsV2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Adds one `<id>.asset` folder the way MobileAsset lays it out: an image under
    /// `AssetData` and an Info.plist naming `build`. A `nil` build leaves the
    /// Info.plist out, like an asset that can't be read.
    @discardableResult
    func addDownload(build: String?, folder: String = "com_apple_MobileAsset_iOSSimulatorRuntime", imageBytes: Int = 4096) throws -> URL {
        let asset = root
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).asset", isDirectory: true)
        let assetData = asset.appendingPathComponent("AssetData", isDirectory: true)
        try FileManager.default.createDirectory(at: assetData, withIntermediateDirectories: true)
        try Data(count: imageBytes).write(to: assetData.appendingPathComponent("090-44150-318.dmg"))
        if let build {
            let plist: [String: Any] = [
                "CFBundleIdentifier": "com.apple.MobileAsset.iOSSimulatorRuntime",
                "MobileAssetProperties": [
                    "Build": build,
                    "__AssetDefaultGarbageCollectionBehavior": "NeverCollected"
                ]
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: asset.appendingPathComponent("Info.plist"))
        }
        return asset
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
