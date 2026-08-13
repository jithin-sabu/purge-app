import AppKit
import SwiftUI

enum AppWindowID {
    static let main = "purge.main"
}

/// Opens Purge's window from the menu bar, whether or not one still exists.
///
/// `MainWindowLocator` can raise a window that is closed, minimised, or on
/// another Space, but it cannot bring back one that was never created — which is
/// exactly the state after a windowless launch in menu-bar-only mode. That gap
/// matters more than it sounds: Settings is a tab *inside* the window, so this is
/// the only route back to the toggle that turns the mode off.
@MainActor
enum AppWindowPresenter {

    /// Set from the `MenuBarExtra` label, which is rendered eagerly at launch and
    /// never torn down. Deliberately not the panel content — with
    /// `.menuBarExtraStyle(.window)` that isn't built until the user first opens
    /// the panel, which would leave this nil for anything reaching `reveal()`
    /// beforehand (opening Purge from Spotlight, say).
    private static var openWindowAction: OpenWindowAction?

    static func registerOpenWindowAction(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    /// Whether a window has to be built rather than raised.
    static func needsNewWindow(windows: [NSWindow]) -> Bool {
        MainWindowLocator.appWindow(in: windows) == nil
    }

    static func reveal() {
        guard needsNewWindow(windows: NSApp.windows) else {
            // The common path, unchanged: SwiftUI keeps a user-closed window in
            // `NSApp.windows`, so this covers closed, minimised, and off-Space.
            MainWindowLocator.revealAppWindow()
            return
        }
        guard let openWindowAction else {
            // Nothing better available; at least bring the app forward.
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openWindowAction(id: AppWindowID.main)
        // A new window from an accessory app routinely arrives behind the
        // frontmost app, and it does not exist yet this turn.
        onNextRunloopTurn {
            MainWindowLocator.revealAppWindow()
        }
    }
}
