import Foundation

/// The developer directory `xcode-select` points at, read once per process.
///
/// `/usr/bin/xcrun`, `/usr/bin/git` and the other developer tools in `/usr/bin`
/// are shims. When no developer directory exists, or the one selected is gone,
/// running one does not fail: macOS shows "The 'xcrun' command requires the
/// command line developer tools. Would you like to install the tools now?", and
/// shows it again at the next launch (#298). `/usr/bin/xcode-select` is not a
/// shim. `xcode-select -p` prints the directory, or exits 2 when there is none,
/// and never asks. So every launch of a `/usr/bin` shim goes through `exists`
/// first.
nonisolated enum DeveloperDirectory {
    static let xcodeSelectPath = "/usr/bin/xcode-select"

    /// `xcode-select -p` reads one file; past this something is wedged.
    private static let timeout: TimeInterval = 10

    private enum Resolution {
        case unresolved
        case resolved(String?)
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var resolution: Resolution = .unresolved

    /// The selected developer directory, when it exists on disk. `nil` on a Mac
    /// with neither Xcode nor the Command Line Tools, or whose selected Xcode was
    /// deleted. Blocks the calling thread like `ProcessRunner.run`: call it off
    /// the main actor.
    static func active() -> String? {
        lock.lock()
        if case .resolved(let cached) = resolution {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Resolved outside the lock: `xcode-select` is a child process, and the
        // scanner and the git checks may both ask on cold start.
        let resolved = resolve(
            launch: { ProcessRunner.run(executablePath: $0, arguments: $1, timeout: $2) },
            isDirectory: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        )
        lock.lock()
        resolution = .resolved(resolved)
        lock.unlock()
        return resolved
    }

    /// Whether a `/usr/bin` shim can be launched without the install prompt.
    static var exists: Bool { active() != nil }

    /// `active` with the process launch and the directory check handed in, so
    /// tests can check what each answer from `xcode-select` leads to.
    static func resolve(
        launch: (_ executablePath: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output?,
        isDirectory: (_ path: String) -> Bool
    ) -> String? {
        guard let output = launch(xcodeSelectPath, ["-p"], timeout), output.succeeded else { return nil }
        let path = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A selected Xcode that was trashed leaves its path behind, and the shims
        // ask to install the tools for it just as they do for no path at all.
        guard !path.isEmpty, isDirectory(path) else { return nil }
        return path
    }
}
