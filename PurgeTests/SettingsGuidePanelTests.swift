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
        panel.show(.removeProfile) { store.cancelWaiting() }
        panel.show(.allowInBackground) {}
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
        var cancels = 0
        panel.show(.allowInBackground) { cancels += 1 }
        panel.show(.allowInBackground) { cancels += 1 }
        defer { panel.hide() }
        #expect(cancels == 0)
        #expect(panel.shown == .allowInBackground)
    }

    /// Each flow hides only its own guide.
    @Test func eachFlowHidesOnlyItsOwnGuide() {
        let panel = SettingsGuidePanel()
        panel.show(.allowInBackground) {}
        defer { panel.hide() }

        panel.hide(.installProfile)
        panel.hide(.removeProfile)
        #expect(panel.shown == .allowInBackground)

        panel.hide(.allowInBackground)
        #expect(panel.shown == nil)
    }

    /// A finished guide is no longer the one shown, so its owner's later hide
    /// and another flow's show both behave as if it were gone.
    @Test func finishingAGuideClearsIt() {
        let panel = SettingsGuidePanel()
        var cancels = 0
        panel.show(.fullDiskAccess) { cancels += 1 }
        defer { panel.hide() }
        panel.finish(.fullDiskAccess)
        #expect(panel.shown == nil)
        panel.show(.installProfile) {}
        #expect(cancels == 0)
    }

    /// One flow can't finish another's guide.
    @Test func finishingAnotherGuideDoesNothing() {
        let panel = SettingsGuidePanel()
        panel.show(.allowInBackground) {}
        defer { panel.hide() }
        panel.finish(.fullDiskAccess)
        panel.finish(.removeProfile)
        #expect(panel.shown == .allowInBackground)
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

    @Test func topRightCornerWithNoWindow() {
        let placement = SettingsGuidePanel.placement(panelSize: size, window: nil, visible: visible, gap: 8)
        #expect(placement.origin == NSPoint(x: 1292, y: 792))
        #expect(placement.pointer == .none)
    }
}
