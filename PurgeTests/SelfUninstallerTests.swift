import Foundation
import Testing
@testable import Purge

/// Uninstall Purge's run (#330), with fake parts and a fake mover: nothing here
/// touches `SMAppService`, launchd, pbs, notifications or the Trash.
@MainActor
@Suite("Uninstall Purge run")
struct SelfUninstallerTests {
    /// A background part that is on or off, and may refuse to turn off.
    final class FakePart: SelfUninstallPartControl {
        let part: SelfUninstallPart
        var on: Bool
        /// How many turn-offs leave it on.
        var refusals: Int
        /// Reports off to `isOn` while still on, the way an unregister call can
        /// return before launchd stops the job. Only the thorough check sees it.
        var onlyThoroughCheckSeesIt = false
        /// Runs while the part turns off, as a Cancel click during the step would.
        var whileTurningOff: (() -> Void)?
        private(set) var turnOffCalls = 0
        private(set) var thoroughChecks = 0

        init(_ part: SelfUninstallPart, on: Bool = true, refusals: Int = 0) {
            self.part = part
            self.on = on
            self.refusals = refusals
        }

        func isOn(thorough: Bool) async -> Bool {
            if thorough { thoroughChecks += 1 }
            return on
        }

        func turnOff() async {
            turnOffCalls += 1
            whileTurningOff?()
            if refusals > 0 {
                refusals -= 1
            } else if !onlyThoroughCheckSeesIt {
                on = false
            }
        }
    }

    final class FakeMover: SelfUninstallFileMover {
        var dataResults: [SelfUninstallDataMove] = [.moved]
        var appResult: SelfUninstallAppMove = .moved
        var refusal: SelfUninstallPolicy.Refusal?
        private(set) var dataMoves = 0
        private(set) var appMoves = 0

        func moveData() async -> SelfUninstallDataMove {
            dataMoves += 1
            return dataResults.count > 1 ? dataResults.removeFirst() : (dataResults.first ?? .moved)
        }

        func appRefusal() async -> SelfUninstallPolicy.Refusal? { refusal }

        func moveApp() async -> SelfUninstallAppMove {
            appMoves += 1
            return appResult
        }
    }

    final class Gate {
        private(set) var history: [Bool] = []
        var isHeld: Bool { history.last ?? false }
        func set(_ value: Bool) { history.append(value) }
    }

    /// Defaults are made in the body: a default argument is evaluated outside the
    /// main actor.
    private func make(_ parts: [FakePart], mover: FakeMover? = nil, gate: Gate? = nil) -> SelfUninstaller {
        let gate = gate ?? Gate()
        return SelfUninstaller(parts: parts, mover: mover ?? FakeMover(), setRunning: gate.set)
    }

    // MARK: Reading

    @Test func listsOnlyThePartsThatAreOnInTheSheetsOrder() async {
        let model = make([
            FakePart(.loginItem),
            FakePart(.finderService, on: false),
            FakePart(.deletedAppsWatcher),
            FakePart(.cleanupReminder, on: false),
            FakePart(.adminHelper)
        ])
        #expect(model.phase == .reading)
        await model.load()
        #expect(model.phase == .confirm)
        #expect(model.partsOn == [.deletedAppsWatcher, .adminHelper, .loginItem])
    }

    @Test func readingDoesNotTurnAnythingOffOrHoldTheStore() async {
        let part = FakePart(.adminHelper)
        let gate = Gate()
        let model = make([part], gate: gate)
        await model.load()
        #expect(part.turnOffCalls == 0)
        #expect(part.on)
        #expect(gate.history.isEmpty)
    }

    // MARK: Everything works

    @Test func turnsEveryPartOffThenMovesTheApp() async {
        let parts = SelfUninstallPart.allCases.map { FakePart($0) }
        let mover = FakeMover()
        let gate = Gate()
        let model = make(parts, mover: mover, gate: gate)
        await model.load()
        await model.start()

        #expect(model.phase == .done)
        #expect(parts.allSatisfy { !$0.on && $0.turnOffCalls == 1 && $0.thoroughChecks == 1 })
        #expect(mover.appMoves == 1)
        #expect(mover.dataMoves == 0)
        #expect(!model.movedData)
        #expect(model.steps.map(\.kind) == SelfUninstallPart.allCases.map { .part($0) } + [.app])
        #expect(model.steps.allSatisfy { $0.state == .done })
        #expect(gate.history == [true])
    }

    @Test func nothingOnStillMovesTheApp() async {
        let mover = FakeMover()
        let model = make([FakePart(.adminHelper, on: false)], mover: mover)
        await model.load()
        #expect(model.partsOn.isEmpty)
        await model.start()
        #expect(model.phase == .done)
        #expect(model.steps.map(\.kind) == [.app])
        #expect(mover.appMoves == 1)
    }

    @Test func theBoxMovesTheDataBeforeTheApp() async {
        let mover = FakeMover()
        let model = make([FakePart(.loginItem)], mover: mover)
        await model.load()
        model.movesData = true
        await model.start()
        #expect(model.phase == .done)
        #expect(model.steps.map(\.kind) == [.part(.loginItem), .data, .app])
        #expect(mover.dataMoves == 1)
        #expect(model.movedData)
    }

    @Test func anAppAlreadyInTheTrashCountsAsDone() async {
        let mover = FakeMover()
        mover.appResult = .refused(.alreadyInTrash)
        let model = make([], mover: mover)
        await model.load()
        await model.start()
        #expect(model.phase == .done)
    }

    // MARK: Another copy on this Mac

    @Test func anotherCopyKeepsTheDataWhateverTheBox() async {
        let mover = FakeMover()
        let other = URL(fileURLWithPath: "/Applications/Purge.app")
        let model = SelfUninstaller(parts: [FakePart(.loginItem)], mover: mover, otherCopies: { [other] })
        await model.load()
        #expect(!model.mayMoveData)
        model.movesData = true
        await model.start()
        #expect(model.phase == .done)
        #expect(mover.dataMoves == 0)
        #expect(!model.steps.contains { $0.kind == .data })
    }

    /// A copy that turns up after the sheet opened still keeps the data.
    @Test func aCopyThatAppearsAfterOpeningStillKeepsTheData() async {
        final class Copies { var list: [URL] = [] }
        let copies = Copies()
        let mover = FakeMover()
        let model = SelfUninstaller(parts: [FakePart(.loginItem)], mover: mover, otherCopies: { copies.list })
        await model.load()
        #expect(model.mayMoveData)
        model.movesData = true
        copies.list = [URL(fileURLWithPath: "/Applications/Purge.app")]
        await model.start()

        #expect(mover.dataMoves == 0)
        #expect(model.phase == .done)
        #expect(!model.movedData)
        #expect(model.steps.first { $0.kind == .data }?.state == .skipped)
        #expect(!model.mayMoveData)
    }

    @Test func aDataMoveThatPutEverythingBackMayBeCancelled() async {
        let mover = FakeMover()
        mover.dataResults = [.failed]
        let gate = Gate()
        let model = make([FakePart(.loginItem)], mover: mover, gate: gate)
        await model.load()
        model.movesData = true
        await model.start()
        #expect(model.phase == .stepFailed)
        #expect(!model.dataIsSplit)
        #expect(model.mayCancel)
        model.dismissed()
        #expect(!gate.isHeld)
    }

    /// Part of the data is in the Trash and couldn't be put back: going back to
    /// a running Purge would start a new, empty data folder beside it.
    @Test func splitDataMayNotBeCancelledAndAnywayLeavesItAlone() async {
        let mover = FakeMover()
        mover.dataResults = [.failedPartly]
        let gate = Gate()
        let model = make([FakePart(.loginItem)], mover: mover, gate: gate)
        await model.load()
        model.movesData = true
        await model.start()
        #expect(model.phase == .stepFailed)
        #expect(model.dataIsSplit)
        #expect(!model.mayCancel)
        model.dismissed()
        #expect(gate.isHeld)

        await model.uninstallAnyway()
        #expect(model.phase == .done)
        #expect(mover.dataMoves == 1)
        #expect(mover.appMoves == 1)
        #expect(model.failedSteps.map(\.kind) == [.data])
    }

    // MARK: A part stays on

    @Test func aPartStillOnStopsTheRunBeforeAnythingMoves() async {
        let watcher = FakePart(.deletedAppsWatcher)
        let helper = FakePart(.adminHelper, refusals: 1)
        let login = FakePart(.loginItem)
        let mover = FakeMover()
        let model = make([watcher, helper, login], mover: mover)
        await model.load()
        model.movesData = true
        await model.start()

        #expect(model.phase == .stepFailed)
        #expect(mover.appMoves == 0)
        #expect(mover.dataMoves == 0)
        // Every part was still tried, so one failure does not leave others on.
        #expect(!watcher.on && !login.on)
        #expect(model.failedSteps.map(\.kind) == [.part(.adminHelper)])
        #expect(model.steps.first { $0.kind == .data }?.state == .skipped)
        #expect(model.steps.first { $0.kind == .app }?.state == .skipped)
    }

    @Test func aCallThatReturnsWithThePartStillRunningCountsAsFailed() async {
        let watcher = FakePart(.deletedAppsWatcher)
        watcher.onlyThoroughCheckSeesIt = true
        let mover = FakeMover()
        let model = make([watcher], mover: mover)
        await model.load()
        await model.start()
        #expect(model.phase == .stepFailed)
        #expect(watcher.thoroughChecks == 1)
        #expect(mover.appMoves == 0)
    }

    @Test func tryAgainRunsOnlyWhatIsLeftAndThenMoves() async {
        let watcher = FakePart(.deletedAppsWatcher)
        let helper = FakePart(.adminHelper, refusals: 1)
        let mover = FakeMover()
        let model = make([watcher, helper], mover: mover)
        await model.load()
        await model.start()
        #expect(model.phase == .stepFailed)

        await model.retry()
        #expect(model.phase == .done)
        #expect(watcher.turnOffCalls == 1)
        #expect(helper.turnOffCalls == 2)
        #expect(mover.appMoves == 1)
    }

    @Test func uninstallAnywayMovesWithThePartStillOn() async {
        let helper = FakePart(.adminHelper, refusals: 5)
        let mover = FakeMover()
        let model = make([helper], mover: mover)
        await model.load()
        model.movesData = true
        await model.start()
        await model.uninstallAnyway()

        #expect(model.phase == .done)
        #expect(helper.on)
        #expect(mover.dataMoves == 1)
        #expect(mover.appMoves == 1)
        // The done screen still names what is on.
        #expect(model.failedSteps.map(\.kind) == [.part(.adminHelper)])
    }

    @Test func aFailedDataMoveStopsBeforeTheApp() async {
        let mover = FakeMover()
        mover.dataResults = [.failed, .moved]
        let model = make([FakePart(.loginItem)], mover: mover)
        await model.load()
        model.movesData = true
        await model.start()
        #expect(model.phase == .stepFailed)
        #expect(mover.appMoves == 0)
        #expect(!model.movedData)

        await model.retry()
        #expect(model.phase == .done)
        #expect(mover.dataMoves == 2)
        #expect(mover.appMoves == 1)
        #expect(model.movedData)
    }

    // MARK: The app can't move

    /// A copy that can't move itself keeps its data: the app is checked first.
    @Test func aCopyThatCannotMoveKeepsItsData() async {
        let mover = FakeMover()
        mover.refusal = .translocated
        let model = make([FakePart(.loginItem)], mover: mover)
        await model.load()
        model.movesData = true
        await model.start()
        #expect(model.phase == .couldNotMove(.translocated))
        #expect(mover.dataMoves == 0)
        #expect(mover.appMoves == 0)
        #expect(!model.movedData)
        #expect(model.steps.first { $0.kind == .data }?.state == .skipped)
    }

    @Test func anAppAlreadyInTheTrashStillLetsTheDataMove() async {
        let mover = FakeMover()
        mover.refusal = .alreadyInTrash
        mover.appResult = .refused(.alreadyInTrash)
        let model = make([], mover: mover)
        await model.load()
        model.movesData = true
        await model.start()
        #expect(model.phase == .done)
        #expect(mover.dataMoves == 1)
    }

    @Test func eachRefusalMapsToTheReasonTheSheetShows() async {
        let cases: [(SelfUninstallAppMove, SelfUninstallMoveProblem)] = [
            (.refused(.readOnlyVolume), .readOnlyVolume),
            (.refused(.translocated), .translocated),
            (.refused(.notThisApp), .notThisApp),
            (.refused(.notAnApp), .notThisApp),
            (.refused(.missing), .notThisApp),
            (.failed, .refusedByMacOS)
        ]
        for (result, problem) in cases {
            let mover = FakeMover()
            mover.appResult = result
            let model = make([FakePart(.loginItem)], mover: mover)
            await model.load()
            await model.start()
            #expect(model.phase == .couldNotMove(problem))
        }
    }

    // MARK: Cancel

    @Test func cancelBeforeStartingLetsTheStoreRunAgain() async {
        let gate = Gate()
        let model = make([FakePart(.loginItem)], gate: gate)
        await model.load()
        model.dismissed()
        #expect(!gate.isHeld)
    }

    @Test func stopAfterTheRunningStepKeepsWhatIsOffAndGoesBackToConfirm() async {
        let watcher = FakePart(.deletedAppsWatcher)
        let helper = FakePart(.adminHelper)
        let gate = Gate()
        let mover = FakeMover()
        let model = make([watcher, helper], mover: mover, gate: gate)
        watcher.whileTurningOff = { model.requestStop() }
        await model.load()
        await model.start()

        // The watcher finished turning off; the helper never started.
        #expect(!watcher.on)
        #expect(helper.on)
        #expect(helper.turnOffCalls == 0)
        #expect(mover.appMoves == 0)
        #expect(gate.history == [true, false])
        #expect(model.phase == .confirm)
        #expect(model.partsOn == [.adminHelper])
        #expect(!model.isStopping)
    }

    @Test func stopIsIgnoredOnceTheMovesStarted() async {
        let model = make([])
        await model.load()
        await model.start()
        model.requestStop()
        #expect(model.phase == .done)
        #expect(!model.isStopping)
    }
}

/// The store side of Uninstall Purge: while it runs, nothing else may start,
/// and its sheet never opens over another.
@MainActor
@Suite("Uninstall Purge store gate")
struct SelfUninstallStoreGateTests {
    @Test func runningHoldsCleansAndScheduledCleans() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        store.isUninstallingPurge = true
        #expect(!store.mayStartSafeClean(trigger: .manual))
        #expect(!store.mayStartSafeClean(trigger: .scheduled))
        #expect(store.isReviewingOrCleaning)

        store.isUninstallingPurge = false
        #expect(store.mayStartSafeClean(trigger: .manual))
        #expect(store.mayStartSafeClean(trigger: .scheduled))
    }

    @Test func theOpenSheetHoldsUnpromptedReviews() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        #expect(!store.isShowingReviewOrCleaning)
        await store.openSelfUninstall()
        #expect(store.isSelfUninstallPresented)
        #expect(store.isShowingReviewOrCleaning)
    }

    @Test func theSheetNeverOpensOverAnother() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.showDeletionSheet = true
        await store.openSelfUninstall()
        #expect(!store.isSelfUninstallPresented)
    }

    /// The sheet opens with its list already read, so it never grows on screen.
    @Test func theSheetOpensOnlyOnceThePartsAreRead() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let model = SelfUninstaller(parts: [SelfUninstallerTests.FakePart(.loginItem)], mover: SelfUninstallerTests.FakeMover())
        await store.openSelfUninstall(model: model)
        let shown = try? #require(store.selfUninstall)
        #expect(shown === model)
        #expect(model.phase == .confirm)
        #expect(model.partsOn == [.loginItem])
        #expect(!store.isPreparingSelfUninstall)
    }

    @Test func aSecondOpenWhileOneIsShownDoesNothing() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let first = SelfUninstaller(parts: [], mover: SelfUninstallerTests.FakeMover())
        await store.openSelfUninstall(model: first)
        await store.openSelfUninstall(model: SelfUninstaller(parts: [], mover: SelfUninstallerTests.FakeMover()))
        #expect(store.selfUninstall === first)
    }

    @Test func theTestHostGetsNoLiveParts() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let model = SelfUninstaller.live(store: store)
        await model.load()
        #expect(model.partsOn.isEmpty)
        await model.start()
        // The inert mover refuses, so nothing of the user's moves. The store
        // stays held: that screen's only ways out quit Purge.
        #expect(model.phase == .couldNotMove(.notThisApp))
        #expect(store.isUninstallingPurge)
        store.isUninstallingPurge = false
    }
}
