import Testing
@testable import Purge

@MainActor
@Suite("WindowCloseQuitter quits only when the user closes Purge in on-demand mode")
struct WindowCloseQuitterTests {

    @Test("Closing the only window on demand quits")
    func userCloseOnDemandQuits() {
        #expect(
            WindowCloseQuitter.shouldQuit(
                showsMenuBarIcon: false,
                closedByPurge: false,
                closingIsOnScreenAppWindow: true,
                otherAppWindowOnScreen: false
            )
        )
    }

    @Test("In the menu bar mode, closing the window keeps Purge running")
    func menuBarModeKeepsRunning() {
        #expect(
            !WindowCloseQuitter.shouldQuit(
                showsMenuBarIcon: true,
                closedByPurge: false,
                closingIsOnScreenAppWindow: true,
                otherAppWindowOnScreen: false
            )
        )
    }

    /// The watcher-launch case: the suppressor closes the first window, and a
    /// review may be about to open a new one.
    @Test("A window Purge closes itself never quits")
    func purgeCloseDoesNotQuit() {
        #expect(
            !WindowCloseQuitter.shouldQuit(
                showsMenuBarIcon: false,
                closedByPurge: true,
                closingIsOnScreenAppWindow: true,
                otherAppWindowOnScreen: false
            )
        )
    }

    @Test("Closing a sheet, panel, or already-closed window does not quit")
    func nonAppWindowDoesNotQuit() {
        #expect(
            !WindowCloseQuitter.shouldQuit(
                showsMenuBarIcon: false,
                closedByPurge: false,
                closingIsOnScreenAppWindow: false,
                otherAppWindowOnScreen: false
            )
        )
    }

    @Test("Closing one of two windows does not quit")
    func secondWindowKeepsRunning() {
        #expect(
            !WindowCloseQuitter.shouldQuit(
                showsMenuBarIcon: false,
                closedByPurge: false,
                closingIsOnScreenAppWindow: true,
                otherAppWindowOnScreen: true
            )
        )
    }
}
