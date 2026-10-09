import Foundation

/// Launches `simctl` the way CoreSimulator expects, and keeps working after
/// Xcode is gone.
///
/// `xcrun simctl` needs a selected Xcode. The binary itself lives in
/// CoreSimulator.framework under `/Library/Developer`, which stays behind when
/// Xcode.app is trashed, and so do the simulator runtimes it manages. Someone who
/// deleted Xcode to free space is exactly who still has 25 GB of runtimes, so the
/// framework copy is the fallback whenever `xcrun` cannot find the tool.
nonisolated enum Simctl {
    static let xcrunPath = "/usr/bin/xcrun"
    static let frameworkPath =
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simctl"

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
        let resolved = resolveLauncher(fileManager: fileManager)
        launcherLock.lock()
        resolution = .resolved(resolved)
        launcherLock.unlock()
        return resolved
    }

    private static func resolveLauncher(fileManager: FileManager) -> Launcher? {
        if fileManager.isExecutableFile(atPath: xcrunPath),
           let found = ProcessRunner.run(
               executablePath: xcrunPath,
               arguments: ["--find", "simctl"],
               timeout: findTimeout
           ),
           found.succeeded {
            return .xcrun
        }
        if fileManager.isExecutableFile(atPath: frameworkPath) {
            return .framework
        }
        return nil
    }

    /// Runs `simctl <arguments>` and returns its output, or `nil` when no `simctl`
    /// could be launched. Blocks the calling thread like `ProcessRunner.run`.
    static func run(_ arguments: [String], timeout: TimeInterval) -> ProcessRunner.Output? {
        switch launcher() {
        case .xcrun:
            return ProcessRunner.run(
                executablePath: xcrunPath,
                arguments: ["simctl"] + arguments,
                timeout: timeout
            )
        case .framework:
            return ProcessRunner.run(
                executablePath: frameworkPath,
                arguments: arguments,
                timeout: timeout
            )
        case nil:
            return nil
        }
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
