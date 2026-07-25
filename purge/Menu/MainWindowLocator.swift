import AppKit

/// Finds and reveals Purge's real window from the menu bar.
///
/// Purge keeps several `NSWindow`s alive at once: the SwiftUI `WindowGroup`
/// window, one `NSStatusBarWindow` per status item, the `MenuBarExtraWindow`
/// panel, and AppKit's glass tracking window. Only the first is the app.
enum MainWindowLocator {

    /// Whether `window` is the app's own window rather than a menu-bar panel.
    ///
    /// Deliberately **not** `canBecomeMain`. A SwiftUI window the user has
    /// closed stays in `NSApp.windows` but reports `canBecomeMain == false`, so
    /// a `canBecomeMain` filter silently matches nothing and "Open Purge" does
    /// nothing at all. `.titled` is set in both the open and closed state, and
    /// none of the status-bar or MenuBarExtra panels carry it.
    @MainActor
    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
    }

    @MainActor
    static func appWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first(where: isAppWindow)
    }

    /// Brings the app's window to the user, wherever it currently is.
    ///
    /// Activation alone is not enough in two cases that both look identical to
    /// the user — the menu item appears to do nothing:
    ///
    /// - the window was restored onto a **different Space**, which does not
    ///   follow app activation on its own (unless the user enabled Mission
    ///   Control's "switch to a Space with open windows"), and
    /// - the window is **minimized**, which `makeKeyAndOrderFront` will not undo.
    ///
    /// `.moveToActiveSpace` is left set rather than toggled back: for a menu bar
    /// utility, the window following you to the Space you invoked it from is the
    /// behavior you want every time, not just the first.
    /// Makes `window` willing to follow the user, without disturbing the
    /// collection-behavior bits SwiftUI already set (`primary`,
    /// `fullScreenNone`) — hence `insert` rather than assignment.
    @MainActor
    static func prepareForReveal(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
    }

    @MainActor
    static func revealAppWindow() {
        guard let window = appWindow(in: NSApp.windows) else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        prepareForReveal(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
