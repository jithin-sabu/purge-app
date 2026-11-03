import AppKit

/// Stand-ins for the windows the app and the menu bar make, for tests that pick
/// the app's window out from among them.
@MainActor
enum WindowFixtures {
    /// Mirrors the real SwiftUI window: `.hiddenTitleBar` keeps `.titled` and
    /// adds `.fullSizeContentView` (observed styleMask 32783).
    static func appWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
    }

    /// Mirrors `NSStatusBarWindow` / `_NSGlassTrackingWindow`: borderless.
    static func statusBarStyleWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
    }

    /// Mirrors `MenuBarExtraWindow`, which is an `NSPanel`.
    static func menuBarPanel() -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
    }
}
