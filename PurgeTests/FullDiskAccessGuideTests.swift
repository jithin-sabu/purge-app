import Foundation
import Testing
@testable import Purge

/// Every Full Disk Access ask waits through one guide (#450). A grant runs each
/// caller's follow-up once; a cancel or a replaced guide runs none.
@Suite("The Full Disk Access guide waits for the grant")
@MainActor
struct FullDiskAccessGuideTests {
    /// A probe the test flips, read from the guide's background checks.
    private final class Access: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var granted: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private func makeGuide(panel: SettingsGuidePanel, access: Access, limit: TimeInterval = 60) -> (FullDiskAccessGuide, () -> Int) {
        var opens = 0
        let guide = FullDiskAccessGuide(
            panel: panel,
            probe: { access.granted },
            openPane: { opens += 1 },
            pollInterval: .milliseconds(20),
            limit: limit
        )
        return (guide, { opens })
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aGrantRunsEachFollowUpOnceAndClosesTheGuide() async {
        let panel = SettingsGuidePanel()
        defer { panel.hide() }
        let access = Access()
        let (guide, opens) = makeGuide(panel: panel, access: access)
        var first = 0
        var second = 0
        guide.open { first += 1 }
        guide.open { second += 1 }
        #expect(opens() == 2)
        #expect(panel.shown == .fullDiskAccess)
        #expect(guide.isWaiting)

        access.granted = true
        await settle { !guide.isWaiting }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(first == 1)
        #expect(second == 1)
        #expect(panel.shown == nil)
    }

    @Test func cancelEndsTheWaitWithoutAGrant() async {
        let panel = SettingsGuidePanel()
        defer { panel.hide() }
        let access = Access()
        let (guide, _) = makeGuide(panel: panel, access: access)
        var granted = 0
        let request = guide.open { granted += 1 }
        guide.cancel(request)
        #expect(!guide.isWaiting)
        #expect(panel.shown == nil)

        access.granted = true
        try? await Task.sleep(for: .milliseconds(100))
        #expect(granted == 0)
    }

    /// Another flow's guide takes the panel: this wait stops, as Not Now stops it.
    @Test func aReplacedGuideStopsTheWait() async {
        let panel = SettingsGuidePanel()
        defer { panel.hide() }
        let access = Access()
        let (guide, _) = makeGuide(panel: panel, access: access)
        var granted = 0
        let other = NSObject()
        guide.open { granted += 1 }
        panel.show(.removeProfile, owner: other) {}
        #expect(!guide.isWaiting)

        access.granted = true
        try? await Task.sleep(for: .milliseconds(100))
        #expect(granted == 0)
        #expect(panel.shown == .removeProfile)
    }

    @Test func theWaitGivesUp() async {
        let panel = SettingsGuidePanel()
        defer { panel.hide() }
        let access = Access()
        let (guide, _) = makeGuide(panel: panel, access: access, limit: 0.1)
        guide.open()
        await settle { !guide.isWaiting }
        #expect(!guide.isWaiting)
        #expect(panel.shown == nil)
    }

    /// Cancelling with nothing waiting leaves another flow's guide alone.
    @Test func cancelWithNoWaitTouchesNothing() {
        let panel = SettingsGuidePanel()
        defer { panel.hide() }
        let (guide, _) = makeGuide(panel: panel, access: Access())
        let other = NSObject()
        panel.show(.allowInBackground, owner: other) {}
        guide.cancel(FullDiskAccessGuide.Request())
        #expect(panel.shown == .allowInBackground)
    }

    /// The failure card closing ends only its own request. Look Deeper's wait
    /// goes on, and a grant runs Look Deeper's follow-up but not the card's.
    @Test func cancellingOneRequestKeepsTheOther() async {
        let panel = SettingsGuidePanel()
        defer { panel.hide() }
        let access = Access()
        let (guide, _) = makeGuide(panel: panel, access: access)
        var lookDeeper = 0
        var card = 0
        guide.open { lookDeeper += 1 }
        let cardRequest = guide.open { card += 1 }
        guide.cancel(cardRequest)
        #expect(guide.isWaiting)
        #expect(panel.shown == .fullDiskAccess)

        access.granted = true
        await settle { !guide.isWaiting }
        #expect(lookDeeper == 1)
        #expect(card == 0)
    }
}
