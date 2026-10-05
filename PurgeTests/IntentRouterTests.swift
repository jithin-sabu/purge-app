import AppKit
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

    // MARK: Scan for Junk

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
        #expect(store.selectedTab == .overview)
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

    @Test("The answer wording fits each outcome")
    func scanAnswerValues() {
        #expect(IntentRouter.ScanOutcome.scanned(safeBytes: 0).dialog == "No junk to clean right now.")
        #expect(IntentRouter.ScanOutcome.scanned(safeBytes: 2_000_000).dialog.contains("safe to clean"))
    }

    @Test("The answer puts the size in bold")
    func styledAnswerBoldsSize() {
        let answer = IntentRouter.ScanOutcome.scanned(safeBytes: 1_576_079_360).styledAnswer
        #expect(String(answer.characters).hasPrefix("Found "))
        let bold = answer.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.count == 1)
        #expect(String(answer[bold[0].range].characters) == formatBytes(1_576_079_360))
        #expect(String(IntentRouter.ScanOutcome.busyCleaning.styledAnswer.characters) == IntentRouter.ScanOutcome.busyCleaning.dialog)
    }

    // MARK: Clean Safe Junk

    @Test("With nothing safe found, nothing is cleaned")
    func cleanWithNothingFound() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let reveals = RevealCounter()
        let router = Self.makeRouter(store: store, reveals: reveals)

        #expect(await router.cleanSafeJunk(reduceMotion: true) == .nothingToClean)
        #expect(!store.isDeleting)
        #expect(store.selectedTab == .overview)
        #expect(reveals.count == 1)
        fake.cleanUp()
    }

    @Test("Results from the last hour are cleaned from without scanning again")
    func cleanReusesFreshResults() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let router = Self.makeRouter(store: store, reveals: RevealCounter())
        _ = await router.scanMac()
        #expect(fake.generalAccesses.count == 1)

        #expect(await router.cleanSafeJunk(reduceMotion: true) == .nothingToClean)
        #expect(fake.generalAccesses.count == 1)
        fake.cleanUp()
    }

    @Test("Results older than an hour are rescanned, App Caches and Dev Tools only")
    func cleanRescansStaleResults() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        let router = Self.makeRouter(store: store, reveals: RevealCounter())
        store.requestScan(.cachesAndDevTools)
        #expect(await Self.eventually { store.hasSessionResults(for: .cachesAndDevTools) && !store.scanQueue.isRunning })
        #expect(fake.generalAccesses.count == 1)

        let later = Date().addingTimeInterval(MenuViewModel.stalenessWindow + 60)
        #expect(await router.cleanSafeJunk(reduceMotion: true, now: later) == .nothingToClean)
        #expect(fake.generalAccesses.count == 2)
        // Large Files, apps and leftovers are not part of a clean.
        #expect(fake.log.isEmpty)
        fake.cleanUp()
    }

    @Test("With no results yet it scans once before cleaning")
    func cleanScansWhenNoResults() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let router = Self.makeRouter(store: store, reveals: RevealCounter())

        #expect(await router.cleanSafeJunk(reduceMotion: true) == .nothingToClean)
        #expect(fake.generalAccesses.count == 1)
        fake.cleanUp()
    }

    @Test("Nothing is cleaned while a clean is already running")
    func cleanWhileCleaning() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        store.isDeleting = true
        let router = Self.makeRouter(store: store, reveals: RevealCounter())

        #expect(await router.cleanSafeJunk(reduceMotion: true) == .busyCleaning)
        #expect(fake.generalAccesses.isEmpty)
        fake.cleanUp()
    }

    @Test("Before onboarding is done nothing is scanned or cleaned")
    func cleanBeforeOnboarding() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let router = Self.makeRouter(store: store, reveals: RevealCounter(), onboardingDone: false)

        #expect(await router.cleanSafeJunk(reduceMotion: true) == .needsSetup)
        #expect(fake.generalAccesses.isEmpty)
        fake.cleanUp()
    }

    @Test("The clean answer bolds the size and owns up to failures")
    func cleanAnswerWording() {
        let size = formatBytes(1_610_000_000)
        let clean = IntentRouter.CleanOutcome.cleaned(bytes: 1_610_000_000, failedCount: 0)
        #expect(clean.dialog == "Moved \(size) of junk to the Trash.")
        #expect(clean.styledAnswer.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.count == 1)
        #expect(IntentRouter.CleanOutcome.cleaned(bytes: 1_610_000_000, failedCount: 2).dialog
            == "Moved \(size) of junk to the Trash. 2 items couldn't be moved.")
        #expect(IntentRouter.CleanOutcome.cleaned(bytes: 0, failedCount: 3).dialog
            == "Purge couldn't move the junk to the Trash. Open Purge to see why.")
    }

    // MARK: Uninstall an app

    @Test("Uninstall opens the review for that app alone once the app list has it")
    func uninstallOpensReview() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        let zoom = Self.app("Zoom")
        store.installedApps = [zoom, Self.app("Other")]
        store.selectedAppIDs = [Self.app("Other").id]
        store.uninstallSection = .leftovers
        let reveals = RevealCounter()
        var reviews: [Set<String>] = []
        let router = IntentRouter(
            store: store,
            reveal: { reveals.count += 1 },
            onboardingDone: { true },
            reviewUninstall: { reviews.append(store.selectedAppIDs) }
        )

        await router.showUninstaller(appID: zoom.id, name: "Zoom")

        #expect(store.selectedTab == .uninstaller)
        #expect(store.uninstallSection == .installedApps)
        #expect(store.uninstallerFocus == UninstallerFocus(appID: zoom.id, name: "Zoom"))
        #expect(reviews == [[zoom.id]])
        #expect(reveals.count == 1)
        fake.cleanUp()
    }

    @Test("Without Full Disk Access the tab asks for it and the review waits")
    func uninstallWithoutAccessSkipsReview() async {
        let fake = FakeScans()
        let store = fake.makeStore()
        let zoom = Self.app("Zoom")
        store.installedApps = [zoom]
        var reviewed = false
        let router = IntentRouter(
            store: store, reveal: {}, onboardingDone: { true },
            reviewUninstall: { reviewed = true }
        )

        await router.showUninstaller(appID: zoom.id, name: "Zoom")

        #expect(store.selectedTab == .uninstaller)
        #expect(store.selectedAppIDs == [zoom.id])
        #expect(!reviewed)
        fake.cleanUp()
    }

    @Test("An app missing from the finished list opens no review")
    func uninstallMissingAppSkipsReview() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        var reviewed = false
        let router = IntentRouter(
            store: store, reveal: {}, onboardingDone: { true },
            reviewUninstall: { reviewed = true }
        )

        await router.showUninstaller(appID: "/Applications/Gone.app", name: "Gone")

        #expect(fake.log.contains("step apps"))
        #expect(!reviewed)
        fake.cleanUp()
    }

    @Test("Before onboarding is done uninstall only opens the window")
    func uninstallBeforeOnboarding() async {
        let store = Self.makeStore()
        let reveals = RevealCounter()
        var reviewed = false
        let router = IntentRouter(
            store: store, reveal: { reveals.count += 1 }, onboardingDone: { false },
            reviewUninstall: { reviewed = true }
        )

        await router.showUninstaller(appID: "/Applications/Zoom.app", name: "Zoom")

        #expect(store.selectedTab == .overview)
        #expect(store.selectedAppIDs.isEmpty)
        #expect(store.uninstallerFocus == nil)
        #expect(!reviewed)
        #expect(reveals.count == 1)
    }

    private static func app(_ name: String) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            bundleID: "test.\(name.lowercased())",
            bundleSizeBytes: 0,
            isRunning: false
        )
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

    @Test("Each app in the picker carries its own 64 px icon")
    func appPickerIcons() throws {
        let png = try #require(InstalledAppIndex.iconPNG(atPath: "/System/Library/CoreServices/Finder.app"))
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 64)
        #expect(rep.pixelsHigh == 64)
        #expect(png.count < 40_000)
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
