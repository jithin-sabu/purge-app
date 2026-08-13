import AppKit
import Foundation
import Testing
@testable import Purge

/// The ordering of these calls is the whole point of `DockIconPolicy` — get it
/// wrong and the window drops behind another app the moment the switch flips, or
/// the app menu bar fails to come back. None of it is observable through `NSApp`.
@MainActor
@Suite("DockIconPolicy switches activation policy in the right order")
struct DockIconPolicyTests {

    private final class FakeHost: ActivationPolicyHost {
        enum Call: Equatable {
            case setPolicy(NSApplication.ActivationPolicy)
            case reveal
        }

        var currentActivationPolicy: NSApplication.ActivationPolicy = .regular
        var isShowingModal = false
        var hasRevealableWindow = true
        var policyChangeSucceeds = true
        private(set) var calls: [Call] = []

        @discardableResult
        func setPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
            calls.append(.setPolicy(policy))
            guard policyChangeSucceeds else { return false }
            currentActivationPolicy = policy
            return true
        }

        func revealWindow() { calls.append(.reveal) }

        /// Synchronous so the test does not have to spin a runloop. The real hop
        /// is covered by manual verification, not here.
        func afterCurrentRunloopTurn(_ work: @escaping () -> Void) { work() }
    }

    @Test("Hiding the Dock icon switches to accessory, then re-fronts the open window")
    func hidingReordersTheWindowAfterTheSwitch() {
        let host = FakeHost()
        DockIconPolicy.apply(hidesDockIcon: true, host: host)

        #expect(host.calls == [.setPolicy(.accessory), .reveal])
    }

    /// Revealing here would pull focus to the app just to show the user nothing.
    @Test("Hiding with no window open changes policy and stops there")
    func hidingWithoutAWindowDoesNotReveal() {
        let host = FakeHost()
        host.hasRevealableWindow = false

        DockIconPolicy.apply(hidesDockIcon: true, host: host)

        #expect(host.calls == [.setPolicy(.accessory)])
    }

    /// Revealing activates even when there is no window, and that activation is
    /// what puts the app menu back at the top of the screen; without it the menu
    /// bar belongs to whatever app was frontmost.
    @Test("Showing the Dock icon again reveals even with no window")
    func showingAlwaysReveals() {
        let host = FakeHost()
        host.currentActivationPolicy = .accessory
        host.hasRevealableWindow = false

        DockIconPolicy.apply(hidesDockIcon: false, host: host)

        #expect(host.calls == [.setPolicy(.regular), .reveal])
    }

    @Test("Applying the policy already in effect does nothing at all")
    func alreadyInTargetPolicyIsANoOp() {
        let host = FakeHost()
        host.currentActivationPolicy = .accessory

        DockIconPolicy.apply(hidesDockIcon: true, host: host)

        #expect(host.calls.isEmpty)
    }

    @Test("A failed policy change leaves the windows alone")
    func failedPolicyChangeStopsBeforeTouchingWindows() {
        let host = FakeHost()
        host.policyChangeSucceeds = false

        DockIconPolicy.apply(hidesDockIcon: true, host: host)

        #expect(host.calls == [.setPolicy(.accessory)])
    }

    /// The cleaning confirmation runs a modal loop; changing policy underneath it
    /// can take the alert with it.
    @Test("Nothing happens while a modal is up")
    func modalBlocksThePolicyChange() {
        let host = FakeHost()
        host.isShowingModal = true

        DockIconPolicy.apply(hidesDockIcon: true, host: host)

        #expect(host.calls.isEmpty)
    }
}
