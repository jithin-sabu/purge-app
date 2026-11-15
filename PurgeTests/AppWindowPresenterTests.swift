import AppKit
import Foundation
import Testing
@testable import Purge

/// With the Dock icon hidden, "Open Purge" is the only route back to the setting
/// that turns the mode off. If this decision goes wrong in the windowless case
/// the menu bar goes dead and the user is stuck.
@MainActor
@Suite("AppWindowPresenter decides between raising and creating a window")
struct AppWindowPresenterTests {

    @Test("An existing window is raised, never duplicated")
    func existingWindowIsRevealed() {
        let windows: [NSWindow] = [
            WindowFixtures.statusBarStyleWindow(),
            WindowFixtures.appWindow(),
        ]
        #expect(!AppWindowPresenter.needsNewWindow(windows: windows))
    }

    /// A window the user closed stays in `NSApp.windows`, so this must still be
    /// raised rather than rebuilt — opening a second one is the visible bug.
    @Test("A closed window still counts as one to raise")
    func closedWindowIsStillRevealable() {
        let window = WindowFixtures.appWindow()
        #expect(!window.isVisible)
        #expect(!AppWindowPresenter.needsNewWindow(windows: [window]))
    }

    /// The windowless-launch state: menu bar chrome only.
    @Test("Menu bar chrome alone means a window has to be created")
    func menuBarChromeAloneRequiresCreation() {
        let windows: [NSWindow] = [
            WindowFixtures.statusBarStyleWindow(),
            WindowFixtures.menuBarPanel(),
            WindowFixtures.statusBarStyleWindow(),
        ]
        #expect(AppWindowPresenter.needsNewWindow(windows: windows))
    }

    @Test("No windows at all means a window has to be created")
    func emptyWindowListRequiresCreation() {
        #expect(AppWindowPresenter.needsNewWindow(windows: []))
    }
}
