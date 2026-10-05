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

    // MARK: Scan my Mac

    @Test("Scanning while idle runs the limited scan without Full Disk Access")
    func scanWhileIdleWithoutAccess() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let reveals = RevealCounter()
        let router = Self.makeRouter(store: store, reveals: reveals)

        let outcome = await router.scanMac()

        #expect(outcome == .scanned(safeBytes: 0))
        #expect(fake.generalAccesses == [.limited])
        #expect(fake.log.isEmpty)
        #expect(reveals.count == 1)
        fake.cleanUp()
    }

    @Test("Scanning while idle with Full Disk Access queues every category")
    func scanWhileIdleWithAccess() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        let router = Self.makeRouter(store: store, reveals: RevealCounter())

        _ = await router.scanMac()

        #expect(fake.generalAccesses == [.full])
        #expect(await Self.eventually { fake.log == ["step largeFiles", "step apps", "step leftovers"] })
        fake.cleanUp()
    }

    @Test("A scan already running is joined, not started again")
    func scanJoinsRunningScan() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let router = Self.makeRouter(store: store, reveals: RevealCounter())
        fake.holdsGeneral = true
        store.startLaunchScans()
        #expect(await Self.eventually { fake.generalAccesses.count == 1 })

        let answer = Task { await router.scanMac() }
        // Give the intent a chance to queue anything it wrongly would.
        try? await Task.sleep(for: .milliseconds(50))
        fake.cleanUp()

        #expect(await answer.value == .scanned(safeBytes: 0))
        #expect(fake.generalAccesses.count == 1)
    }

    @Test("Nothing scans while a clean is running")
    func scanWaitsForClean() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        store.isDeleting = true
        let reveals = RevealCounter()
        let router = Self.makeRouter(store: store, reveals: reveals)

        #expect(await router.scanMac() == .busyCleaning)
        #expect(fake.generalAccesses.isEmpty)
        #expect(reveals.count == 1)
        fake.cleanUp()
    }

    @Test("Before onboarding is done nothing scans")
    func scanBeforeOnboarding() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let router = Self.makeRouter(store: store, reveals: RevealCounter(), onboardingDone: false)

        #expect(await router.scanMac() == .needsSetup)
        #expect(fake.generalAccesses.isEmpty)
        fake.cleanUp()
    }

    @Test("Only a finished scan returns a size to Shortcuts")
    func scanAnswerValues() {
        #expect(IntentRouter.ScanOutcome.scanned(safeBytes: 2_000_000).safeSize?.value == 2_000_000)
        #expect(IntentRouter.ScanOutcome.scanned(safeBytes: 0).dialog == "Nothing needs cleaning right now.")
        #expect(IntentRouter.ScanOutcome.scanned(safeBytes: 2_000_000).dialog.contains("safe to clean"))
        #expect(IntentRouter.ScanOutcome.busyCleaning.safeSize == nil)
        #expect(IntentRouter.ScanOutcome.stopped.safeSize == nil)
    }

    // MARK: Uninstall an app

    @Test("Uninstall opens the uninstaller with only that app ticked")
    func uninstallFocusesOneApp() {
        let store = Self.makeStore()
        store.selectedAppIDs = ["/Applications/Other.app"]
        store.uninstallSection = .leftovers
        let reveals = RevealCounter()
        let router = Self.makeRouter(store: store, reveals: reveals)

        router.showUninstaller(appID: "/Applications/Zoom.app", name: "Zoom")

        #expect(store.selectedTab == .uninstaller)
        #expect(store.uninstallSection == .installedApps)
        #expect(store.selectedAppIDs == ["/Applications/Zoom.app"])
        #expect(store.uninstallerFocus == UninstallerFocus(appID: "/Applications/Zoom.app", name: "Zoom"))
        #expect(reveals.count == 1)
    }

    @Test("Before onboarding is done uninstall only opens the window")
    func uninstallBeforeOnboarding() {
        let store = Self.makeStore()
        let reveals = RevealCounter()
        let router = Self.makeRouter(store: store, reveals: reveals, onboardingDone: false)

        router.showUninstaller(appID: "/Applications/Zoom.app", name: "Zoom")

        #expect(store.selectedTab == .overview)
        #expect(store.selectedAppIDs.isEmpty)
        #expect(store.uninstallerFocus == nil)
        #expect(reveals.count == 1)
    }

    @Test("The app picker uses the uninstaller's ids and never lists system apps or Purge")
    func appPickerMatchesUninstaller() {
        let discovered = AppUninstallScanner.discoverInstalledApps()
        #expect(discovered.allSatisfy { !$0.bundleURL.path.hasPrefix("/System/") })
        #expect(discovered.allSatisfy { $0.bundleID != "io.getpurge.app" })

        let url = URL(fileURLWithPath: "/Applications/Zoom.app")
        let entity = InstalledAppEntity(.init(name: "Zoom", bundleURL: url, bundleID: "us.zoom.xos"))
        let app = InstalledApp(name: "Zoom", bundleURL: url, bundleID: "us.zoom.xos", bundleSizeBytes: 0, isRunning: false)
        #expect(entity.id == app.id)
    }

    @Test("Typing an app name matches name or bundle id, like the search box")
    func appPickerMatching() {
        let apps = [
            InstalledAppEntity(.init(name: "Zoom", bundleURL: URL(fileURLWithPath: "/Applications/Zoom.app"), bundleID: "us.zoom.xos")),
            InstalledAppEntity(.init(name: "Slack", bundleURL: URL(fileURLWithPath: "/Applications/Slack.app"), bundleID: "com.tinyspeck.slackmacgap")),
        ]
        #expect(InstalledAppIndex.matching("zo", in: apps).map(\.name) == ["Zoom"])
        #expect(InstalledAppIndex.matching("tinyspeck", in: apps).map(\.name) == ["Slack"])
        #expect(InstalledAppIndex.matching("  ", in: apps).count == 2)
        #expect(InstalledAppIndex.matching("figma", in: apps).isEmpty)
    }

    private static func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
