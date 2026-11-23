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

        /// Held until the test ends the modal, as the real run loop holds it.
        private var waitingForModal: [() -> Void] = []

        func afterModalEnds(_ work: @escaping () -> Void) { waitingForModal.append(work) }

        func endModal() {
            isShowingModal = false
            let work = waitingForModal
            waitingForModal = []
            work.forEach { $0() }
        }
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

    /// The watcher's link opens Purge, which macOS answers by making it a regular
    /// app (#438). Hiding the Dock icon again there must not bring back a window
    /// the user closed: SwiftUI keeps a closed window, so it counts as revealable.
    @Test("Hiding again after an open leaves a closed window closed")
    func hidingWithoutRevealLeavesTheWindowAlone() {
        let host = FakeHost()

        DockIconPolicy.apply(hidesDockIcon: true, revealsWindow: false, host: host)

        #expect(host.calls == [.setPolicy(.accessory)])
    }

    /// A reopen is the user asking for the window, so it keeps the reveal.
    @Test("Hiding again after a reopen still re-fronts the window")
    func hidingWithRevealAfterReopen() {
        let host = FakeHost()

        DockIconPolicy.apply(hidesDockIcon: true, revealsWindow: true, host: host)

        #expect(host.calls == [.setPolicy(.accessory), .reveal])
    }

    /// An open can arrive while the cleaning alert is up (#438). The policy must
    /// not change under the alert, and must change once it closes, or the Dock
    /// icon stays after Keep Cleaning.
    @Test("An open during a modal alert hides the Dock icon once the alert closes")
    func restoreWaitsForTheModalToEnd() {
        let host = FakeHost()
        host.isShowingModal = true

        DockIconPolicy.restoreAfterOpen(revealsWindow: false, host: host) { true }
        #expect(host.calls.isEmpty)

        host.endModal()
        #expect(host.calls == [.setPolicy(.accessory)])
    }

    /// The setting may change while the alert is up; the value applied is the
    /// one in effect when it closes.
    @Test("The value applied after a modal is read when the modal ends")
    func restoreReadsTheValueAfterTheModal() {
        let host = FakeHost()
        host.isShowingModal = true
        var hides = true

        DockIconPolicy.restoreAfterOpen(revealsWindow: false, host: host) { hides }
        hides = false
        host.endModal()

        #expect(host.calls.isEmpty)
    }

    @Test("With no modal up, an open hides the Dock icon at once")
    func restoreWithoutAModalAppliesAtOnce() {
        let host = FakeHost()

        DockIconPolicy.restoreAfterOpen(revealsWindow: false, host: host) { true }

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
