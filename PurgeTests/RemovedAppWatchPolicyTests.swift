import CoreServices
import Foundation
import ServiceManagement
import Testing
@testable import Purge

@Suite("Removed-app watch decides when leftovers get a review")
struct RemovedAppWatchPolicyTests {
    private let safe = SafetyInfo(
        level: .safe,
        headline: "",
        explanation: "",
        recoverySteps: "",
        reinstallCommand: nil
    )

    private func makeApp(
        name: String = "Rectangle",
        bundlePath: String = "/Applications/Rectangle.app",
        bundleID: String? = "com.knollsoft.Rectangle"
    ) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            bundleID: bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )
    }

    private func item(
        _ path: String,
        category: UninstallCategory,
        reason: MatchReason,
        isSelected: Bool = true
    ) -> UninstallItem {
        UninstallItem(
            path: URL(fileURLWithPath: path),
            sizeBytes: 10,
            category: category,
            safetyInfo: safe,
            matchReason: reason,
            isSelected: isSelected
        )
    }

    // MARK: Review window exit

    /// Once a review Purge opened its window for is over, Purge quits when the
    /// watcher started it or on-demand mode has no menu bar icon, and hides in
    /// menu bar mode. With a clean the user started running beside the review,
    /// the quit waits: `NSApp.terminate` would meet the quit guard with a "still
    /// cleaning" alert for a quit nobody asked for (#173).
    @Test
    func reviewWindowExitWaitsForACleanInProgress() {
        typealias Exit = RemovedAppWatchPolicy.ReviewWindowExit
        func exit(quitsWhenDone: Bool, menuBar: Bool, cleaning: Bool) -> Exit {
            RemovedAppWatchPolicy.reviewWindowExit(quitsWhenDone: quitsWhenDone, showsMenuBarIcon: menuBar, cleanInProgress: cleaning)
        }
        #expect(exit(quitsWhenDone: true, menuBar: true, cleaning: false) == .quit)
        #expect(exit(quitsWhenDone: false, menuBar: false, cleaning: false) == .quit)
        #expect(exit(quitsWhenDone: true, menuBar: true, cleaning: true) == .quitAfterClean)
        #expect(exit(quitsWhenDone: false, menuBar: false, cleaning: true) == .quitAfterClean)
        #expect(exit(quitsWhenDone: false, menuBar: true, cleaning: false) == .hide)
        #expect(exit(quitsWhenDone: false, menuBar: true, cleaning: true) == .hide)
    }

    // MARK: Paths

    @Test
    func normalizesDataVolumeAndTrailingSlash() {
        #expect(RemovedAppWatchPolicy.normalizedPath("/System/Volumes/Data/Applications/") == "/Applications")
        #expect(RemovedAppWatchPolicy.normalizedPath("/Applications/Foo.app/") == "/Applications/Foo.app")
        #expect(RemovedAppWatchPolicy.normalizedPath("/") == "/")
    }

    @Test
    func onlyChangesOutsideBundlesAreRelevant() {
        let roots = ["/Applications", "/Users/x/Applications"]
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/", roots: roots))
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/Utilities/", roots: roots))
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/Users/x/Applications", roots: roots))
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/System/Volumes/Data/Applications/", roots: roots))
        // A product folder inside a vendor folder, where #143's apps live.
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/Autodesk/AutoCAD 2026/", roots: roots))
        // Churn inside a bundle during an update or launch.
        #expect(!RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/Foo.app/Contents/", roots: roots))
        #expect(!RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/Vendor/Foo.app/", roots: roots))
        #expect(!RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/Vendor/Foo.app/Contents/", roots: roots))
        // Any folder further down that the uninstaller walks.
        #expect(RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/A/B/C/", roots: roots))
        // A hidden folder the walk never enters.
        #expect(!RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications/A/.cache/", roots: roots))
        // A sibling folder that only shares the root's prefix.
        #expect(!RemovedAppWatchPolicy.isRelevantChange(atPath: "/Applications Old/", roots: roots))
        #expect(!RemovedAppWatchPolicy.isRelevantChange(atPath: "/Library/", roots: roots))
    }

    @Test
    func departedAppsAreThoseMissingFromTheNewIndex() {
        let kept = makeApp(name: "Kept", bundlePath: "/Applications/Kept.app", bundleID: "com.x.kept")
        let gone = makeApp(name: "Gone", bundlePath: "/Applications/Gone.app", bundleID: "com.x.gone")
        let added = makeApp(name: "New", bundlePath: "/Applications/New.app", bundleID: "com.x.new")
        let departed = RemovedAppWatchPolicy.departedApps(
            previous: [kept.id: kept, gone.id: gone],
            current: [kept.id: kept, added.id: added]
        )
        #expect(departed.map(\.id) == [gone.id])
    }

    /// Finder renames a trashed bundle when an older copy already sits there. The
    /// copy that counts is the one with the departed bundle's file number, never a
    /// stale one that only shares its name.
    @Test
    func trashedCopyIsFoundByFileNumberNotName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-trash-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let stale = trash.appendingPathComponent("Rectangle.app", isDirectory: true)
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        let bundle = apps.appendingPathComponent("Rectangle.app", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let number = try #require(RemovedAppWatchPolicy.fileNumber(atPath: bundle.path))

        let renamed = trash.appendingPathComponent("Rectangle 10.23.45.app", isDirectory: true)
        try fm.moveItem(at: bundle, to: renamed)

        let found = RemovedAppWatchPolicy.trashedCopy(fileNumber: number, in: trash)
        #expect(found?.lastPathComponent == renamed.lastPathComponent)
        #expect(RemovedAppWatchPolicy.trashedCopy(fileNumber: nil, in: trash) == nil)
    }

    /// A handle on a bundle reports where it went. Only the same file counts: a
    /// deleted bundle's handle still names its old path, which may hold nothing
    /// or a replacement by then.
    @Test
    func departureKindFollowsTheBundleNotItsName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-kind-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        for folder in [apps, trash, desktop] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }

        func bundle(_ name: String) throws -> (URL, UInt64) {
            let url = apps.appendingPathComponent("\(name).app", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return (url, try #require(RemovedAppWatchPolicy.fileNumber(atPath: url.path)))
        }

        let (trashed, trashedNumber) = try bundle("Trashed")
        let inTrash = trash.appendingPathComponent("Trashed 10.23.45.app")
        try fm.moveItem(at: trashed, to: inTrash)
        #expect(RemovedAppWatchPolicy.departureKind(currentPath: inTrash.path, fileNumber: trashedNumber) == .trashed)

        let (moved, movedNumber) = try bundle("Moved")
        let onDesktop = desktop.appendingPathComponent("Moved.app")
        try fm.moveItem(at: moved, to: onDesktop)
        #expect(RemovedAppWatchPolicy.departureKind(currentPath: onDesktop.path, fileNumber: movedNumber) == .movedElsewhere)

        let (deleted, deletedNumber) = try bundle("Deleted")
        try fm.removeItem(at: deleted)
        #expect(RemovedAppWatchPolicy.departureKind(currentPath: deleted.path, fileNumber: deletedNumber) == .deleted)

        let (replaced, replacedNumber) = try bundle("Replaced")
        try fm.removeItem(at: replaced)
        try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
        #expect(RemovedAppWatchPolicy.departureKind(currentPath: replaced.path, fileNumber: replacedNumber) == .deleted)

        #expect(RemovedAppWatchPolicy.departureKind(currentPath: nil, fileNumber: 1) == .deleted)
    }

    /// Dragging an app in from a disk image creates the bundle before its
    /// `Info.plist`. An index taken mid-copy must not keep the identifier-less
    /// entry, or deleting the app soon after installing it is never reviewed.
    @Test("A bundle indexed before its Info.plist arrived is read again")
    func bundleIndexedMidCopyIsReadAgain() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-midcopy-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("Chrome.app/Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let key = root.appendingPathComponent("Chrome.app").standardizedFileURL.path

        let midCopy = ApplicationsFolderWatcher.index(roots: [root], reusing: .init())
        #expect(midCopy.apps[key]?.bundleID == nil)

        let plist: NSDictionary = ["CFBundleIdentifier": "com.google.Chrome", "CFBundleName": "Google Chrome"]
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let landed = ApplicationsFolderWatcher.index(roots: [root], reusing: midCopy)
        #expect(landed.apps[key]?.bundleID == "com.google.Chrome")
        #expect(landed.apps[key]?.name == "Google Chrome")
    }

    /// Reading a bundle again used to mean listing both roots every two seconds
    /// for five minutes (#177). The reads now back off, from seconds to a minute,
    /// and stop after about five minutes in all.
    @Test("A bundle with no identifier is read again on a backoff, for about five minutes")
    func incompleteRecheckBacksOff() {
        let delays = (1...12).map { RemovedAppWatchPolicy.incompleteRecheckDelay(attempt: $0) }
        let scheduled = delays.compactMap { $0 }
        #expect(scheduled == [
            .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32),
            .seconds(60), .seconds(60), .seconds(60), .seconds(60),
        ])
        #expect(delays.dropFirst(9).allSatisfy { $0 == nil })
        #expect(RemovedAppWatchPolicy.incompleteRecheckDelay(attempt: 0) == nil)
        #expect(scheduled.reduce(Duration.zero, +) == .seconds(302))
    }

    @Test
    func followDecisionReportsDeletionsOnceQuietAndDropsMovesAndReturns() {
        let timing = RemovedAppWatchPolicy.FollowTiming.standard
        func decide(
            _ kind: RemovedAppWatchPolicy.DepartureKind,
            back: Bool = false,
            departure: Duration = .seconds(1),
            deleted: Duration? = nil,
            activity: Duration = .seconds(0)
        ) -> RemovedAppWatchPolicy.FollowDecision {
            RemovedAppWatchPolicy.followDecision(
                kind: kind,
                appIsBack: back,
                sinceDeparture: departure,
                sinceDeleted: deleted,
                sinceActivity: activity,
                timing: timing
            )
        }
        // `rm`: reported once the roots have been quiet for the quiet period.
        #expect(decide(.deleted, deleted: .seconds(1), activity: .seconds(1)) == .keepFollowing)
        #expect(decide(.deleted, deleted: .seconds(2), activity: .seconds(2)) == .report)
        // An installer still writing keeps it waiting, but never past the cap.
        #expect(decide(.deleted, deleted: .seconds(29), activity: .milliseconds(100)) == .keepFollowing)
        #expect(decide(.deleted, deleted: .seconds(30), activity: .milliseconds(100)) == .report)
        // Moved: followed for the window, then dropped as a move.
        #expect(decide(.movedElsewhere, departure: .seconds(59)) == .keepFollowing)
        #expect(decide(.movedElsewhere, departure: .seconds(60)) == .drop)
        // Trashed later (from the Desktop, say): reported.
        #expect(decide(.trashed, departure: .seconds(20)) == .report)
        // The update landed or the app was put back: never reported.
        #expect(decide(.deleted, back: true, deleted: .seconds(5), activity: .seconds(5)) == .drop)
        #expect(decide(.trashed, back: true) == .drop)
    }

    // MARK: Review decision

    @Test
    func offersReviewForAnAppThatIsReallyGone() {
        #expect(RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: ["com.other.app"],
            otherCopyExists: false,
            removedByPurge: false
        ))
    }

    @Test
    func updateThatPutTheBundleBackIsNotARemoval() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: true,
            installedBundleIDs: [],
            otherCopyExists: false,
            removedByPurge: false
        ))
    }

    /// Moved into a vendor folder, renamed, or a second copy staying: its support
    /// files are still in use. Identifiers compare case-insensitively.
    @Test
    func sameIdentifierStillInstalledIsNotARemoval() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: ["com.knollsoft.rectangle"],
            otherCopyExists: false,
            removedByPurge: false
        ))
    }

    @Test
    func purgeOwnUninstallIsNotReviewedTwice() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: [],
            otherCopyExists: false,
            removedByPurge: true
        ))
    }

    @Test
    func appsWithoutAnIdentifierOrPurgeItselfAreSkipped() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(bundleID: nil),
            bundleStillExists: false,
            installedBundleIDs: [],
            otherCopyExists: false,
            removedByPurge: false
        ))
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(name: "Purge", bundlePath: "/Applications/Purge.app", bundleID: "io.getpurge.app"),
            bundleStillExists: false,
            installedBundleIDs: [],
            otherCopyExists: false,
            removedByPurge: false
        ))
    }

    /// Dragged to the Desktop, on an external drive, or set aside by an updater:
    /// Launch Services still knows a live copy, so its data is still in use.
    @Test
    func aLiveCopyElsewhereIsNotARemoval() {
        #expect(!RemovedAppWatchPolicy.shouldOfferReview(
            for: makeApp(),
            bundleStillExists: false,
            installedBundleIDs: [],
            otherCopyExists: true,
            removedByPurge: false
        ))
    }

    @Test
    func otherCopiesInTheTrashOrAtTheOldPathDoNotCount() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-copies-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let desktopCopy = root.appendingPathComponent("Desktop/Rectangle.app", isDirectory: true)
        let trashedCopy = root.appendingPathComponent(".Trash/Rectangle.app", isDirectory: true)
        try fm.createDirectory(at: desktopCopy, withIntermediateDirectories: true)
        try fm.createDirectory(at: trashedCopy, withIntermediateDirectories: true)
        let app = makeApp()

        #expect(RemovedAppWatchPolicy.countsAsOtherCopy(desktopCopy, of: app))
        #expect(!RemovedAppWatchPolicy.countsAsOtherCopy(trashedCopy, of: app))
        #expect(!RemovedAppWatchPolicy.countsAsOtherCopy(app.bundleURL, of: app))
        #expect(!RemovedAppWatchPolicy.countsAsOtherCopy(
            root.appendingPathComponent("Missing/Rectangle.app"), of: app
        ))
        #expect(RemovedAppWatchPolicy.isInTrash(path: "/Volumes/Backup/.Trashes/501/Rectangle.app"))
        #expect(RemovedAppWatchPolicy.isInTrash(path: "/Users/x/Library/Mobile Documents/.Trash/Rectangle.app"))
    }

    /// Only the unit-test host stays away from the real agent and records. A build
    /// run from Xcode must act on them, or trying the feature from Xcode silently
    /// shows nothing (it did: a Debug build dropped a real removal record).
    @Test
    func onlyTheTestHostLeavesTheLiveAgentAlone() {
        #expect(RemovedAppMonitor.managesLiveAgent(environment: [:]))
        #expect(RemovedAppMonitor.managesLiveAgent(environment: ["HOME": "/Users/x"]))
        #expect(!RemovedAppMonitor.managesLiveAgent(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(!RemovedAppMonitor.managesLiveAgent(environment: ["XCTestSessionIdentifier": "ABC"]))
    }

    // MARK: Watcher health

    /// A blocked or stopped watcher misses every removal without a sound, so each
    /// of those states must read as a problem the user is told about.
    @Test("Watcher health reports a blocked, stopped, or unregistered watcher")
    func watcherHealthNamesEachProblem() {
        func health(_ status: SMAppService.Status, failed: Bool = false, answered: Bool?) -> WatcherHealth {
            RemovedAppMonitor.watcherHealth(
                isEnabled: true,
                status: status,
                registrationFailed: failed,
                agentAnswered: answered
            )
        }
        #expect(health(.requiresApproval, answered: nil) == .needsApproval)
        #expect(health(.requiresApproval, answered: false) == .needsApproval)
        #expect(health(.notRegistered, answered: nil) == .failedToStart)
        #expect(health(.notFound, answered: false) == .failedToStart)
        #expect(health(.enabled, failed: true, answered: nil) == .failedToStart)
        // Listed as allowed, yet silent for a whole check: not running.
        #expect(health(.enabled, answered: false) == .notRunning)
        let problems: [WatcherHealth] = [.needsApproval, .notRunning, .failedToStart]
        #expect(problems.allSatisfy { $0.needsAttention })
    }

    @Test("An answer means the watcher runs; no answer yet is not a problem")
    func watcherHealthTrustsAnAnswer() {
        #expect(RemovedAppMonitor.watcherHealth(
            isEnabled: true, status: .enabled, registrationFailed: false, agentAnswered: nil
        ) == .checking)
        #expect(RemovedAppMonitor.watcherHealth(
            isEnabled: true, status: .enabled, registrationFailed: false, agentAnswered: true
        ) == .running)
        // What macOS reports can lag; the agent answering is what counts.
        #expect(RemovedAppMonitor.watcherHealth(
            isEnabled: true, status: .notFound, registrationFailed: true, agentAnswered: true
        ) == .running)
        #expect(RemovedAppMonitor.watcherHealth(
            isEnabled: false, status: .requiresApproval, registrationFailed: true, agentAnswered: false
        ) == .off)
        let fine: [WatcherHealth] = [.off, .checking, .running]
        #expect(!fine.contains { $0.needsAttention })
    }

    // MARK: Switching off

    /// An agent macOS still listed while the setting was off started Purge after
    /// every removal, with Settings saying Off (#177). One awaiting approval
    /// counts too: approved later, it would start a watcher nobody asked for.
    @Test("An agent still listed while the watcher is off is unregistered")
    func agentListedWhileOffIsUnregistered() {
        #expect(RemovedAppMonitor.shouldUnregisterAgent(isEnabled: false, status: .enabled))
        #expect(RemovedAppMonitor.shouldUnregisterAgent(isEnabled: false, status: .requiresApproval))
        #expect(!RemovedAppMonitor.shouldUnregisterAgent(isEnabled: false, status: .notRegistered))
        #expect(!RemovedAppMonitor.shouldUnregisterAgent(isEnabled: false, status: .notFound))
        #expect(!RemovedAppMonitor.shouldUnregisterAgent(isEnabled: true, status: .enabled))
        #expect(!RemovedAppMonitor.shouldUnregisterAgent(isEnabled: true, status: .requiresApproval))
    }

    // MARK: Agent updates

    @Test("The agent restarts once a replaced executable reads the same twice")
    func agentRestartsAfterReplacementSettles() {
        #expect(RemovedAppWatchPolicy.agentHome(launched: 10, previous: 10, current: 10) == .unchanged)
        // First sight of a new copy: it may still be landing.
        #expect(RemovedAppWatchPolicy.agentHome(launched: 10, previous: 10, current: 20) == .settling)
        #expect(RemovedAppWatchPolicy.agentHome(launched: 10, previous: 20, current: 20) == .replaced)
        // Still changing between checks.
        #expect(RemovedAppWatchPolicy.agentHome(launched: 10, previous: 20, current: 30) == .settling)
        // Deleted, then the new copy landed (a Finder replace).
        #expect(RemovedAppWatchPolicy.agentHome(launched: 10, previous: nil, current: 20) == .settling)
    }

    @Test("An agent whose Purge was trashed or deleted goes quiet rather than restarting")
    func agentGoesDormantWhenItsPurgeIsGone() {
        #expect(RemovedAppWatchPolicy.agentHome(launched: 10, previous: 10, current: nil) == .settling)
        #expect(RemovedAppWatchPolicy.agentHome(launched: 10, previous: nil, current: nil) == .gone)
        // Put back from the Trash: the same file again.
        #expect(RemovedAppWatchPolicy.agentHome(launched: 10, previous: nil, current: 10) == .unchanged)
    }

    @Test("An agent that never read its own file number never acts on it")
    func agentWithoutLaunchNumberStays() {
        #expect(RemovedAppWatchPolicy.agentHome(launched: nil, previous: 20, current: 20) == .unchanged)
        #expect(RemovedAppWatchPolicy.agentHome(launched: nil, previous: nil, current: nil) == .unchanged)
    }

    @Test("An agent from another Purge copy is stale, the owner's own agent is not")
    func agentStaleWhenOwnerIsAnotherCopy() {
        let installed = "/Applications/Purge.app/Contents/MacOS/io.getpurge.watch"
        let xcode = "/Users/me/Library/Developer/Xcode/DerivedData/purge-abc/Build/Products/Debug/Purge.app/Contents/MacOS/io.getpurge.watch"
        #expect(RemovedAppWatchPolicy.agentIsStale(ownPath: xcode, ownerPath: installed, ownerExists: true))
        #expect(!RemovedAppWatchPolicy.agentIsStale(ownPath: installed, ownerPath: installed, ownerExists: true))
        #expect(!RemovedAppWatchPolicy.agentIsStale(
            ownPath: installed,
            ownerPath: "/System/Volumes/Data" + installed,
            ownerExists: true
        ))
        // A copy with no agent in it cannot stop a working one.
        #expect(!RemovedAppWatchPolicy.agentIsStale(ownPath: xcode, ownerPath: installed, ownerExists: false))
    }

    // MARK: Records

    /// A record is a file any process running as the user can write, so only one
    /// the watcher could have produced is acted on.
    @Test
    func onlyRecordsTheWatcherCouldHaveWrittenAreValid() {
        let roots = ["/Applications", "/Users/x/Applications"]
        func valid(_ path: String, _ id: String = "com.knollsoft.Rectangle", _ name: String = "Rectangle") -> Bool {
            RemovedAppWatchPolicy.isValidRecord(path: path, bundleID: id, name: name, roots: roots)
        }
        #expect(valid("/Applications/Rectangle.app"))
        #expect(valid("/Applications/Vendor/Rectangle.app"))
        #expect(valid("/Users/x/Applications/Rectangle.app"))

        // Any depth the watcher indexes, as with AutoCAD (#143).
        #expect(valid("/Applications/Autodesk/AutoCAD 2026/AutoCAD 2026.app"))
        #expect(valid("/Applications/A/B/C/Rectangle.app"))
        #expect(!valid("/Applications/Host.app/Contents/Rectangle.app"))
        #expect(!valid("/Library/LaunchDaemons/Rectangle.app"))
        #expect(!valid("/Applications/../Library/Rectangle.app"))
        #expect(!valid("/Applications/Rectangle"))
        #expect(!valid("/Applications/Rectangle.app", "no-dots"))
        #expect(!valid("/Applications/Rectangle.app", "com.x/../y"))
        #expect(!valid("/Applications/Rectangle.app", "com.x.y", ""))
        #expect(!valid("/Applications/Rectangle.app", "com.x.y", "Line\nbreak"))
        #expect(!valid("/Applications/Rectangle.app", "com.x.y", String(repeating: "a", count: 200)))
    }

    // MARK: Review rows

    @Test
    func reviewDropsTheBundleAndPreselectsOnlyIdentifierMatches() {
        let owner = makeApp()
        let home = "/Users/x/Library"
        let rows = RemovedAppReviewFiltering.reviewItems(
            from: [
                item("/Applications/Rectangle.app", category: .bundle, reason: .appBundle),
                item("\(home)/Preferences/com.knollsoft.Rectangle.plist", category: .preferences, reason: .bundleID),
                item("\(home)/Application Support/Rectangle", category: .applicationSupport, reason: .appName)
            ],
            owner: owner,
            survivors: [],
            appGroupClaims: AppGroupClaims(),
            home: URL(fileURLWithPath: "/Users/x")
        )
        #expect(rows.map(\.category) == [.preferences, .applicationSupport])
        #expect(rows.map(\.isSelected) == [true, false])
    }

    /// The review opens unprompted, so nothing outside the home folder starts
    /// ticked, even an identifier match. Those are the paths that can need the
    /// administrator helper.
    @Test
    func reviewNeverPreselectsSystemLevelLeftovers() {
        let rows = RemovedAppReviewFiltering.reviewItems(
            from: [
                item("/Library/LaunchDaemons/com.knollsoft.Rectangle.plist", category: .launchDaemons, reason: .bundleID),
                item("/Users/x/Library/Caches/com.knollsoft.Rectangle", category: .caches, reason: .bundleID)
            ],
            owner: makeApp(),
            survivors: [],
            appGroupClaims: AppGroupClaims(),
            home: URL(fileURLWithPath: "/Users/x")
        )
        #expect(rows.map(\.isSelected) == [false, true])
    }

    /// A folder named after the removed app that a kept app also claims by name
    /// must not be offered at all.
    @Test
    func reviewLeavesOutLeftoversAnInstalledAppStillClaims() {
        let owner = makeApp(name: "Notes", bundlePath: "/Applications/Notes.app", bundleID: "com.a.notes")
        let survivor = makeApp(name: "Notes", bundlePath: "/Applications/Other/Notes.app", bundleID: "com.b.notes")
        let rows = RemovedAppReviewFiltering.reviewItems(
            from: [
                item("/Users/x/Library/Application Support/Notes", category: .applicationSupport, reason: .appName),
                item("/Users/x/Library/Preferences/com.a.notes.plist", category: .preferences, reason: .bundleID)
            ],
            owner: owner,
            survivors: [survivor],
            appGroupClaims: AppGroupClaims(),
            home: URL(fileURLWithPath: "/Users/x")
        )
        #expect(rows.map(\.path.lastPathComponent) == ["com.a.notes.plist"])
    }

    /// A group container named after the removed app that a kept app lists in
    /// its entitlements is not offered either (#200).
    @Test
    func reviewLeavesOutAGroupAKeptAppLists() {
        let owner = makeApp(name: "Editor", bundlePath: "/nonexistent-purge-tests/Editor.app", bundleID: "com.vendor.Editor")
        let survivor = makeApp(name: "Viewer", bundlePath: "/nonexistent-purge-tests/Viewer.app", bundleID: "org.other.Viewer")
        let shared = item("/Users/x/Library/Group Containers/ABCDE12345.com.vendor.Editor", category: .groupContainers, reason: .groupID)
        let own = item("/Users/x/Library/Group Containers/group.com.vendor.Editor", category: .groupContainers, reason: .groupID)
        let claims = AppGroupClaims.gather(for: [survivor], leftovers: [shared, own]) { _ in
            CodeSignature(identifier: "org.other.Viewer", teamID: "ZZZZZ99999", appGroups: ["ABCDE12345.com.vendor.Editor"])
        }
        let rows = RemovedAppReviewFiltering.reviewItems(
            from: [shared, own],
            owner: owner,
            survivors: [survivor],
            appGroupClaims: claims,
            home: URL(fileURLWithPath: "/Users/x")
        )
        #expect(rows.map(\.path.lastPathComponent) == ["group.com.vendor.Editor"])
    }
}

@Suite("Applications folder watcher", .serialized)
@MainActor
struct ApplicationsFolderWatcherTests {
    private let fm = FileManager.default

    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-watch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeBundle(in folder: URL, name: String, bundleID: String) throws -> URL {
        let bundle = folder.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    @Test
    func snapshotIndexesTopLevelAndVendorFolderBundles() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try makeBundle(in: root, name: "Alpha", bundleID: "com.test.alpha")
        let vendor = root.appendingPathComponent("Vendor", isDirectory: true)
        try fm.createDirectory(at: vendor, withIntermediateDirectories: true)
        try makeBundle(in: vendor, name: "Beta", bundleID: "com.test.beta")

        let product = vendor.appendingPathComponent("Product", isDirectory: true)
        try fm.createDirectory(at: product, withIntermediateDirectories: true)
        try makeBundle(in: product, name: "Gamma", bundleID: "com.test.gamma")
        let deeper = product.appendingPathComponent("Tools", isDirectory: true)
        try fm.createDirectory(at: deeper, withIntermediateDirectories: true)
        try makeBundle(in: deeper, name: "Delta", bundleID: "com.test.delta")

        let snapshot = ApplicationsFolderWatcher.snapshot(roots: [root], reusing: [:])
        #expect(Set(snapshot.values.compactMap(\.bundleID)) == ["com.test.alpha", "com.test.beta", "com.test.gamma", "com.test.delta"])
        #expect(Set(snapshot.values.map(\.name)) == ["Alpha", "Beta", "Gamma", "Delta"])
    }

    /// A root that exists but cannot be listed must not read as "every app deleted".
    @Test
    func unreadableRootKeepsItsPreviousEntries() throws {
        let root = try makeRoot()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        try makeBundle(in: root, name: "Alpha", bundleID: "com.test.alpha")
        let before = ApplicationsFolderWatcher.snapshot(roots: [root], reusing: [:])
        #expect(before.count == 1)

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        let after = ApplicationsFolderWatcher.snapshot(roots: [root], reusing: before)
        #expect(RemovedAppWatchPolicy.departedApps(previous: before, current: after).isEmpty)
    }

    /// A bundle an updater replaced at the same path has a new file number, so it
    /// is read again instead of being described by the copy it replaced.
    @Test
    func indexRereadsABundleSwappedInPlace() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let bundle = try makeBundle(in: root, name: "Alpha", bundleID: "com.test.alpha")
        let before = ApplicationsFolderWatcher.index(roots: [root], reusing: .init())

        let staged = try makeBundle(in: try makeRoot(), name: "Alpha", bundleID: "com.test.alpha2")
        defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
        try fm.removeItem(at: bundle)
        try fm.moveItem(at: staged, to: bundle)

        let after = ApplicationsFolderWatcher.index(roots: [root], reusing: before)
        #expect(after.bundleIDs == ["com.test.alpha2"])
        #expect(after.fileNumbers[bundle.standardizedFileURL.path] != before.fileNumbers[bundle.standardizedFileURL.path])
    }

    /// End to end through FSEvents: a bundle that leaves is reported at once,
    /// inside the three seconds the old settle delay waited, and carries the file
    /// number its Trash copy can be found by. A bundle that comes back shows up in
    /// the next index, which is what withdraws a review opened during an update.
    ///
    /// The stream only reports changes made after fseventsd has it running, so
    /// the test proves that with a probe bundle before it moves anything. A fixed
    /// pause was too short on a busy CI runner, and the move was never reported.
    @Test(.timeLimit(.minutes(1)))
    func reportsADepartureAtOnceAndSeesTheAppComeBack() async throws {
        let root = try makeRoot()
        let elsewhere = try makeRoot()
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: elsewhere)
        }
        let leaving = try makeBundle(in: root, name: "Leaving", bundleID: "com.test.leaving")
        let leavingNumber = RemovedAppWatchPolicy.fileNumber(atPath: leaving.path)

        let watcher = ApplicationsFolderWatcher(roots: [root])
        var departures: [ApplicationsFolderWatcher.Departure] = []
        var indexes: [ApplicationsFolderWatcher.Index] = []
        watcher.onDeparture = { departures.append($0) }
        watcher.onChange = { indexes.append($0) }
        watcher.start()
        defer { watcher.stop() }

        for _ in 0..<50 where watcher.installedApps.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(watcher.installedApps.count == 1)
        // A new probe each try, since one made before the stream was running is
        // never reported. Only an event brings it into an index.
        var isLive = false
        for attempt in 0..<20 where !isLive {
            let probeID = "com.test.probe\(attempt)"
            _ = try makeBundle(in: root, name: "Probe\(attempt)", bundleID: probeID)
            for _ in 0..<25 where !isLive {
                try await Task.sleep(nanoseconds: 20_000_000)
                isLive = indexes.contains { $0.bundleIDs.contains(probeID) }
            }
        }
        try #require(isLive)

        let movedAt = Date()
        let moved = elsewhere.appendingPathComponent("Leaving.app")
        try fm.moveItem(at: leaving, to: moved)
        for _ in 0..<250 where departures.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let departure = try #require(departures.first)
        // Under the old three-second settle delay, with room for a busy runner.
        #expect(Date().timeIntervalSince(movedAt) < 2.5)
        #expect(departure.app.bundleID == "com.test.leaving")
        // The id must not drift once the bundle is gone, or the ignore list and the
        // record path stop matching it.
        #expect(departure.app.id == leaving.standardizedFileURL.path)
        #expect(departure.fileNumber == leavingNumber)
        #expect(!departure.bundleStillExists)
        #expect(RemovedAppWatchPolicy.shouldOfferReview(
            for: departure.app,
            bundleStillExists: departure.bundleStillExists,
            installedBundleIDs: departure.installedBundleIDs,
            otherCopyExists: false,
            removedByPurge: false
        ))

        let seen = indexes.count
        try fm.moveItem(at: moved, to: leaving)
        for _ in 0..<250 where !indexes.dropFirst(seen).contains(where: { $0.bundleIDs.contains("com.test.leaving") }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(indexes.dropFirst(seen).contains { $0.bundleIDs.contains("com.test.leaving") })
    }

    /// With destination tracking (the background agent), on compressed timings:
    /// a drag to the Trash is reported at once; a deletion once the roots go quiet;
    /// a copy moved and left alone never; a moved copy that is then trashed, or
    /// deleted the way `brew uninstall` purges the Caskroom, when that happens; and
    /// a `brew upgrade` style swap never.
    @Test(.timeLimit(.minutes(1)))
    func trashIsReportedAtOnceAndEverythingElseIsFollowed() async throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: outside)
        }
        let trash = outside.appendingPathComponent(".Trash", isDirectory: true)
        let desktop = outside.appendingPathComponent("Desktop", isDirectory: true)
        let caskroom = outside.appendingPathComponent("Caskroom", isDirectory: true)
        for folder in [trash, desktop, caskroom] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let trashed = try makeBundle(in: root, name: "Trashed", bundleID: "com.test.trashed")
        let moved = try makeBundle(in: root, name: "Moved", bundleID: "com.test.moved")
        let movedThenTrashed = try makeBundle(in: root, name: "Later", bundleID: "com.test.later")
        let uninstalled = try makeBundle(in: root, name: "Uninstalled", bundleID: "com.test.uninstalled")
        let deleted = try makeBundle(in: root, name: "Deleted", bundleID: "com.test.deleted")
        let upgraded = try makeBundle(in: root, name: "Upgraded", bundleID: "com.test.upgraded")

        let timing = RemovedAppWatchPolicy.FollowTiming(
            quietPeriod: .milliseconds(500),
            maxDeletedWait: .seconds(5),
            movedFollowWindow: .seconds(2),
            pollInterval: .milliseconds(50)
        )
        let watcher = ApplicationsFolderWatcher(roots: [root], tracksDestinations: true, timing: timing)
        var departures: [(at: Date, departure: ApplicationsFolderWatcher.Departure)] = []
        watcher.onDeparture = { departures.append((Date(), $0)) }
        watcher.start()
        defer { watcher.stop() }

        for _ in 0..<50 where watcher.installedApps.count < 6 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(watcher.installedApps.count == 6)
        try await Task.sleep(nanoseconds: 500_000_000)

        func reported(_ id: String) -> (at: Date, departure: ApplicationsFolderWatcher.Departure)? {
            departures.first { $0.departure.app.bundleID == id }
        }
        func waitFor(_ id: String, seconds: Double) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while reported(id) == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        let start = Date()
        try fm.moveItem(at: trashed, to: trash.appendingPathComponent("Trashed 10.23.45.app"))
        let onDesktop = desktop.appendingPathComponent("Later.app")
        try fm.moveItem(at: moved, to: desktop.appendingPathComponent("Moved.app"))
        try fm.moveItem(at: movedThenTrashed, to: onDesktop)
        let inCaskroom = caskroom.appendingPathComponent("Uninstalled.app")
        try fm.moveItem(at: uninstalled, to: inCaskroom)
        try fm.removeItem(at: deleted)
        // The upgrade: set the old copy aside, install the new one, drop the old.
        let backup = caskroom.appendingPathComponent("Upgraded.app")
        try fm.moveItem(at: upgraded, to: backup)
        try makeBundle(in: root, name: "Upgraded", bundleID: "com.test.upgraded")
        try fm.removeItem(at: backup)

        try await waitFor("com.test.trashed", seconds: 1)
        let trashReport = try #require(reported("com.test.trashed"))
        #expect(trashReport.departure.kind == .trashed)
        #expect(trashReport.at.timeIntervalSince(start) < 0.6)
        #expect(reported("com.test.deleted") == nil)

        try await waitFor("com.test.deleted", seconds: 3)
        let deleteReport = try #require(reported("com.test.deleted"))
        #expect(deleteReport.departure.kind == .deleted)
        #expect(deleteReport.at.timeIntervalSince(start) >= 0.5)

        // Well inside the follow window, the Desktop copy goes to the Trash and
        // Homebrew purges its Caskroom copy. Both count from that moment.
        #expect(reported("com.test.later") == nil)
        #expect(reported("com.test.uninstalled") == nil)
        let laterMovedAt = Date()
        try fm.moveItem(at: onDesktop, to: trash.appendingPathComponent("Later.app"))
        try fm.removeItem(at: inCaskroom)
        try await waitFor("com.test.later", seconds: 1)
        try await waitFor("com.test.uninstalled", seconds: 2)
        let laterReport = try #require(reported("com.test.later"))
        #expect(laterReport.departure.kind == .trashed)
        #expect(laterReport.at.timeIntervalSince(laterMovedAt) < 0.5)
        #expect(reported("com.test.uninstalled")?.departure.kind == .deleted)

        // Past the follow window: the copy left on the Desktop was a move, and the
        // upgraded app came back, so neither was ever reported.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        #expect(reported("com.test.moved") == nil)
        #expect(reported("com.test.upgraded") == nil)
    }

    /// A root that is moved away is noticed, and watched again when it comes
    /// back. The stream was created without `WatchRoot`, so the `RootChanged`
    /// event `handle` looked for never came: a renamed `~/Applications` kept its
    /// stale index, and nothing in it was ever reported again (#177).
    @Test(.timeLimit(.minutes(1)))
    func aMovedRootIsNoticedAndWatchedAgainWhenItReturns() async throws {
        let parent = try makeRoot()
        defer { try? fm.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try makeBundle(in: root, name: "Alpha", bundleID: "com.test.alpha")

        let watcher = ApplicationsFolderWatcher(roots: [root])
        var indexes: [ApplicationsFolderWatcher.Index] = []
        watcher.onChange = { indexes.append($0) }
        watcher.start()
        defer { watcher.stop() }

        for _ in 0..<50 where watcher.installedApps.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(watcher.installedApps.count == 1)
        // As above: the stream only reports changes made once it is running.
        var isLive = false
        for attempt in 0..<20 where !isLive {
            let probeID = "com.test.probe\(attempt)"
            _ = try makeBundle(in: root, name: "Probe\(attempt)", bundleID: probeID)
            for _ in 0..<25 where !isLive {
                try await Task.sleep(nanoseconds: 20_000_000)
                isLive = indexes.contains { $0.bundleIDs.contains(probeID) }
            }
        }
        try #require(isLive)

        let aside = parent.appendingPathComponent("Applications (old)", isDirectory: true)
        try fm.moveItem(at: root, to: aside)
        for _ in 0..<250 where !watcher.installedApps.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(watcher.installedApps.isEmpty)

        try fm.moveItem(at: aside, to: root)
        for _ in 0..<250 where !watcher.index.bundleIDs.contains("com.test.alpha") {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(watcher.index.bundleIDs.contains("com.test.alpha"))
    }

    /// A bundle indexed before its `Info.plist` landed gets its identifier from a
    /// later read of that bundle alone: nothing near the top of the root changes
    /// when the plist arrives, so no event reports it (#177).
    @Test(.timeLimit(.minutes(1)))
    func aBundleReadMidCopyGetsItsIdentifierLater() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let contents = root.appendingPathComponent("Chrome.app/Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)

        let watcher = ApplicationsFolderWatcher(roots: [root])
        var indexes: [ApplicationsFolderWatcher.Index] = []
        watcher.onChange = { indexes.append($0) }
        watcher.start()
        defer { watcher.stop() }

        for _ in 0..<50 where watcher.installedApps.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(watcher.installedApps.count == 1)
        #expect(watcher.installedApps.first?.bundleID == nil)

        let plist: NSDictionary = ["CFBundleIdentifier": "com.google.Chrome", "CFBundleName": "Google Chrome"]
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        // The first read again comes two seconds after the index.
        for _ in 0..<500 where !watcher.index.bundleIDs.contains("com.google.chrome") {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(watcher.index.bundleIDs.contains("com.google.chrome"))
        #expect(indexes.last?.apps.values.first?.name == "Google Chrome")
    }
}

@Suite("Removed-app handoff files", .serialized)
struct RemovedAppHandoffTests {
    private func withTemporaryRoot(_ body: () throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = RemovedAppHandoff.root
        RemovedAppHandoff.root = root
        defer { RemovedAppHandoff.root = previous }
        try body()
    }

    /// Reading leaves records in place, so a review that has to wait for
    /// onboarding or Full Disk Access is not lost. Discarding removes one.
    @Test
    func pendingRecordsStayUntilDiscarded() throws {
        try withTemporaryRoot {
            RemovedAppHandoff.enqueue(.init(path: "/Applications/A.app", bundleID: "com.a", name: "A", fileNumber: 7, removedAt: Date()))
            RemovedAppHandoff.enqueue(.init(path: "/Applications/B.app", bundleID: "com.b", name: "B"))

            #expect(Set(RemovedAppHandoff.pending().map(\.name)) == ["A", "B"])
            #expect(RemovedAppHandoff.pending().count == 2)
            #expect(RemovedAppHandoff.pending().first { $0.name == "A" }?.fileNumber == 7)

            RemovedAppHandoff.discard(path: "/Applications/A.app")
            #expect(RemovedAppHandoff.pending().map(\.name) == ["B"])

            RemovedAppHandoff.clearPending()
            #expect(RemovedAppHandoff.pending().isEmpty)
        }
    }

    /// A record that waited more than a week is dropped rather than reviewed.
    @Test
    func oldRecordsExpire() throws {
        try withTemporaryRoot {
            let longAgo = Date().addingTimeInterval(-RemovedAppWatchPolicy.recordLifetime - 60)
            RemovedAppHandoff.enqueue(.init(path: "/Applications/Old.app", bundleID: "com.old", name: "Old", removedAt: longAgo))
            RemovedAppHandoff.enqueue(.init(path: "/Applications/New.app", bundleID: "com.new", name: "New", removedAt: Date()))
            #expect(RemovedAppHandoff.pending().map(\.name) == ["New"])
        }
    }

    @Test
    func ignoreExpiresAfterGrace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = RemovedAppHandoff.root
        RemovedAppHandoff.root = root
        defer { RemovedAppHandoff.root = previous }

        let path = "/Applications/Gone.app"
        RemovedAppHandoff.ignore(paths: [path])
        #expect(RemovedAppHandoff.isIgnored(path: path))
    }
}
