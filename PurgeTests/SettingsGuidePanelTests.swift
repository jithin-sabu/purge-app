import AppKit
import Foundation
import Testing
@testable import Purge

/// The Apple Intelligence profile flow and the deleted-apps watcher share one
/// System Settings guide panel (#447). One flow must never leave the other
/// waiting with no guide, and a guide that is replaced must stop its flow, not
/// move it on.
@Suite("Two flows share the System Settings guide without breaking each other")
@MainActor
struct SettingsGuidePanelTests {
    private let defaults = ThrowawayDefaults()

    /// The watcher's guide replaces the profile guide, so the profile flow is
    /// told it was cancelled. Its wait then ends at once, and a cancelled wait
    /// returns before any request to the asset service.
    @Test func aReplacedProfileGuideStopsTheProfileWait() async {
        let panel = SettingsGuidePanel()
        let store = AppleIntelligenceModelStore(defaults: defaults.defaults)
        let watcher = NSObject()
        panel.show(.removeProfile, owner: store) { store.cancelWaiting() }
        panel.show(.allowInBackground, owner: watcher) {}
        defer { panel.hide() }

        #expect(panel.shown == .allowInBackground)
        let start = Date()
        let removed = await store.waitUntil({ false }, limit: 3)
        #expect(!removed)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    /// Showing the same guide again is not a replacement: its owner keeps waiting.
    @Test func showingTheSameGuideAgainCancelsNothing() {
        let panel = SettingsGuidePanel()
        let owner = NSObject()
        var cancels = 0
        panel.show(.allowInBackground, owner: owner) { cancels += 1 }
        panel.show(.allowInBackground, owner: owner) { cancels += 1 }
        defer { panel.hide() }
        #expect(cancels == 0)
        #expect(panel.shown == .allowInBackground)
        #expect(panel.ownerCount == 1)
    }

    /// Each flow hides only its own guide.
    @Test func eachFlowHidesOnlyItsOwnGuide() {
        let panel = SettingsGuidePanel()
        let owner = NSObject()
        panel.show(.allowInBackground, owner: owner) {}
        defer { panel.hide() }

        panel.hide(.installProfile, owner: owner)
        panel.hide(.removeProfile, owner: owner)
        #expect(panel.shown == .allowInBackground)

        panel.hide(.allowInBackground, owner: owner)
        #expect(panel.shown == nil)
    }

    /// A finished guide is no longer the one shown, so its owner's later hide
    /// and another flow's show both behave as if it were gone.
    @Test func finishingAGuideClearsIt() {
        let panel = SettingsGuidePanel()
        let owner = NSObject()
        var cancels = 0
        panel.show(.fullDiskAccess, owner: owner) { cancels += 1 }
        defer { panel.hide() }
        panel.finish(.fullDiskAccess, owner: owner)
        #expect(panel.shown == nil)
        panel.show(.installProfile, owner: NSObject()) {}
        #expect(cancels == 0)
    }

    /// One flow can't finish another's guide.
    @Test func finishingAnotherGuideDoesNothing() {
        let panel = SettingsGuidePanel()
        let owner = NSObject()
        panel.show(.allowInBackground, owner: owner) {}
        defer { panel.hide() }
        panel.finish(.fullDiskAccess, owner: owner)
        panel.finish(.removeProfile, owner: owner)
        #expect(panel.shown == .allowInBackground)
    }

    // MARK: Two flows on one guide

    /// The helper and the deleted-apps watcher both wait on Allow in the
    /// Background. One giving up leaves the guide up for the other.
    @Test func oneOwnerHidingKeepsTheGuideForTheOther() {
        let panel = SettingsGuidePanel()
        let helper = NSObject()
        let watcher = NSObject()
        var cancels = 0
        panel.show(.allowInBackground, owner: watcher) { cancels += 1 }
        panel.show(.allowInBackground, owner: helper) { cancels += 1 }
        defer { panel.hide() }

        panel.hide(.allowInBackground, owner: helper)
        #expect(panel.shown == .allowInBackground)
        #expect(panel.ownerCount == 1)
        #expect(cancels == 0)

        panel.hide(.allowInBackground, owner: helper)
        #expect(panel.ownerCount == 1)

        panel.hide(.allowInBackground, owner: watcher)
        #expect(panel.shown == nil)
    }

    /// One owner's change landing does not finish the guide while the other
    /// still waits; the last one does.
    @Test func theGuideFinishesWithItsLastOwner() {
        let panel = SettingsGuidePanel()
        let helper = NSObject()
        let watcher = NSObject()
        panel.show(.allowInBackground, owner: watcher) {}
        panel.show(.allowInBackground, owner: helper) {}
        defer { panel.hide() }

        panel.finish(.allowInBackground, owner: helper)
        #expect(panel.shown == .allowInBackground)
        #expect(panel.ownerCount == 1)

        panel.finish(.allowInBackground, owner: watcher)
        #expect(panel.shown == nil)
    }

    /// A flow that went away without hiding never holds the guide open for
    /// the one still there.
    @Test func aGoneOwnerDoesNotHoldTheGuide() {
        let panel = SettingsGuidePanel()
        let helper = NSObject()
        do {
            let watcher = NSObject()
            panel.show(.allowInBackground, owner: watcher) {}
        }
        panel.show(.allowInBackground, owner: helper) {}
        defer { panel.hide() }
        #expect(panel.ownerCount == 1)

        panel.hide(.allowInBackground, owner: helper)
        #expect(panel.shown == nil)
    }

    /// Another guide replacing a shared one tells every owner, so neither keeps
    /// waiting with no guide.
    @Test func replacingASharedGuideCancelsEveryOwner() {
        let panel = SettingsGuidePanel()
        let watcher = NSObject()
        let helper = NSObject()
        let fullDiskAccess = NSObject()
        var cancelled: [String] = []
        panel.show(.allowInBackground, owner: watcher) { cancelled.append("watcher") }
        panel.show(.allowInBackground, owner: helper) { cancelled.append("helper") }
        defer { panel.hide() }

        panel.show(.fullDiskAccess, owner: fullDiskAccess) {}
        #expect(cancelled == ["watcher", "helper"])
        #expect(panel.shown == .fullDiskAccess)
        #expect(panel.ownerCount == 1)
    }
}

/// Where the panel goes beside System Settings, and which edge its pointer is on.
@Suite("The guide sits beside System Settings and points at it")
struct SettingsGuidePlacementTests {
    private let visible = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    private let size = NSSize(width: 300, height: 200)

    @Test func toTheRightWhenThereIsRoom() {
        let window = NSRect(x: 200, y: 300, width: 700, height: 600)
        let placement = SettingsGuidePanel.placement(panelSize: size, window: window, visible: visible, gap: 8)
        #expect(placement.origin == NSPoint(x: 908, y: 700))
        #expect(placement.pointer == .leading)
    }

    @Test func toTheLeftWhenTheRightIsFull() {
        let window = NSRect(x: 700, y: 300, width: 800, height: 600)
        let placement = SettingsGuidePanel.placement(panelSize: size, window: window, visible: visible, gap: 8)
        #expect(placement.origin == NSPoint(x: 392, y: 700))
        #expect(placement.pointer == .trailing)
    }

    @Test func belowWhenNeitherSideFits() {
        let window = NSRect(x: 100, y: 400, width: 1400, height: 500)
        let placement = SettingsGuidePanel.placement(panelSize: size, window: window, visible: visible, gap: 8)
        #expect(placement.origin == NSPoint(x: 100, y: 192))
        #expect(placement.pointer == .top)
    }

    /// Never off the bottom of the screen, even beside a short window low down.
    @Test func keptOnScreen() {
        let window = NSRect(x: 200, y: 0, width: 700, height: 150)
        let placement = SettingsGuidePanel.placement(panelSize: size, window: window, visible: visible, gap: 8)
        #expect(placement.origin.y == 0)
    }

    /// Below a window that runs off the left edge, the panel stays on screen.
    @Test func belowKeptOnScreenSideways() {
        let window = NSRect(x: -400, y: 400, width: 1900, height: 500)
        let placement = SettingsGuidePanel.placement(panelSize: size, window: window, visible: visible, gap: 8)
        #expect(placement.origin == NSPoint(x: 0, y: 192))
        #expect(placement.pointer == .top)
    }

    @Test func topRightCornerWithNoWindow() {
        let placement = SettingsGuidePanel.placement(panelSize: size, window: nil, visible: visible, gap: 8)
        #expect(placement.origin == NSPoint(x: 1292, y: 792))
        #expect(placement.pointer == .none)
    }
}
