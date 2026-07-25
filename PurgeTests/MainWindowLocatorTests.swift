import AppKit
import Foundation
import Testing
@testable import Purge

/// Covers the "Open Purge" menu item, which silently did nothing whenever the
/// app's window was closed or parked on another Space.
@MainActor
@Suite("MainWindowLocator finds the app window in every state")
struct MainWindowLocatorTests {

    /// Mirrors the real SwiftUI window: `.hiddenTitleBar` keeps `.titled` and
    /// adds `.fullSizeContentView` (observed styleMask 32783).
    private static func makeAppWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
    }

    /// Mirrors `NSStatusBarWindow` / `_NSGlassTrackingWindow`: borderless.
    private static func makeStatusBarStyleWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
    }

    /// Mirrors `MenuBarExtraWindow`, which is an `NSPanel`.
    private static func makeMenuBarPanel() -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
    }

    @Test
    func titledWindowIsRecognisedAsTheAppWindow() {
        #expect(MainWindowLocator.isAppWindow(Self.makeAppWindow()))
    }

    @Test
    func menuBarChromeIsNotMistakenForTheAppWindow() {
        #expect(!MainWindowLocator.isAppWindow(Self.makeStatusBarStyleWindow()))
        #expect(!MainWindowLocator.isAppWindow(Self.makeMenuBarPanel()))
    }

    /// Regression: the previous implementation filtered on `canBecomeMain`.
    /// A window that is not on screen reports `canBecomeMain == false` — which
    /// is exactly the state after the user closes the window — so the filter
    /// matched nothing and "Open Purge" did nothing at all. `.titled` holds in
    /// both states.
    @Test
    func offScreenAppWindowIsStillFoundEvenThoughItCannotBecomeMain() {
        let window = Self.makeAppWindow()
        #expect(!window.isVisible)
        #expect(!window.canBecomeMain, "precondition: this is the state that broke the old filter")
        #expect(MainWindowLocator.isAppWindow(window))
    }

    @Test
    func appWindowIsPickedOutOfMenuBarChrome() {
        let appWindow = Self.makeAppWindow()
        // Menu-bar windows deliberately come first: `NSApp.windows` ordering is
        // not guaranteed, so selection must not depend on position.
        let windows: [NSWindow] = [
            Self.makeStatusBarStyleWindow(),
            Self.makeMenuBarPanel(),
            Self.makeStatusBarStyleWindow(),
            appWindow,
        ]
        #expect(MainWindowLocator.appWindow(in: windows) === appWindow)
    }

    @Test
    func noAppWindowYieldsNil() {
        let windows: [NSWindow] = [
            Self.makeStatusBarStyleWindow(),
            Self.makeMenuBarPanel(),
        ]
        #expect(MainWindowLocator.appWindow(in: windows) == nil)
    }

    /// Without `.moveToActiveSpace` a window restored onto another Space stays
    /// there when the app is activated, so the menu item appears to do nothing.
    @Test
    func prepareForRevealOptsTheWindowIntoFollowingTheUser() {
        let window = Self.makeAppWindow()
        #expect(!window.collectionBehavior.contains(.moveToActiveSpace))

        MainWindowLocator.prepareForReveal(window)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
    }

    /// SwiftUI sets `primary` and `fullScreenNone` on this window (observed mask
    /// 66048). Revealing it must add a bit, not replace the mask.
    @Test
    func prepareForRevealPreservesExistingCollectionBehavior() {
        let window = Self.makeAppWindow()
        window.collectionBehavior = [.primary, .fullScreenNone]

        MainWindowLocator.prepareForReveal(window)

        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(window.collectionBehavior.contains(.primary))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
    }

    @Test
    func prepareForRevealIsIdempotent() {
        let window = Self.makeAppWindow()
        MainWindowLocator.prepareForReveal(window)
        let afterFirst = window.collectionBehavior

        MainWindowLocator.prepareForReveal(window)
        #expect(window.collectionBehavior == afterFirst)
    }
}
