import AppKit

/// Quits Purge when the user closes its window in on-demand mode.
///
/// Watches `NSWindow.willCloseNotification` instead of answering
/// `applicationShouldTerminateAfterLastWindowClosed`, for two reasons. AppKit
/// decides what "last window" means, and Purge keeps windows alive that are not
/// the app (status-bar windows, AppKit's glass tracking window; see
/// `MainWindowLocator`), so that callback may never arrive. And the callback
/// cannot say who closed the window.
///
/// That second part matters because Purge closes its own window in two places.
/// The initial-window suppressor closes it on a windowless launch, when the
/// deleted-apps watcher started Purge and a review may be about to appear; quitting
/// there would drop the review. The deleted-apps review closes the window it
/// opened once it is done, and decides for itself whether to quit. Both go
/// through `closeWithoutQuitting`.
@MainActor
enum WindowCloseQuitter {
    private static var purgeIsClosing = false
    private static var observer: NSObjectProtocol?

    /// Idempotent. Called from `AppBootstrapper`.
    static func start() {
        guard observer == nil else { return }
        // `queue: nil` runs the block synchronously inside `close()`, which is
        // what lets `purgeIsClosing` mark the close as Purge's own.
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window else { return }
                windowWillClose(window)
            }
        }
    }

    /// Closes `window` without it counting as the user closing Purge.
    static func closeWithoutQuitting(_ window: NSWindow) {
        let wasClosing = purgeIsClosing
        purgeIsClosing = true
        defer { purgeIsClosing = wasClosing }
        window.close()
    }

    /// Every term has to hold before a close quits the app.
    ///
    /// `closingIsOnScreenAppWindow` excludes sheets, alerts, menu bar panels, and
    /// SwiftUI tearing down a window that was already closed. `otherAppWindowOnScreen`
    /// covers a second window from File ▸ New Window.
    static func shouldQuit(
        showsMenuBarIcon: Bool,
        closedByPurge: Bool,
        closingIsOnScreenAppWindow: Bool,
        otherAppWindowOnScreen: Bool
    ) -> Bool {
        !showsMenuBarIcon && !closedByPurge && closingIsOnScreenAppWindow && !otherAppWindowOnScreen
    }

    private static func windowWillClose(_ window: NSWindow) {
        let quits = shouldQuit(
            showsMenuBarIcon: StartupPreferenceStore.persistedShowsMenuBarIcon(),
            closedByPurge: purgeIsClosing,
            closingIsOnScreenAppWindow: isOnScreenAppWindow(window),
            otherAppWindowOnScreen: NSApp.windows.contains { $0 !== window && isOnScreenAppWindow($0) }
        )
        guard quits else { return }

        // After the close finishes. Checked again in case something put a window
        // back up in between, such as a deleted-apps review arriving.
        onNextRunloopTurn {
            guard !NSApp.windows.contains(where: isOnScreenAppWindow) else { return }
            // Goes through `applicationShouldTerminate`, so a clean in progress
            // still gets its confirmation.
            NSApp.terminate(nil)
        }
    }

    private static func isOnScreenAppWindow(_ window: NSWindow) -> Bool {
        MainWindowLocator.isAppWindow(window)
            && window.sheetParent == nil
            && (window.isVisible || window.isMiniaturized)
    }
}
