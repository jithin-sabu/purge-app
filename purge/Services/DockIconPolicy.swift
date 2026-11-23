import AppKit

/// Runs `work` after the current runloop turn.
///
/// Load-bearing wherever it appears here. AppKit rebuilds the main menu and
/// redoes activation as part of an activation-policy change, and anything ordered
/// in the same turn gets undone — the visible symptom is the window dropping
/// behind whatever app is next in the stack the instant the switch is flipped.
/// The same hop is what lets a newly created window come forward, and what gives
/// SwiftUI a turn to materialise a scene before it is closed again.
@MainActor
func onNextRunloopTurn(_ work: @escaping () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated(work)
    }
}

/// The parts of `NSApplication` that switching the Dock icon on and off touches.
///
/// Exists so the call *ordering* below can be tested — the ordering is the whole
/// substance of this type, and none of it is observable through `NSApp` in a test.
@MainActor
protocol ActivationPolicyHost: AnyObject {
    var currentActivationPolicy: NSApplication.ActivationPolicy { get }
    var isShowingModal: Bool { get }
    var hasRevealableWindow: Bool { get }

    @discardableResult
    func setPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func revealWindow()
    func afterCurrentRunloopTurn(_ work: @escaping () -> Void)
    func afterModalEnds(_ work: @escaping () -> Void)
}

extension NSApplication: ActivationPolicyHost {
    var currentActivationPolicy: NSApplication.ActivationPolicy { activationPolicy() }
    var isShowingModal: Bool { modalWindow != nil }
    var hasRevealableWindow: Bool { MainWindowLocator.appWindow(in: windows) != nil }

    @discardableResult
    func setPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        setActivationPolicy(policy)
    }

    func revealWindow() {
        MainWindowLocator.revealAppWindow()
    }

    func afterCurrentRunloopTurn(_ work: @escaping () -> Void) {
        onNextRunloopTurn(work)
    }

    /// A modal alert runs the run loop in its own mode, so a block queued for the
    /// default mode waits until the alert has closed, then runs at once.
    func afterModalEnds(_ work: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated(work)
        }
    }
}

/// Shows or hides the Dock icon by flipping the app's activation policy.
///
/// `.accessory` is what "menu bar only" actually means: no Dock tile, no ⌘-Tab
/// entry, and no app menu bar along the top of the screen.
@MainActor
enum DockIconPolicy {
    /// `revealsWindow: false` changes the policy and stops there. The open route
    /// uses it (#438): the watcher's link must not bring back a window the user
    /// closed, because the deleted-apps review decides whether the window shows.
    /// `hasRevealableWindow` matches a closed window too, since SwiftUI keeps it.
    static func apply(hidesDockIcon: Bool, revealsWindow: Bool = true, host: ActivationPolicyHost) {
        let target: NSApplication.ActivationPolicy = hidesDockIcon ? .accessory : .regular

        // Re-applying the current policy makes the menu bar flicker for nothing.
        guard host.currentActivationPolicy != target else { return }
        // The cleaning alert runs its own modal loop; changing policy under it is a
        // good way to lose the alert. The Settings toggle isn't reachable during one,
        // so skipping is enough — the pref is persisted and applies on next launch.
        guard !host.isShowingModal else { return }
        guard host.setPolicy(target) else { return }
        guard revealsWindow else { return }

        // Hiding with no window open: nothing to bring forward, and activating would
        // steal focus to show the user nothing. Showing always reveals, because that
        // is what puts the app menu back at the top of the screen without a stray
        // extra click — `revealAppWindow` activates even when there is no window.
        if hidesDockIcon && !host.hasRevealableWindow { return }

        host.afterCurrentRunloopTurn {
            host.revealWindow()
        }
    }

    static func apply(hidesDockIcon: Bool, revealsWindow: Bool = true) {
        apply(hidesDockIcon: hidesDockIcon, revealsWindow: revealsWindow, host: NSApplication.shared)
    }

    /// Hides the Dock icon again after macOS brought it back (#438).
    ///
    /// When LaunchServices opens a copy that is already running, it makes the app
    /// a regular one: the watcher's `purge://` link, `open -a`, Spotlight and
    /// Finder all do it, and the Dock icon then stays until Purge quits. By the
    /// time the open or reopen callback runs, the switch has already happened,
    /// and setting the policy again there holds. Reads the store's live value, not
    /// the saved one, so a state that keeps the Dock icon on purpose keeps it.
    ///
    /// An open can arrive while the cleaning alert's modal loop runs. `apply`
    /// will not change the policy under the alert, so this waits until the alert
    /// closes, then reads the value again and applies it.
    static func restoreAfterOpen(
        revealsWindow: Bool,
        host: ActivationPolicyHost,
        hidesDockIcon: @escaping @MainActor () -> Bool
    ) {
        guard !host.isShowingModal else {
            host.afterModalEnds {
                restoreAfterOpen(revealsWindow: revealsWindow, host: host, hidesDockIcon: hidesDockIcon)
            }
            return
        }
        apply(hidesDockIcon: hidesDockIcon(), revealsWindow: revealsWindow, host: host)
    }

    static func restoreAfterOpen(revealsWindow: Bool) {
        restoreAfterOpen(revealsWindow: revealsWindow, host: NSApplication.shared) {
            StartupPreferenceStore.shared.hidesDockIcon
        }
    }
}
