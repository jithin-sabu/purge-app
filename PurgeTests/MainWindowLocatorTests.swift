import AppKit
import Foundation
import Testing
@testable import Purge

/// Covers the "Open Purge" menu item, which silently did nothing whenever the
/// app's window was closed or parked on another Space.
@MainActor
@Suite("MainWindowLocator finds the app window in every state")
struct MainWindowLocatorTests {

    @Test
    func titledWindowIsRecognisedAsTheAppWindow() {
        #expect(MainWindowLocator.isAppWindow(WindowFixtures.appWindow()))
    }

    @Test
    func menuBarChromeIsNotMistakenForTheAppWindow() {
        #expect(!MainWindowLocator.isAppWindow(WindowFixtures.statusBarStyleWindow()))
        #expect(!MainWindowLocator.isAppWindow(WindowFixtures.menuBarPanel()))
    }

    /// Regression: the previous implementation filtered on `canBecomeMain`.
    /// A window that is not on screen reports `canBecomeMain == false` — which
    /// is exactly the state after the user closes the window — so the filter
    /// matched nothing and "Open Purge" did nothing at all. `.titled` holds in
    /// both states.
    @Test
    func offScreenAppWindowIsStillFoundEvenThoughItCannotBecomeMain() {
        let window = WindowFixtures.appWindow()
        #expect(!window.isVisible)
        #expect(!window.canBecomeMain, "precondition: this is the state that broke the old filter")
        #expect(MainWindowLocator.isAppWindow(window))
    }

    @Test
    func appWindowIsPickedOutOfMenuBarChrome() {
        let appWindow = WindowFixtures.appWindow()
        // Menu-bar windows deliberately come first: `NSApp.windows` ordering is
        // not guaranteed, so selection must not depend on position.
        let windows: [NSWindow] = [
            WindowFixtures.statusBarStyleWindow(),
            WindowFixtures.menuBarPanel(),
            WindowFixtures.statusBarStyleWindow(),
            appWindow,
        ]
        #expect(MainWindowLocator.appWindow(in: windows) === appWindow)
    }

    /// `.titled` alone let Sparkle's update window or an alert stand in for
    /// Purge's own window (#183).
    @Test
    func otherTitledWindowsAreNotTheAppWindow() {
        #expect(!MainWindowLocator.isAppWindow(WindowFixtures.titledWindow()))
        #expect(!MainWindowLocator.isAppWindow(WindowFixtures.titledPanel()))
        let appWindow = WindowFixtures.appWindow()
        let windows: [NSWindow] = [WindowFixtures.titledWindow(), WindowFixtures.titledPanel(), appWindow]
        #expect(MainWindowLocator.appWindow(in: windows) === appWindow)
    }

    @Test
    func noAppWindowYieldsNil() {
        let windows: [NSWindow] = [
            WindowFixtures.statusBarStyleWindow(),
            WindowFixtures.menuBarPanel(),
        ]
        #expect(MainWindowLocator.appWindow(in: windows) == nil)
    }

    /// Without `.moveToActiveSpace` a window restored onto another Space stays
    /// there when the app is activated, so the menu item appears to do nothing.
    @Test
    func prepareForRevealOptsTheWindowIntoFollowingTheUser() {
        let window = WindowFixtures.appWindow()
        #expect(!window.collectionBehavior.contains(.moveToActiveSpace))

        MainWindowLocator.prepareForReveal(window)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
    }

    /// SwiftUI sets `primary` and `fullScreenNone` on this window (observed mask
    /// 66048). Revealing it must add a bit, not replace the mask.
    @Test
    func prepareForRevealPreservesExistingCollectionBehavior() {
        let window = WindowFixtures.appWindow()
        window.collectionBehavior = [.primary, .fullScreenNone]

        MainWindowLocator.prepareForReveal(window)

        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(window.collectionBehavior.contains(.primary))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
    }

    @Test
    func prepareForRevealIsIdempotent() {
        let window = WindowFixtures.appWindow()
        MainWindowLocator.prepareForReveal(window)
        let afterFirst = window.collectionBehavior

        MainWindowLocator.prepareForReveal(window)
        #expect(window.collectionBehavior == afterFirst)
    }
}
