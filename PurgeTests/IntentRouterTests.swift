import Foundation
import Testing
@testable import Purge

/// The App Intents call into `IntentRouter`; these check what each one does to
/// the store and the window, with no window and no real defaults.
@MainActor
@Suite("App Intents route into the window")
struct IntentRouterTests {

    /// Counts reveals instead of touching `NSApp`.
    private final class RevealCounter {
        var count = 0
    }

    private static func makeRouter(
        store: PurgeStore,
        reveals: RevealCounter,
        onboardingDone: Bool = true
    ) -> IntentRouter {
        IntentRouter(store: store, reveal: { reveals.count += 1 }, onboardingDone: { onboardingDone })
    }

    private static func makeStore() -> PurgeStore {
        PurgeStore(defaults: UserDefaults(suiteName: "purge-tests-\(UUID().uuidString)")!)
    }

    @Test("The tab option covers the five scan tabs and nothing else")
    func tabOptionsMapToScanTabs() {
        let mapped = PurgeTabOption.allCases.map(\.tab)
        #expect(mapped == [.overview, .appCaches, .devTools, .largeFiles, .uninstaller])
        #expect(!mapped.contains(.settings))
        #expect(!mapped.contains(.about))
        #expect(PurgeTabOption.caseDisplayRepresentations.count == PurgeTabOption.allCases.count)
    }

    @Test("Opening a tab selects it and shows the window once")
    func openSelectsTabAndReveals() {
        let store = Self.makeStore()
        let reveals = RevealCounter()
        let router = Self.makeRouter(store: store, reveals: reveals)

        router.open(tab: .largeFiles)

        #expect(store.selectedTab == .largeFiles)
        #expect(reveals.count == 1)
    }

    @Test("Before onboarding is done the window opens but the tab is left alone")
    func openBeforeOnboardingOnlyReveals() {
        let store = Self.makeStore()
        let reveals = RevealCounter()
        let router = Self.makeRouter(store: store, reveals: reveals, onboardingDone: false)

        router.open(tab: .uninstaller)

        #expect(store.selectedTab == .overview)
        #expect(reveals.count == 1)
    }
}
