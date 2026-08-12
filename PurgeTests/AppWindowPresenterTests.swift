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

    private static func makeAppWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
    }

    private static func makeStatusBarStyleWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
    }

    private static func makeMenuBarPanel() -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
    }

    @Test("An existing window is raised, never duplicated")
    func existingWindowIsRevealed() {
        let windows: [NSWindow] = [
            Self.makeStatusBarStyleWindow(),
            Self.makeAppWindow(),
        ]
        #expect(AppWindowPresenter.plan(windows: windows) == .reveal)
    }

    /// A window the user closed stays in `NSApp.windows`, so this must still be
    /// `.reveal` — opening a second one is the visible bug.
    @Test("A closed window still counts as one to raise")
    func closedWindowIsStillRevealable() {
        let window = Self.makeAppWindow()
        #expect(!window.isVisible)
        #expect(AppWindowPresenter.plan(windows: [window]) == .reveal)
    }

    /// The windowless-launch state: menu bar chrome only.
    @Test("Menu bar chrome alone means a window has to be created")
    func menuBarChromeAloneRequiresCreation() {
        let windows: [NSWindow] = [
            Self.makeStatusBarStyleWindow(),
            Self.makeMenuBarPanel(),
            Self.makeStatusBarStyleWindow(),
        ]
        #expect(AppWindowPresenter.plan(windows: windows) == .create)
    }

    @Test("No windows at all means a window has to be created")
    func emptyWindowListRequiresCreation() {
        #expect(AppWindowPresenter.plan(windows: []) == .create)
    }
}
