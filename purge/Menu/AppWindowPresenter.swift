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

    enum Plan: Equatable {
        /// A window object exists — raise it, and never open a second one.
        case reveal
        /// Nothing to raise; one has to be made.
        case create
    }

    /// Set by whichever view mounts first. `MenuBarExtra` content is enough on
    /// its own: the "Open Purge" row lives inside it, so by the time anyone can
    /// tap that row this has been set.
    private static var openWindowAction: OpenWindowAction?

    static func registerOpenWindowAction(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    static func plan(windows: [NSWindow]) -> Plan {
        MainWindowLocator.appWindow(in: windows) == nil ? .create : .reveal
    }

    static func reveal() {
        switch plan(windows: NSApp.windows) {
        case .reveal:
            // The common path, unchanged: SwiftUI keeps a user-closed window in
            // `NSApp.windows`, so this covers closed, minimised, and off-Space.
            MainWindowLocator.revealAppWindow()

        case .create:
            guard let openWindowAction else {
                // Nothing better available; at least bring the app forward.
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            openWindowAction(id: AppWindowID.main)
            // A new window from an accessory app routinely arrives behind the
            // frontmost app, and it does not exist yet this turn.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MainWindowLocator.revealAppWindow()
                }
            }
        }
    }
}
