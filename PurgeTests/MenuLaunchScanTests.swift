import Foundation
import Testing
@testable import Purge

/// The menu bar's scan at launch, and the launch that skips it (#177).
@MainActor
@Suite("Menu bar launch scan")
struct MenuLaunchScanTests {

    @Test("Attaching scans at launch")
    func attachScansAtLaunch() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let model = MenuViewModel()

        model.attach(store: store)

        #expect(await Self.eventually { fake.generalAccesses.count == 1 })
        fake.cleanUp()
    }

    /// A Purge the deleted-apps watcher started shows one review and quits, so
    /// it must not walk the disk first. The first menu open scans instead, so the
    /// menu never settles on numbers no scan produced.
    @Test("A watcher launch skips the scan, and the first menu open runs it")
    func watcherLaunchScansOnFirstMenuOpen() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let model = MenuViewModel()

        model.attach(store: store, scansAtLaunch: false)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fake.generalAccesses.isEmpty)
        #expect(model.state == .checking)

        model.menuDidOpen()
        #expect(await Self.eventually { fake.generalAccesses.count == 1 })
        #expect(await Self.eventually { model.state != .checking })
        fake.cleanUp()
    }

    /// A scan the window ran first is the launch scan: the model settles on its
    /// results by itself, and opening the menu after it shows them at once and
    /// starts no second scan. The scan is held open past the model's 200 ms
    /// debounce, so the model sees it in flight the way it sees a real one.
    @Test("A scan the window ran first counts as the launch scan")
    func windowScanCountsAsLaunchScan() async {
        let fake = FakeScans()
        fake.holdsGeneral = true
        let store = fake.makeStore()
        let model = MenuViewModel()
        model.attach(store: store, scansAtLaunch: false)

        store.requestScan(.cachesAndDevTools)
        // Held once the scan has reached the fake, so the release below has
        // something to release.
        #expect(await Self.eventually { fake.generalAccesses.count == 1 })
        try? await Task.sleep(for: .milliseconds(400))
        fake.finishHeldGeneral()
        #expect(await Self.eventually { store.hasSessionResults(for: .cachesAndDevTools) && !store.scanQueue.isRunning })
        #expect(await Self.eventually { model.state != .checking })

        model.menuDidOpen()
        // Had the skipped scan still been pending, this open would have gone back
        // to checking and started a scan of its own.
        #expect(model.state != .checking)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fake.generalAccesses.count == 1)
        fake.cleanUp()
    }

    /// Counts only the time this loop was running, as `IntentRouterTests` does:
    /// on CI the test host can stall with every suite waiting.
    private static func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
        var waited: TimeInterval = 0
        var last = Date()
        while !condition() {
            guard waited < timeout else { return false }
            try? await Task.sleep(for: .milliseconds(10))
            let now = Date()
            waited += min(now.timeIntervalSince(last), 0.25)
            last = now
        }
        return true
    }
}
