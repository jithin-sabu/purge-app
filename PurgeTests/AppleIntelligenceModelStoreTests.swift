import Foundation
import Testing
@testable import Purge

@Suite("The Apple Intelligence row only acts where it was checked, and always offers a way back")
struct AppleIntelligenceModelStoreTests {
    private func os(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    /// The spike ran on 27.0. A new major version could rename the service's
    /// keys, and a release the service reads as naming no sets resets every
    /// asset on the Mac, so 28 stays out until it is checked.
    @Test func supportedOnEvery27ReleaseOnly() {
        #expect(AppleIntelligenceModelStore.isSupported(os: os(27), machine: "arm64"))
        #expect(AppleIntelligenceModelStore.isSupported(os: os(27, 3), machine: "arm64"))
        #expect(!AppleIntelligenceModelStore.isSupported(os: os(26, 6), machine: "arm64"))
        #expect(!AppleIntelligenceModelStore.isSupported(os: os(15, 5), machine: "arm64"))
        #expect(!AppleIntelligenceModelStore.isSupported(os: os(28), machine: "arm64"))
        #expect(!AppleIntelligenceModelStore.isSupported(os: os(27), machine: "x86_64"))
    }

    private func reading(present: Int) -> AppleIntelligenceReading {
        let sets = AppleIntelligenceCatalog.sets.enumerated().map { index, set in
            AppleIntelligenceSetReading(
                set: set,
                recordsOnDisk: index < present ? 3 : 0,
                eliminating: 0,
                latestBytes: index < present ? 1_000_000_000 : 0,
                folder: index < present ? .holdsFiles : .empty
            )
        }
        return AppleIntelligenceReading(sets: sets, readAt: Date())
    }

    /// After a partial removal the block is installed and some sets stayed.
    /// Download Again is the only way in the app to lift the block, so it shows
    /// beside Remove.
    @Test func partialRemovalOffersBothActions() {
        let offers = AppleIntelligenceModelStore.offers(reading: reading(present: 2), isProfileInstalled: true)
        #expect(offers.remove)
        #expect(offers.downloadAgain)
    }

    @Test func otherStatesOfferOneAction() {
        let untouched = AppleIntelligenceModelStore.offers(reading: reading(present: 5), isProfileInstalled: false)
        #expect(untouched.remove && !untouched.downloadAgain)

        let removed = AppleIntelligenceModelStore.offers(reading: reading(present: 0), isProfileInstalled: true)
        #expect(!removed.remove && removed.downloadAgain)

        let none = AppleIntelligenceModelStore.offers(reading: reading(present: 0), isProfileInstalled: false)
        #expect(!none.remove && none.downloadAgain)

        let unread = AppleIntelligenceModelStore.offers(reading: nil, isProfileInstalled: false)
        #expect(!unread.remove && !unread.downloadAgain)
    }

    /// One set can start minutes after the one before it, so the watch does not
    /// end after a short pause; and it does not say "downloading" forever when
    /// nothing comes.
    @Test func downloadWatchWaitsForAQuietSpellAndGivesUpWhenNothingComes() {
        let settle = AppleIntelligenceModelStore.downloadSettleTime
        let start = AppleIntelligenceModelStore.downloadStartWait
        #expect(AppleIntelligenceModelStore.downloadWatch(anythingArrived: true, quietFor: 60) == .keepWatching)
        #expect(AppleIntelligenceModelStore.downloadWatch(anythingArrived: true, quietFor: settle) == .settled)
        #expect(AppleIntelligenceModelStore.downloadWatch(anythingArrived: false, quietFor: settle) == .keepWatching)
        #expect(AppleIntelligenceModelStore.downloadWatch(anythingArrived: false, quietFor: start) == .nothingArrived)
    }

    /// After a partial removal some sets are on the Mac before Download Again,
    /// so those must not count as arrivals, or the watch would call a download
    /// that never started finished.
    @Test func setsAlreadyThereAtTheRequestAreNotArrivals() {
        let leftovers = atRequest(present: 2)
        #expect(!AppleIntelligenceModelStore.hasArrivals(since: leftovers, now: reading(present: 2).sets))
        #expect(AppleIntelligenceModelStore.hasArrivals(since: leftovers, now: reading(present: 3).sets))
        #expect(AppleIntelligenceModelStore.hasArrivals(since: atRequest(present: 0), now: reading(present: 1).sets))
        #expect(!AppleIntelligenceModelStore.hasArrivals(since: atRequest(present: 0), now: reading(present: 0).sets))
    }

    // MARK: A pending Download Again across launches

    private typealias Store = AppleIntelligenceModelStore
    private let defaults = ThrowawayDefaults()
    private let requestedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func atRequest(present: Int) -> [Store.DownloadRequest.SetAtRequest] {
        reading(present: present).sets.map(Store.DownloadRequest.SetAtRequest.init)
    }

    private func request(present: Int = 0) -> Store.DownloadRequest {
        Store.DownloadRequest(requestedAt: requestedAt, sets: reading(present: present).sets)
    }

    private func after(_ seconds: TimeInterval) -> Date {
        requestedAt.addingTimeInterval(seconds)
    }

    /// Closing the window quits Purge in on-demand mode, so the request has to
    /// outlive the app, with the sets it is judged against.
    @Test func aRequestSurvivesARelaunchAndClearsCleanly() {
        let saved = request(present: 2)
        Store.saveDownloadRequest(saved, to: defaults.defaults)
        #expect(Store.loadDownloadRequest(from: defaults.defaults) == saved)
        #expect(Store.loadDownloadRequest(from: defaults.defaults)?.sets.filter(\.isPresent).count == 2)

        Store.saveDownloadRequest(nil, to: defaults.defaults)
        #expect(Store.loadDownloadRequest(from: defaults.defaults) == nil)
        #expect(defaults.defaults.object(forKey: Store.downloadRequestKey) == nil)
    }

    /// The bug from 1.10.0: Download Again, then a relaunch before anything
    /// arrived, and the row was gone. After a relaunch the row picks up where
    /// it was.
    @Test func aRelaunchPicksUpThePendingRequest() {
        let nothing = reading(present: 0).sets
        let soon = Store.arrivalOutcome(
            current: nil, request: request(), now: nothing, lastArrivalChange: after(90), at: after(90))
        #expect(soon.outcome == .downloadRequested)
        #expect(!soon.requestDone)

        let later = Store.arrivalOutcome(
            current: nil, request: request(), now: nothing,
            lastArrivalChange: after(Store.downloadStartWait), at: after(Store.downloadStartWait))
        #expect(later.outcome == .downloadNotStarted)
        #expect(!later.requestDone)
    }

    /// Models that landed while Purge was closed count as arrivals, so the row
    /// watches them settle, then goes back to showing the size.
    @Test func modelsThatArrivedWhilePurgeWasClosedSettle() {
        let some = reading(present: 3).sets
        let relaunch = after(Store.downloadStartWait + 60)
        let first = Store.arrivalOutcome(
            current: nil, request: request(), now: some, lastArrivalChange: relaunch, at: relaunch)
        #expect(first.outcome == .downloadRequested)
        #expect(!first.requestDone)

        let quiet = relaunch.addingTimeInterval(Store.downloadSettleTime)
        let settled = Store.arrivalOutcome(
            current: first.outcome, request: request(), now: some, lastArrivalChange: relaunch, at: quiet)
        #expect(settled.outcome == nil)
        #expect(settled.requestDone)
    }

    /// After a partial removal the sets that stayed are not arrivals, after a
    /// relaunch as much as before it.
    @Test func leftoversAreNotArrivalsAfterARelaunch() {
        let next = Store.arrivalOutcome(
            current: nil, request: request(present: 2), now: reading(present: 2).sets,
            lastArrivalChange: after(Store.downloadStartWait), at: after(Store.downloadStartWait))
        #expect(next.outcome == .downloadNotStarted)
    }

    /// A Mac that never downloads doesn't keep the row for good: after a week
    /// with nothing arrived the request is dropped, at launch and while watching.
    @Test func aRequestWithNothingArrivedExpiresAfterAWeek() {
        let nothing = reading(present: 0).sets
        let week = after(Store.downloadRequestExpiry)
        let atLaunch = Store.arrivalOutcome(
            current: nil, request: request(), now: nothing, lastArrivalChange: week, at: week)
        #expect(atLaunch.outcome == nil)
        #expect(atLaunch.requestDone)

        let watching = Store.arrivalOutcome(
            current: .downloadNotStarted, request: request(), now: nothing, lastArrivalChange: week, at: week)
        #expect(watching.outcome == nil)
        #expect(watching.requestDone)

        // Still "downloading" because nothing read it all week: dropped at once.
        let unread = Store.arrivalOutcome(
            current: .downloadRequested, request: request(), now: nothing, lastArrivalChange: week, at: week)
        #expect(unread.outcome == nil)
        #expect(unread.requestDone)

        // A clock stepped back a little right after the request keeps it.
        let stepBack = Store.arrivalOutcome(
            current: .downloadRequested, request: request(), now: nothing, lastArrivalChange: after(-5), at: after(-5))
        #expect(stepBack.outcome == .downloadRequested)
        #expect(!stepBack.requestDone)

        let dayBefore = after(Store.downloadRequestExpiry - 24 * 60 * 60)
        let stillWaiting = Store.arrivalOutcome(
            current: .downloadNotStarted, request: request(), now: nothing, lastArrivalChange: dayBefore, at: dayBefore)
        #expect(stillWaiting.outcome == .downloadNotStarted)
        #expect(!stillWaiting.requestDone)
    }

    /// A late download still counts, even after "nothing has arrived yet".
    @Test func aLateArrivalWatchesAgain() {
        let late = after(2 * 24 * 60 * 60)
        let next = Store.arrivalOutcome(
            current: .downloadNotStarted, request: request(), now: reading(present: 1).sets,
            lastArrivalChange: late, at: late)
        #expect(next.outcome == .downloadRequested)
        #expect(!next.requestDone)
    }

    /// Arrivals win over expiry: models that start landing after a week, or
    /// with the clock moved back, are watched until they settle, which ends the
    /// request. Settling counts from the last change, so it can't run on.
    @Test func arrivalsAfterExpiryAreWatchedUntilTheySettle() {
        let landing = reading(present: 2).sets
        for start in [after(Store.downloadRequestExpiry + 60), after(-24 * 60 * 60)] {
            let late = Store.arrivalOutcome(
                current: .downloadNotStarted, request: request(), now: landing, lastArrivalChange: start, at: start)
            #expect(late.outcome == .downloadRequested)
            #expect(!late.requestDone)

            let watching = Store.arrivalOutcome(
                current: .downloadRequested, request: request(), now: landing, lastArrivalChange: start, at: start)
            #expect(watching.outcome == .downloadRequested)

            let quiet = start.addingTimeInterval(Store.downloadSettleTime)
            let settled = Store.arrivalOutcome(
                current: .downloadRequested, request: request(), now: landing, lastArrivalChange: start, at: quiet)
            #expect(settled.outcome == nil)
            #expect(settled.requestDone)
        }
    }

    @Test func aPendingRequestReadsByAge() {
        #expect(Store.pendingOutcome(requestedAt: requestedAt, now: requestedAt) == .downloadRequested)
        #expect(Store.pendingOutcome(requestedAt: requestedAt, now: after(Store.downloadStartWait - 1)) == .downloadRequested)
        #expect(Store.pendingOutcome(requestedAt: requestedAt, now: after(Store.downloadStartWait)) == .downloadNotStarted)
        #expect(Store.pendingOutcome(requestedAt: requestedAt, now: after(Store.downloadRequestExpiry)) == nil)
        // A small clock adjustment keeps the request; a clock moved well back
        // can't leave one that never ages out.
        #expect(Store.pendingOutcome(requestedAt: requestedAt, now: after(-60)) == .downloadRequested)
        #expect(Store.pendingOutcome(requestedAt: requestedAt, now: after(-Store.clockStepAllowance - 1)) == nil)
    }

    /// The clock moved back a day while the row said "downloading": without a
    /// limit it would keep saying so, re-reading every 20 seconds, for a day.
    @Test func aClockMovedWellBackDropsAnActiveRequest() {
        let dayBack = after(-24 * 60 * 60)
        let next = Store.arrivalOutcome(
            current: .downloadRequested, request: request(), now: reading(present: 0).sets,
            lastArrivalChange: dayBack, at: dayBack)
        #expect(next.outcome == nil)
        #expect(next.requestDone)
    }

    /// The row shows for a pending request, but a Mac that never had the
    /// models and asked for nothing still shows none: there is nothing of
    /// Purge's to bring back there.
    @Test func onlyAPendingRequestKeepsTheRowOnAMacWithoutModels() {
        let none = reading(present: 0)
        #expect(!Store.isRelevant(reading: none, isProfileInstalled: false, lastOutcome: nil))
        #expect(Store.isRelevant(reading: none, isProfileInstalled: false, lastOutcome: .downloadRequested))
        #expect(Store.isRelevant(reading: none, isProfileInstalled: false, lastOutcome: .downloadNotStarted))
        #expect(Store.isRelevant(reading: reading(present: 1), isProfileInstalled: false, lastOutcome: nil))
        #expect(Store.isRelevant(reading: none, isProfileInstalled: true, lastOutcome: nil))
    }

    /// Remove and a failed request own the row; a request left over from before
    /// them is forgotten rather than brought back.
    @Test func anotherOutcomeReplacesTheRequest() {
        let next = Store.arrivalOutcome(
            current: .profileStillInstalled, request: request(), now: reading(present: 0).sets,
            lastArrivalChange: after(60), at: after(60))
        #expect(next.outcome == .profileStillInstalled)
        #expect(next.requestDone)
    }

    // MARK: Remove acts on the confirmation, Download Again on what was removed (#179)

    private var catalog: [AppleIntelligenceModelSet] { AppleIntelligenceCatalog.sets }

    /// The confirmation showed two sets. One went on its own before the click
    /// and a third appeared: neither is touched.
    @Test func removeActsOnlyOnTheConfirmedSets() {
        let planned = [catalog[0], catalog[1]]
        let present = [catalog[1], catalog[2]]
        #expect(Store.targets(planned: planned, present: present) == [catalog[1]])
        #expect(Store.targets(planned: planned, present: []).isEmpty)
        #expect(Store.targets(planned: [], present: present).isEmpty)
    }

    /// Download Again asks for the sets Purge removed and nothing else: not a
    /// set that stayed after a partial removal, and not one the Mac never had.
    @Test func downloadAgainAsksForWhatWasRemoved() {
        // Sets 0 and 1 removed and absent, 2 stayed, 3 and 4 never there.
        let sets = reading(present: 3).sets.map { item in
            AppleIntelligenceSetReading(
                set: item.set, recordsOnDisk: item.set == catalog[2] ? 3 : 0, eliminating: 0,
                latestBytes: nil, folder: item.set == catalog[2] ? .holdsFiles : .empty)
        }
        let byRecord = Store.setsToRequest(removed: [catalog[0].name, catalog[1].name], blockedTypes: [], sets: sets)
        #expect(byRecord == [catalog[0], catalog[1]])

        // After a relaunch with no record, the profile still says what was blocked.
        let byBlock = Store.setsToRequest(
            removed: [], blockedTypes: [catalog[0].assetType, catalog[2].assetType], sets: sets)
        #expect(byBlock == [catalog[0]])

        // A removed set that is back on the Mac is not asked for again.
        let back = Store.setsToRequest(removed: [catalog[2].name], blockedTypes: [], sets: sets)
        #expect(back.isEmpty)

        // No record and no block, as after an update: every absent set, as before.
        #expect(Store.setsToRequest(removed: [], blockedTypes: [], sets: sets).map(\.name)
            == [catalog[0], catalog[1], catalog[3], catalog[4]].map(\.name))
        #expect(Store.setsToRequest(removed: [], blockedTypes: [], sets: reading(present: 5).sets).isEmpty)
    }

    /// The record outlives a relaunch, adds up over removals, and lets go of a
    /// set once it is on the Mac again, however it got there.
    @Test func theRemovedSetsRecordSurvivesARelaunchAndForgetsWhatCameBack() {
        let first = Store.remembering(removed: [catalog[3].name], in: [])
        let both = Store.remembering(removed: [catalog[0].name, catalog[3].name], in: first)
        #expect(both == [catalog[0].name, catalog[3].name])

        Store.saveRemovedSetNames(both, to: defaults.defaults)
        #expect(Store.loadRemovedSetNames(from: defaults.defaults) == both)

        let afterDownload = Store.forgetting(present: [catalog[0].name], from: both)
        #expect(afterDownload == [catalog[3].name])
        Store.saveRemovedSetNames([], to: defaults.defaults)
        #expect(Store.loadRemovedSetNames(from: defaults.defaults).isEmpty)
        #expect(defaults.defaults.object(forKey: Store.removedSetsKey) == nil)
    }

    /// Cancel shows a second before the wait begins. A click in that second
    /// used to be wiped by the wait and Purge sat there for ten minutes.
    @Test @MainActor func aCancelBeforeTheWaitStartsIsKept() async {
        let store = Store(defaults: defaults.defaults)
        store.cancelWaiting()
        let start = Date()
        let held = await store.waitUntil({ false }, limit: 3)
        #expect(!held)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
