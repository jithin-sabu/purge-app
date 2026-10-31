import Foundation

/// Launches `simctl` the way CoreSimulator expects, and keeps working after
/// Xcode is gone.
///
/// `xcrun simctl` needs a selected Xcode. The binary itself lives in
/// CoreSimulator.framework under `/Library/Developer`, which stays behind when
/// Xcode.app is trashed, and so do the simulator runtimes it manages. Someone who
/// deleted Xcode to free space is exactly who still has 25 GB of runtimes, so the
/// framework copy is the fallback whenever `xcrun` cannot find the tool.
///
/// `/usr/bin/xcrun` is a shim that exists on every Mac. Run with no developer
/// directory, it shows macOS's "install the command line developer tools" dialog
/// instead of failing (#298), so it is only run once `DeveloperDirectory` says
/// there is one.
nonisolated enum Simctl {
    static let xcrunPath = "/usr/bin/xcrun"
    static let frameworkDirectoryPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"
    static let frameworkPath = frameworkDirectoryPath + "/Resources/bin/simctl"
    /// Where CoreSimulator keeps the runtime images it manages.
    static let runtimeStorePath = "/Library/Developer/CoreSimulator"
    /// Where CoreSimulator keeps this user's devices and caches.
    static let userFolderRelativePath = "Library/Developer/CoreSimulator"

    /// How `simctl` is reached on this Mac.
    enum Launcher: Equatable {
        case xcrun
        case framework
    }

    private enum Resolution {
        case unresolved
        case resolved(Launcher?)
    }

    private static let launcherLock = NSLock()
    private nonisolated(unsafe) static var resolution: Resolution = .unresolved

    /// `xcrun --find` is a cheap lookup; past this something is wedged.
    private static let findTimeout: TimeInterval = 10

    /// Resolved once per process: `xcrun` when it can find `simctl`, the framework
    /// copy when it cannot, `nil` when neither exists.
    static func launcher(fileManager: FileManager = .default) -> Launcher? {
        launcherLock.lock()
        if case .resolved(let cached) = resolution {
            launcherLock.unlock()
            return cached
        }
        launcherLock.unlock()

        // Resolved outside the lock: `xcrun --find` is a child process, and the
        // scanner and the deleter may both ask on cold start.
        let resolved = resolveLauncher(
            developerDirectoryExists: { DeveloperDirectory.exists },
            launch: { ProcessRunner.run(executablePath: $0, arguments: $1, timeout: $2) },
            isExecutable: { fileManager.isExecutableFile(atPath: $0) }
        )
        launcherLock.lock()
        resolution = .resolved(resolved)
        launcherLock.unlock()
        return resolved
    }

    /// `launcher` with the developer directory check, the process launch and the
    /// executable check handed in, so tests can check that `xcrun` is never run
    /// on a Mac without developer tools.
    static func resolveLauncher(
        developerDirectoryExists: () -> Bool,
        launch: (_ executablePath: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output?,
        isExecutable: (_ path: String) -> Bool
    ) -> Launcher? {
        // `isExecutableFile` on `xcrunPath` is no guard: the shim is always there.
        if developerDirectoryExists(),
           let found = launch(xcrunPath, ["--find", "simctl"], findTimeout),
           found.succeeded {
            return .xcrun
        }
        if isExecutable(frameworkPath) {
            return .framework
        }
        return nil
    }

    /// `false` when nothing CoreSimulator has ever been installed or run for this
    /// user: no framework, no runtime store, no devices folder. Then there are no
    /// runtimes to list, and the scan need not launch anything to find that out.
    static func coreSimulatorPresent(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemFolders: [String] = [Simctl.frameworkDirectoryPath, Simctl.runtimeStorePath]
    ) -> Bool {
        let userFolder = home.appendingPathComponent(userFolderRelativePath, isDirectory: true).path
        return (systemFolders + [userFolder]).contains { fileManager.fileExists(atPath: $0) }
    }

    /// The shape of `run`, so tests can hand in a fake `simctl`.
    typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output?

    /// Runs `simctl <arguments>` and returns its output, or `nil` when no `simctl`
    /// could be launched. Blocks the calling thread like `ProcessRunner.run`.
    static func run(_ arguments: [String], timeout: TimeInterval) -> ProcessRunner.Output? {
        dispatch(
            arguments,
            timeout: timeout,
            launcher: launcher(),
            launch: { ProcessRunner.run(executablePath: $0, arguments: $1, timeout: $2) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// `run` with the launcher, the process launch and the executable check handed
    /// in, so tests can check which binary each call reaches.
    static func dispatch(
        _ arguments: [String],
        timeout: TimeInterval,
        launcher: Launcher?,
        launch: (_ executablePath: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output?,
        isExecutable: (_ path: String) -> Bool
    ) -> ProcessRunner.Output? {
        switch launcher {
        case .xcrun:
            let output = launch(xcrunPath, ["simctl"] + arguments, timeout)
            // `xcrun --find` passing does not mean xcrun will run the tool. An Xcode
            // update waiting on its license, for one, stops xcrun before simctl
            // starts. simctl never ran, so asking the framework copy is not a
            // second attempt at the same work. When that copy can't launch either,
            // xcrun's own answer is kept: it names the cause.
            if let output, xcrunRefused(output), isExecutable(frameworkPath) {
                return launch(frameworkPath, arguments, timeout) ?? output
            }
            return output
        case .framework:
            return launch(frameworkPath, arguments, timeout)
        case nil:
            return nil
        }
    }

    /// `true` when xcrun itself failed and simctl never started. xcrun prefixes its
    /// own errors with "xcrun: error:", and the license check speaks for itself.
    static func xcrunRefused(_ output: ProcessRunner.Output) -> Bool {
        guard !output.timedOut, output.status != 0 else { return false }
        let text = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("xcrun: error:") || mentionsXcodeLicense(text)
    }

    /// Matches both texts Xcode prints when its license waits to be accepted:
    /// "You have not agreed to the Xcode license agreements" and "please run
    /// 'sudo xcodebuild -license'". xcrun exits 69 for either.
    static func mentionsXcodeLicense(_ lowercasedText: String) -> Bool {
        lowercasedText.contains("xcode license") || lowercasedText.contains("xcodebuild -license")
    }

    /// Same as `ProcessRunner.runAsync`: keeps the blocking drain off the caller's thread.
    static func runAsync(_ arguments: [String], timeout: TimeInterval) async -> ProcessRunner.Output? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(arguments, timeout: timeout))
            }
        }
    }
}
