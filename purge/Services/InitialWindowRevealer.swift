import AppKit

/// Brings the launch window forward when the Dock icon is hidden (#428).
///
/// Purge turns into an accessory app before it finishes launching, and macOS
/// does not activate an accessory app that just started. The window then opens
/// behind the front app, or not on screen at all, with no Dock icon to click.
/// After Restart to Update that looks like Purge closed and never came back.
/// With the Dock icon shown, macOS activates the app by itself.
///
/// The opposite of `InitialWindowSuppressor`, and bounded the same way: it waits
/// a few runloop turns for SwiftUI to make the window, reveals it, tries again
/// twice if that did not hold, and never runs again.
@MainActor
enum InitialWindowRevealer {

    /// SwiftUI can make the first window a turn or two after launch finishes.
    private static let windowWaitTurns = 3

    /// When Purge starts right after it quit, as it does after an update or a
    /// Homebrew upgrade, the app macOS brought forward in between can take the
    /// front back within a second, more so when that app is on another Space.
    /// It did in about half of the test relaunches on a Mac with several
    /// Spaces, and the tries below settled every one of them.
    private static let retryDelays: [TimeInterval] = [1, 2.5]

    static func revealInitialWindow() {
        // The unit-test host shares the real defaults, and must not pull a
        // window forward on the developer's screen in the middle of a run.
        guard !TestHost.isActive() else { return }
        reveal(turnsLeft: windowWaitTurns)
    }

    private static func reveal(turnsLeft: Int) {
        onNextRunloopTurn {
            if AppWindowPresenter.needsNewWindow(windows: NSApp.windows), turnsLeft > 0 {
                reveal(turnsLeft: turnsLeft - 1)
                return
            }
            AppWindowPresenter.reveal()
            for delay in retryDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { revealAgainIfNotActive() }
                }
            }
        }
    }

    /// macOS may turn down a second request to activate while another app is
    /// in front. Ordering the window front needs no activation, so the window
    /// is at least on top where the user can see it.
    private static func revealAgainIfNotActive() {
        guard !NSApp.isActive else { return }
        AppWindowPresenter.reveal()
        MainWindowLocator.appWindow(in: NSApp.windows)?.orderFrontRegardless()
    }
}
