import AppKit

/// Starts Purge windowless when it was launched at login in menu-bar-only mode.
///
/// SwiftUI has no way to decline creating a `WindowGroup`'s first window before
/// macOS 15, so the window is closed instead of prevented. That can show for a
/// frame on older systems — accepted, since the alternative is a window in the
/// user's face at every login.
///
/// Strictly bounded on purpose. A standing observer that closed app windows
/// would fight the user's own "Open Purge" a moment later; this runs for a
/// couple of runloop turns and then never again.
@MainActor
enum InitialWindowSuppressor {

    /// Closes the launch window now and for the next turn or two, in case SwiftUI
    /// creates it slightly after `applicationDidFinishLaunching`.
    static func suppressInitialWindow() {
        closeAppWindows()
        scheduleClose(remaining: 2)
    }

    private static func scheduleClose(remaining: Int) {
        guard remaining > 0 else { return }
        onNextRunloopTurn {
            closeAppWindows()
            scheduleClose(remaining: remaining - 1)
        }
    }

    private static func closeAppWindows() {
        for window in NSApp.windows where MainWindowLocator.isAppWindow(window) {
            window.close()
        }
    }
}
