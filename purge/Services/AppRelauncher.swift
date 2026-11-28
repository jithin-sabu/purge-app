import AppKit
import Foundation

/// Quits Purge and opens it again, for the Language row (#465).
///
/// The quit goes through `NSApp.terminate`, so `CleaningQuitGuard` still asks
/// before a clean is cut off. Purge is opened again only from
/// `applicationWillTerminate`, once the quit is certain: a quit the person
/// cancels opens nothing later. A small shell waits for this process to end,
/// then opens the bundle, so the new copy never runs beside the old one.
///
/// macOS doesn't bring forward an app opened by a process that isn't in front,
/// so the new copy is passed `launchArgument` and reveals its own window.
@MainActor
enum AppRelauncher {
    /// Set while a relaunch quit is under way.
    private(set) static var isRelaunchRequested = false

    /// Marks the copy the relaunch opens. Only an argument, so nothing is saved
    /// and a relaunch that never happens leaves nothing behind.
    nonisolated static let launchArgument = "-purge.relaunchedFromSettings"

    /// True when this copy was opened by a relaunch.
    nonisolated static var launchedByRelaunch: Bool {
        isRelaunch(arguments: ProcessInfo.processInfo.arguments)
    }

    nonisolated static func isRelaunch(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(launchArgument)
    }

    static func relaunch() {
        isRelaunchRequested = true
        NSApp.terminate(nil)
        // Only reached when the quit was cancelled.
        isRelaunchRequested = false
    }

    /// Called from `applicationWillTerminate`.
    static func openAgainIfRequested() {
        guard isRelaunchRequested else { return }
        // Uninstall Purge moved the app to the Trash; nothing to open.
        guard !SelfUninstallState.clearsDefaultsOnQuit else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = waiterArguments(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundlePath: Bundle.main.bundleURL.path
        )
        try? process.run()
    }

    /// `sh -c` with the pid and path as arguments, never pasted into the
    /// script. Waits up to 20 s for the pid to go, in case it is never freed,
    /// then opens the bundle with `launchArgument`.
    nonisolated static func waiterArguments(pid: Int32, bundlePath: String) -> [String] {
        let script = """
            i=0
            while /bin/kill -0 "$0" 2>/dev/null && [ "$i" -lt 200 ]; do /bin/sleep 0.1; i=$((i + 1)); done
            exec /usr/bin/open "$1" --args "$2"
            """
        return ["-c", script, String(pid), bundlePath, launchArgument]
    }
}
