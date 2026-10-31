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

    /// What one run of `xcode-select -p` said.
    enum Lookup: Equatable {
        /// A developer directory with the tools in it.
        case found(String)
        /// None is selected, or the selected one is gone or has no tools.
        case missing
        /// `xcode-select` could not be launched or did not answer in time. Says
        /// nothing about the Mac, so it is never cached.
        case unanswered
    }

    /// The real `xcrun` inside a developer directory. Its presence is the check,
    /// not the directory's: a trashed Xcode leaves its path selected, and a
    /// Command Line Tools folder a macOS upgrade emptied is still a folder.
    static func toolsPath(in directory: String) -> String {
        directory + "/usr/bin/xcrun"
    }

    /// The selected developer directory, when its tools exist on disk. `nil` on
    /// a Mac with neither Xcode nor the Command Line Tools, or whose selected
    /// Xcode was deleted. Blocks the calling thread like `ProcessRunner.run`:
    /// call it off the main actor.
    static func active() -> String? {
        shared.active(
            launch: { ProcessRunner.run(executablePath: $0, arguments: $1, timeout: $2) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

    /// Whether a `/usr/bin` shim can be launched without the install prompt.
    static var exists: Bool { active() != nil }

    /// One `xcode-select -p` run, with the process launch and the executable
    /// check handed in, so tests can check what each answer leads to.
    static func resolve(
        launch: (_ executablePath: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output?,
        isExecutable: (_ path: String) -> Bool
    ) -> Lookup {
        guard let output = launch(xcodeSelectPath, ["-p"], timeout), !output.timedOut else { return .unanswered }
        guard output.status == 0 else { return .missing }
        let path = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, isExecutable(toolsPath(in: path)) else { return .missing }
        return .found(path)
    }

    private static let shared = Cache()

    /// Remembers a definite answer for the rest of the process. An unanswered
    /// lookup is asked again next time: caching it would turn one slow cold start
    /// into "no developer tools" until Purge quits, and with it every git status
    /// into "unknown", which skips the uncommitted-changes confirmation a dirty
    /// project gets. A found directory is checked on disk again at every call,
    /// because Purge's own uninstaller can trash Xcode while Purge runs, and the
    /// shims then prompt for the path left behind.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: Lookup?

        init() {}

        func active(
            launch: (_ executablePath: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output?,
            isExecutable: (_ path: String) -> Bool
        ) -> String? {
            lock.lock()
            let known = cached
            lock.unlock()

            let lookup: Lookup
            if let known {
                lookup = known
            } else {
                // Resolved outside the lock: `xcode-select` is a child process, and
                // the scanner and the git checks may both ask on cold start.
                lookup = DeveloperDirectory.resolve(launch: launch, isExecutable: isExecutable)
                if lookup != .unanswered {
                    lock.lock()
                    cached = lookup
                    lock.unlock()
                }
            }

            switch lookup {
            case .found(let path):
                return isExecutable(DeveloperDirectory.toolsPath(in: path)) ? path : nil
            case .missing, .unanswered:
                return nil
            }
        }
    }
}
