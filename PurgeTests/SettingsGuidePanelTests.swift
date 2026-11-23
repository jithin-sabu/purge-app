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
}
