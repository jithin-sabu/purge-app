import Darwin
import Foundation

/// Stops a command-line tool's background job before its folder goes (#225),
/// the way the uninstaller quits an app before removing it. Only the jobs the
/// scan paired with the folder are ever stopped, in the user's own launchd
/// domain, with no password.
nonisolated enum LaunchAgentStopper {
    nonisolated enum Outcome: Equatable, Sendable {
        case stopped
        /// launchd had no such job loaded, so there was nothing to stop.
        case notLoaded
        case failed(String)
    }

    typealias Runner = @Sendable (_ executablePath: String, _ arguments: [String]) -> ProcessRunner.Output?

    static let launchctlPath = "/bin/launchctl"

    /// `launchctl bootout` answers 3 ("No such process") for a job that is not
    /// loaded; `print` answers 113 for one it cannot find.
    static let notLoadedStatuses: Set<Int32> = [3, 113]

    static func stop(label: String, uid: uid_t = getuid(), runner: Runner = liveRunner) -> Outcome {
        guard let output = runner(launchctlPath, ["bootout", "gui/\(uid)/\(label)"]) else {
            return .failed(String(localized: "Purge couldn't run launchctl."))
        }
        if output.succeeded { return .stopped }
        if !output.timedOut, notLoadedStatuses.contains(output.status) { return .notLoaded }
        let message = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? String(localized: "launchctl stopped with an error.") : message)
    }

    /// Starts a job Purge stopped again, from its plist, when the removal it
    /// was stopped for did not go ahead. True when launchd took it.
    static func start(plist: URL, uid: uid_t = getuid(), runner: Runner = liveRunner) -> Bool {
        runner(launchctlPath, ["bootstrap", "gui/\(uid)", plist.path])?.succeeded == true
    }

    static let liveRunner: Runner = { path, arguments in
        ProcessRunner.run(executablePath: path, arguments: arguments, timeout: 15)
    }
}
