import Foundation

/// Runs the `xcodebuild` inside the selected Xcode, and nothing else (#132).
///
/// `/usr/bin/xcodebuild` is a shim like `/usr/bin/xcrun`: with no developer
/// directory it shows macOS's "install the command line developer tools" dialog
/// (#298), and with only the Command Line Tools selected it just fails, since they
/// carry no `xcodebuild`. So Purge never runs the shim. It runs
/// `<developer dir>/usr/bin/xcodebuild` directly, and only when the developer
/// directory is a full Xcode's.
nonisolated enum XcodeBuildTool {
    /// The shape of `run`, so tests can hand in a fake `xcodebuild`.
    typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output?

    /// `<developerDirectory>/usr/bin/xcodebuild` when the directory is inside an
    /// Xcode app (`…/Xcode.app/Contents/Developer`) and that file can run. `nil`
    /// on a Mac with no developer tools or only the Command Line Tools.
    static func executablePath(developerDirectory: String?, isExecutable: (_ path: String) -> Bool) -> String? {
        guard var directory = developerDirectory, !directory.isEmpty else { return nil }
        while directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
        guard directory.hasSuffix(".app/Contents/Developer") else { return nil }
        let path = directory + "/usr/bin/xcodebuild"
        return isExecutable(path) ? path : nil
    }

    /// Runs `xcodebuild <arguments>` from the selected Xcode. `nil` when there is
    /// no full Xcode to run it from, or it could not be launched. Blocks the
    /// calling thread like `ProcessRunner.run`.
    static func run(_ arguments: [String], timeout: TimeInterval) -> ProcessRunner.Output? {
        guard let path = executablePath(
            developerDirectory: DeveloperDirectory.active(),
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else { return nil }
        return ProcessRunner.run(executablePath: path, arguments: arguments, timeout: timeout)
    }

    /// Same as `ProcessRunner.runAsync`: keeps the blocking drain off the caller's thread.
    static func runAsync(_ arguments: [String], timeout: TimeInterval) async -> ProcessRunner.Output? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(arguments, timeout: timeout))
            }
        }
    }

    /// `xcodebuild -showComponent <kind> -json`. A cold first launch of
    /// `xcodebuild` can take a while; past this something is wedged.
    static let showComponentTimeout: TimeInterval = 60

    /// Asks `run` what `xcodebuild` says about `kind`. `nil` when it could not be
    /// asked or did not answer clearly, which never counts as "not installed".
    static func status(
        of kind: XcodeComponent.Kind,
        run: Runner,
        assetsRoot: URL = SimulatorRuntime.mobileAssetRoot
    ) -> XcodeComponent.Status? {
        guard let output = run(["-showComponent", kind.rawValue, "-json"], showComponentTimeout),
              output.succeeded
        else { return nil }
        return XcodeComponent.parseShowComponent(output.stdout, kind: kind, assetsRoot: assetsRoot)
    }
}
