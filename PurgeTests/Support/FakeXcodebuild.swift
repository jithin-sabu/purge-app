import Foundation
@testable import Purge

/// A stand-in `xcodebuild` for the Xcode component checks (#132). It answers
/// `-showComponent <name> -json` the way Xcode 27 does, and on `-deleteComponent`
/// takes the component away, removing its asset folder from a `FakeAssetsV2` the
/// way Apple's asset service does. Records every argv it is given.
final class FakeXcodebuild: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var installed: Bool

    /// The `<id>.asset` folder `-showComponent` names while installed.
    let asset: URL?
    let build: String
    /// The exit status `-deleteComponent` returns.
    var deleteStatus: Int32 = 0
    /// Keeps the component installed after a delete that exits 0.
    var staysInstalled = false
    /// `-showComponent` fails, as with a pending Xcode license.
    var showFails = false

    init(asset: URL?, build: String = "27A266a", installed: Bool = true) {
        self.asset = asset
        self.build = build
        self.installed = installed
    }

    var arguments: [[String]] { lock.withLock { calls } }

    var deleteCalls: [[String]] { arguments.filter { $0.first == "-deleteComponent" } }

    /// The real `-showComponent metalToolchain -json` output from Xcode 27.0 with
    /// the toolchain installed, with `assetPath` pointed at `asset`.
    static func installedJSON(assetData path: String, build: String = "27A266a") -> String {
        let escaped = path.replacingOccurrences(of: "/", with: "\\/")
        return """
        {
          "assetPath" : "\(escaped)",
          "buildVersion" : "\(build)",
          "status" : "installed",
          "toolchainIdentifier" : "com.apple.dt.toolchain.Metal.32023.921.5",
          "toolchainSearchPath" : "\\/private\\/var\\/run\\/com.apple.security.cryptexd\\/mnt\\/com.apple.MobileAsset.MetalToolchain-v27.1.266.1.6Mh0rW"
        }
        """
    }

    static func uninstalledJSON(build: String = "27A266a") -> String {
        """
        {
          "buildVersion" : "\(build)",
          "status" : "uninstalled"
        }
        """
    }

    func run(_ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output? {
        lock.lock()
        calls.append(arguments)
        lock.unlock()

        switch arguments.first {
        case "-showComponent":
            if showFails {
                let text = "You have not agreed to the Xcode license agreements."
                return ProcessRunner.Output(status: 69, stdout: Data(), stderr: Data(text.utf8), timedOut: false)
            }
            let isInstalled = lock.withLock { installed }
            let json: String
            if isInstalled, let asset {
                json = Self.installedJSON(assetData: asset.appendingPathComponent("AssetData").path, build: build)
            } else {
                json = Self.uninstalledJSON(build: build)
            }
            let noise = "IDEDownloadableMetalToolchainCoordinator: Failed to remount the Metal Toolchain"
            return ProcessRunner.Output(status: 0, stdout: Data(json.utf8), stderr: Data(noise.utf8), timedOut: false)
        case "-deleteComponent":
            guard deleteStatus == 0 else {
                let text = "xcodebuild: error: Failed to delete component."
                return ProcessRunner.Output(status: deleteStatus, stdout: Data(), stderr: Data(text.utf8), timedOut: false)
            }
            if !staysInstalled {
                lock.withLock { installed = false }
                if let asset { try? FileManager.default.removeItem(at: asset) }
            }
            return ProcessRunner.Output(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
        default:
            return ProcessRunner.Output(status: 64, stdout: Data(), stderr: Data(), timedOut: false)
        }
    }
}
