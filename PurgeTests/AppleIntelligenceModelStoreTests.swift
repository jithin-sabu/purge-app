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

    /// A Mac that answers the worker from memory and records what was asked of
    /// it, so `remove` and `downloadAgain` can run whole in a test. Nothing
    /// waits: pauses return at once.
    @MainActor
    private final class FakeMac {
        var blocks: [String]
        var siriLanguage: String? = "zh-TW"
        var resets: [String] = []
        /// Each release request as sent, so a test can see how many sets one named.
        var resetRequests: [[String]] = []
        var subscribeCalls = 0
        var subscribed: [[String: Any]] = []
        var recorded: [[AppleIntelligenceModelSet]] = []
        /// What the worker answers for an op instead of success.
        var failing: [String: AppleIntelligenceWorker.Outcome] = [:]
        /// What the worker answers for a release of one set, by set name.
        var failingResets: [String: AppleIntelligenceWorker.Outcome] = [:]
        /// Answers for a set's releases in order, before `failingResets` applies.
        var resetReplies: [String: [AppleIntelligenceWorker.Outcome]] = [:]
        /// Answers for the download requests in order, before `failing` applies.
        var subscribeReplies: [AppleIntelligenceWorker.Outcome] = []
        /// What the Mac reads as once a release has been asked for, and after
        /// how many more readings, since macOS deletes after it answers.
        var readingAfterReset: AppleIntelligenceReading?
        var readsBeforeDeleted = 0
        /// How many releases macOS takes before `readingAfterReset` applies.
        var resetsBeforeDeleted = 1
        /// What the asset service logged, for the details.
        var serviceLog: [String] = []
        /// Runs after each release request, with how many have gone out.
        var afterReset: ((Int) -> Void)?
        /// Runs after a set's asset-type lookup.
        var afterLookup: (() -> Void)?
        /// Runs inside each pause, as a click during it would.
        var duringPause: (() -> Void)?

        func paused() { duringPause?() }

        /// The current reading, behind a lock: the store reads it off the main actor.
        final class ReadingBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: AppleIntelligenceReading
            private var pending: (reading: AppleIntelligenceReading, reads: Int)?
            init(_ value: AppleIntelligenceReading) { self.value = value }
            func get() -> AppleIntelligenceReading {
                lock.withLock {
                    if let next = pending {
                        if next.reads <= 0 {
                            value = next.reading
                            pending = nil
                        } else {
                            pending = (next.reading, next.reads - 1)
                        }
                    }
                    return value
                }
            }
            func set(_ new: AppleIntelligenceReading, afterReads reads: Int = 0) {
                lock.withLock { pending = (new, reads) }
            }
        }

        let current: ReadingBox

        init(reading: AppleIntelligenceReading, blocks: [String]) {
            current = ReadingBox(reading)
            self.blocks = blocks
        }

        private let accepted = AppleIntelligenceWorker.Outcome(ok: true, result: [:], error: nil)

        var services: Store.Services {
            var services = Store.Services()
            let current = current
            services.read = { current.get() }
            services.installedBlocks = { [blocks] in blocks }
            services.siriLanguage = { [siriLanguage] in siriLanguage }
            services.recordRemoval = { [self] sets, _, _ in self.recorded.append(sets) }
            services.pause = { [self] _ in await self.paused() }
            services.serviceLog = { [serviceLog] _ in serviceLog }
            services.runWorker = { [self] op, input, _ in
                switch op {
                case "asset-type":
                    defer { self.afterLookup?() }
                    if let failure = self.failing[op] { return failure }
                    let name = input["assetSet"] as? String
                    let type = AppleIntelligenceCatalog.sets.first { $0.name == name }?.assetType
                    return AppleIntelligenceWorker.Outcome(ok: true, result: ["assetType": type as Any], error: nil)
                case "reset":
                    let names = input["assetSets"] as? [String] ?? []
                    self.resets += names
                    self.resetRequests.append(names)
                    defer { self.afterReset?(self.resetRequests.count) }
                    if let after = self.readingAfterReset, self.resets.count == self.resetsBeforeDeleted {
                        current.set(after, afterReads: self.readsBeforeDeleted)
                    }
                    guard let name = names.first else { return self.accepted }
                    if var queued = self.resetReplies[name], !queued.isEmpty {
                        let reply = queued.removeFirst()
                        self.resetReplies[name] = queued
                        return reply
                    }
                    return self.failingResets[name] ?? self.failing[op] ?? self.accepted
                case "subscribe":
                    self.subscribeCalls += 1
                    self.subscribed = input["subscriptions"] as? [[String: Any]] ?? []
                    if !self.subscribeReplies.isEmpty { return self.subscribeReplies.removeFirst() }
                    return self.failing[op] ?? self.accepted
                default:
                    return self.accepted
                }
            }
            return services
        }
    }

    /// The Mac with `set` gone and the rest as `base` has them.
    private func without(_ set: AppleIntelligenceModelSet, from base: AppleIntelligenceReading) -> AppleIntelligenceReading {
        AppleIntelligenceReading(
            sets: base.sets.map { item in
                item.set == set
                    ? AppleIntelligenceSetReading(set: item.set, recordsOnDisk: 0, eliminating: 0, latestBytes: 0, folder: .empty)
                    : item
            },
            readAt: Date())
    }

    /// Run whole: the confirmation showed sets 0 and 1, then set 0 went on
    /// its own and set 2 appeared. Only set 1 is sent to the service. With
    /// every type already blocked there is no profile step, so nothing waits.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func removeReleasesOnlyTheConfirmedSets() async throws {
        let present = reading(present: 3).sets.filter { $0.set != catalog[0] }
        let mac = FakeMac(
            reading: AppleIntelligenceReading(sets: present, readAt: Date()),
            blocks: catalog.map(\.assetType))
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0], catalog[1]])

        #expect(mac.resets == [catalog[1].name])
        #expect(store.phase == .idle)
        // The fake Mac still lists set 1 afterwards, so nothing was recorded as gone.
        #expect(mac.recorded.isEmpty)
        #expect(Store.loadRemovedSetNames(from: defaults.defaults).isEmpty)
    }

    /// Run whole: with no profile to lift, Download Again subscribes to the
    /// recorded sets that are absent, with each language alias's values in
    /// the Siri language first, and leaves a present set alone.
    @Test(.enabled(if: Store.isSupported, "the download is gated to macOS 27 on Apple silicon"))
    @MainActor func downloadAgainSubscribesToTheRemovedSetsInTheSiriLanguage() async throws {
        Store.saveRemovedSetNames([catalog[0].name, catalog[1].name, catalog[4].name], to: defaults.defaults)
        let present = reading(present: 1).sets.map { item in
            AppleIntelligenceSetReading(
                set: item.set, recordsOnDisk: item.set == catalog[1] ? 3 : 0, eliminating: 0,
                latestBytes: nil, folder: item.set == catalog[1] ? .holdsFiles : .empty)
        }
        let mac = FakeMac(reading: AppleIntelligenceReading(sets: present, readAt: Date()), blocks: [])
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.downloadAgain()

        #expect(mac.subscribed.compactMap { $0["name"] as? String } == [catalog[0], catalog[4]].map(\.recovery.name))
        let aliases = mac.subscribed.first?["usageAliasCandidates"] as? [String: [String]]
        #expect(aliases == ["com.apple.Settings.AppleIntelligence": ["language_zh_TW", "language_zh", "language_en", "default"]])
        let spatial = mac.subscribed.last?["usageAliasCandidates"] as? [String: [String]]
        #expect(spatial == ["spatialPhotos.relive.main": ["default"]])
        #expect(store.lastOutcome == .downloadRequested)
        // Set 1 is on the Mac, so the record let go of it at the reading.
        #expect(Store.loadRemovedSetNames(from: defaults.defaults) == [catalog[0].name, catalog[4].name])
    }

    // MARK: A failure the user can read and report (#343)

    /// What the worker sends when macOS's asset service drops the connection.
    private static let droppedText = "NSCocoaErrorDomain 4097: Couldn’t communicate with a helper application."
        + "; NSDebugDescription: connection to service named com.apple.siri.uaf.subscription.service"

    private var lockReply: AppleIntelligenceWorker.Outcome {
        AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "com.apple.UnifiedAssetFramework -1: Could not eliminate as there are current locks",
            domain: "com.apple.UnifiedAssetFramework", code: -1)
    }

    private var dropped: AppleIntelligenceWorker.Outcome {
        AppleIntelligenceWorker.outcome(fromReply: [
            "ok": false,
            "error": Self.droppedText,
            "errorDomain": NSCocoaErrorDomain,
            "errorCode": 4097,
            "errorSummary": "NSCocoaErrorDomain 4097: Couldn’t communicate with a helper application.",
        ])
    }

    /// The domain and code come apart from the text, and a reply without them,
    /// as the worker's own refusals are, still reads.
    @Test func theWorkersReplyKeepsItsDomainAndCode() {
        #expect(!dropped.ok)
        #expect(dropped.domain == NSCocoaErrorDomain)
        #expect(dropped.code == 4097)
        #expect(dropped.error == Self.droppedText)

        let refusal = AppleIntelligenceWorker.outcome(fromReply: ["ok": false, "error": "refusing a reset with no asset sets"])
        #expect(!refusal.ok)
        #expect(refusal.domain == nil && refusal.code == nil && refusal.summary == nil)
        #expect(refusal.problem == "refusing a reset with no asset sets")

        let fine = AppleIntelligenceWorker.outcome(fromReply: ["ok": true, "result": ["assetType": "x"]])
        #expect(fine.ok)
        #expect(fine.result["assetType"] as? String == "x")
    }

    /// The row has room for one short reason. The three ways the connection to
    /// the service fails get plain words; any other error keeps its own first
    /// part and drops the userInfo, which is in the details.
    @Test func aConnectionFailureReadsInPlainWords() {
        #expect(dropped.problem == String(localized: "macOS's asset service stopped before it answered"))
        #expect(AppleIntelligenceWorker.connectionProblem(domain: NSCocoaErrorDomain, code: 4099)
            == String(localized: "macOS's asset service couldn't be reached"))
        #expect(AppleIntelligenceWorker.connectionProblem(domain: NSCocoaErrorDomain, code: 4101)
            == String(localized: "macOS's asset service sent an answer Purge couldn't read"))
        #expect(AppleIntelligenceWorker.connectionProblem(domain: NSCocoaErrorDomain, code: 260) == nil)
        #expect(AppleIntelligenceWorker.connectionProblem(domain: "com.apple.UnifiedAssetFramework", code: 4097) == nil)
        #expect(AppleIntelligenceWorker.connectionProblem(domain: nil, code: nil) == nil)

        let other = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:],
            error: "com.apple.UnifiedAssetFramework -1: The operation couldn’t be completed.; NSUnderlyingError: x",
            domain: "com.apple.UnifiedAssetFramework", code: -1,
            summary: "com.apple.UnifiedAssetFramework -1: The operation couldn’t be completed.")
        #expect(other.problem == "com.apple.UnifiedAssetFramework -1: The operation couldn’t be completed.")
    }

    /// The details open with the two versions a report needs, then every
    /// failed request as it came. Nothing failed, nothing to show.
    @Test func detailsCarryTheVersionsAndEveryFailedRequest() {
        let line = dropped.detailLine(op: "reset", subject: "com.apple.modelcatalog")
        #expect(line == "reset com.apple.modelcatalog: \(Self.droppedText)")
        let details = AppleIntelligenceWorker.details(
            [line, "reset b: y"], purge: "1.14.1 (42)", system: "Version 27.3 (Build 26C5035r)")
        #expect(details == "Purge 1.14.1 (42), macOS Version 27.3 (Build 26C5035r)\n\n\(line)\n\nreset b: y")
        #expect(AppleIntelligenceWorker.details([]) == nil)
    }

    /// The log keeps an error's words private: macOS chooses its description
    /// and its userInfo, and either could name a file. Only the domain and
    /// code go in the clear, with Purge's and the worker's own fixed sentences.
    @Test func theLogLeavesOutWhatMacOSWrote() {
        let withPath = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:],
            error: "NSCocoaErrorDomain 260: The file “/Users/someone/a” couldn’t be opened.; NSFilePath: /Users/someone/a",
            domain: NSCocoaErrorDomain, code: 260,
            summary: "NSCocoaErrorDomain 260: The file “/Users/someone/a” couldn’t be opened.")
        #expect(AppleIntelligenceWorker.clearText(of: withPath) == "NSCocoaErrorDomain 260")
        #expect(!AppleIntelligenceWorker.clearText(of: withPath).contains("/Users/"))

        let noCode = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "X: y; NSFilePath: /Users/someone/z", domain: "X")
        #expect(AppleIntelligenceWorker.clearText(of: noCode) == "X ?")

        let refusal = AppleIntelligenceWorker.outcome(fromReply: ["ok": false, "error": "refusing a reset with no asset sets"])
        #expect(AppleIntelligenceWorker.clearText(of: refusal) == "refusing a reset with no asset sets")
    }

    /// Download Again clears its old subscriptions first and ignores the
    /// answer, so that call alone is kept out of the error log. A failed
    /// release, lookup or download request is always logged as an error.
    @Test func onlyTheIgnoredUnsubscribeIsLoggedQuietly() {
        #expect(AppleIntelligenceWorker.ignoredFailures == ["unsubscribe"])
    }

    /// The log line names what the call was about.
    @Test func aCallIsNamedByItsSetsOrSubscriptions() {
        #expect(AppleIntelligenceWorker.subject(of: ["assetSet": "a"]) == "a")
        #expect(AppleIntelligenceWorker.subject(of: ["assetSets": ["a", "b"]]) == "a, b")
        #expect(AppleIntelligenceWorker.subject(of: ["subscriber": "s", "names": ["n"]]) == "n")
        #expect(AppleIntelligenceWorker.subject(of: ["subscriptions": [["name": "x"], ["name": "y"]]]) == "x, y")
        #expect(AppleIntelligenceWorker.subject(of: [:]) == "")
    }

    /// Run whole, as in the report: the profile is in, every release fails on
    /// the connection, and every set stays. The row gets the short reason, the
    /// details get each request in full, and nothing is booked as removed.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func aFailedReleaseSaysWhyAndKeepsTheWholeAnswer() async throws {
        // The profile blocks the two sets on the Mac, as a first removal leaves it.
        let mac = FakeMac(reading: reading(present: 2), blocks: [catalog[0].assetType, catalog[1].assetType])
        mac.failing["reset"] = dropped
        mac.serviceLog = ["2026-11-12 12:27:34.678 E  assetsubscriptiond[3692:1a06e6a] -[UAFXPCService operationWithConfig:completion:] x"]
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0], catalog[1]])

        // Each release is asked three times while the connection drops.
        #expect(mac.resets == [catalog[0].name, catalog[0].name, catalog[0].name,
                               catalog[1].name, catalog[1].name, catalog[1].name])
        guard case .someLeft(let removed, let left, let reason, let details) = store.lastOutcome else {
            Issue.record("expected someLeft, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(removed == 0)
        #expect(left == 2)
        #expect(reason == String(localized: "macOS's asset service stopped before it answered"))
        let text = try #require(details)
        #expect(text.hasPrefix("Purge "))
        #expect(text.contains("reset \(catalog[0].name): \(Self.droppedText)"))
        #expect(text.contains("reset \(catalog[1].name): \(Self.droppedText)"))
        #expect(text.contains("reset \(catalog[1].name) (try 3): \(Self.droppedText)"))
        // What the service logged meanwhile closes the details.
        #expect(text.hasSuffix("assetsubscriptiond log:\n\(mac.serviceLog.joined(separator: "\n"))"))
        #expect(store.lastOutcome?.details == details)
        #expect(store.nextSteps.count == 2)
        // Nothing went, so the undo button only lifts the block, and says so.
        #expect(store.undoTitle == String(localized: "Remove Profile"))
        #expect(store.offersDownloadAgain)
        #expect(mac.recorded.isEmpty)
        #expect(Store.loadRemovedSetNames(from: defaults.defaults).isEmpty)
    }

    /// Set 0's release fails on the connection but the set is gone afterwards;
    /// set 1's release is accepted but the set is still listed. The row must
    /// not quote set 0's error for set 1: the reason comes from a set that
    /// stayed, and with nothing failed for it there are no details.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func theReasonComesFromASetThatStayed() async throws {
        let mac = FakeMac(reading: reading(present: 2), blocks: catalog.map(\.assetType))
        mac.failingResets[catalog[0].name] = dropped
        mac.readingAfterReset = AppleIntelligenceReading(
            sets: reading(present: 2).sets.map { item in
                item.set == catalog[0]
                    ? AppleIntelligenceSetReading(set: item.set, recordsOnDisk: 0, eliminating: 0, latestBytes: 0, folder: .empty)
                    : item
            },
            readAt: Date())
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0], catalog[1]])

        #expect(store.lastOutcome == .someLeft(
            removed: 1, left: 1,
            reason: String(localized: "macOS hasn't finished removing them"),
            details: nil))
        #expect(mac.recorded == [[catalog[0]]])
    }

    /// macOS can say "current locks" after the description, in the part the
    /// short reason leaves out. It still counts as a lock reply, so the row
    /// says the models are in use rather than quoting the error.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func aLockReplyIsFoundInTheWholeAnswer() async throws {
        let mac = FakeMac(reading: reading(present: 1), blocks: catalog.map(\.assetType))
        mac.failing["reset"] = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:],
            error: "com.apple.UnifiedAssetFramework -1: The operation couldn’t be completed.; NSDebugDescription: current locks",
            domain: "com.apple.UnifiedAssetFramework", code: -1,
            summary: "com.apple.UnifiedAssetFramework -1: The operation couldn’t be completed.")
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0]])

        guard case .someLeft(_, _, let reason, let details) = store.lastOutcome else {
            Issue.record("expected someLeft, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(reason == String(localized: "macOS says these are still in use"))
        #expect(details?.contains("current locks") == true)
        // A lock reply is not a dropped connection, so it is not asked again
        // at once; the set gets one more request after the watch.
        #expect(mac.resets == [catalog[0].name, catalog[0].name])
    }

    /// Run whole: macOS turns the download request down. The row gets the
    /// short reason and the details name the subscriptions that were asked for.
    @Test(.enabled(if: Store.isSupported, "the download is gated to macOS 27 on Apple silicon"))
    @MainActor func aFailedDownloadRequestKeepsTheWholeAnswer() async throws {
        let mac = FakeMac(reading: reading(present: 0), blocks: [])
        mac.failing["subscribe"] = dropped
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.downloadAgain()

        guard case .downloadRequestFailed(let reason, let details) = store.lastOutcome else {
            Issue.record("expected downloadRequestFailed, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(reason == String(localized: "macOS's asset service stopped before it answered"))
        let text = try #require(details)
        #expect(text.contains("subscribe \(catalog.map(\.recovery.name).joined(separator: ", ")): \(Self.droppedText)"))
        #expect(mac.subscribeCalls == Store.connectionAttempts)
        // The profile is gone and some sets are not, so the button to ask again stays.
        #expect(store.offersDownloadAgain || store.reading?.isAnythingPresent == false)
        #expect(store.undoTitle == String(localized: "Download Again"))
        #expect(store.nextSteps.count == 2)
    }

    /// Only a failure with more to say than its line has details.
    @Test func onlyFailuresHaveDetails() {
        #expect(AppleIntelligenceOutcome.someLeft(removed: 0, left: 1, reason: "r", details: "d").details == "d")
        #expect(AppleIntelligenceOutcome.notReady("r", details: "d").details == "d")
        #expect(AppleIntelligenceOutcome.downloadRequestFailed("r", details: "d").details == "d")
        #expect(AppleIntelligenceOutcome.notReady("r", details: nil).details == nil)
        #expect(AppleIntelligenceOutcome.removed(sets: 1, freedShownBytes: nil, freedRawBytes: nil).details == nil)
        #expect(AppleIntelligenceOutcome.profileNotInstalled.details == nil)
        #expect(AppleIntelligenceOutcome.downloadRequested.details == nil)
        #expect(AppleIntelligenceOutcome.downloadNotStarted.details == nil)
        #expect(AppleIntelligenceOutcome.profileStillInstalled.details == nil)
    }

    /// The report on the 27.3 beta: the service dropped the connection. One
    /// drop is asked again after a pause, and a release that then goes
    /// through is a plain removal with nothing to report.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func aDroppedConnectionIsAskedAgain() async throws {
        let start = reading(present: 1)
        let mac = FakeMac(reading: start, blocks: catalog.map(\.assetType))
        mac.resetReplies[catalog[0].name] = [dropped]
        mac.readingAfterReset = without(catalog[0], from: start)
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0]])

        #expect(mac.resets == [catalog[0].name, catalog[0].name])
        guard case .removed(let sets, _, _) = store.lastOutcome else {
            Issue.record("expected removed, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(sets == 1)
        #expect(mac.recorded == [[catalog[0]]])
        #expect(store.nextSteps.isEmpty)
    }

    /// Only a broken connection is asked again. Any other answer is the
    /// service's own, and asking again won't change it.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func aRefusalIsNotAskedAgain() async throws {
        let mac = FakeMac(reading: reading(present: 1), blocks: catalog.map(\.assetType))
        mac.failing["reset"] = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "com.apple.UnifiedAssetFramework 5: no",
            domain: "com.apple.UnifiedAssetFramework", code: 5, summary: "com.apple.UnifiedAssetFramework 5: no")
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0]])

        #expect(mac.resets == [catalog[0].name])
        guard case .someLeft(_, _, let reason, _) = store.lastOutcome else {
            Issue.record("expected someLeft, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(reason == "com.apple.UnifiedAssetFramework 5: no")
    }

    /// macOS answers before it deletes. A set that goes a few readings after
    /// the answer is removed, not "stayed", as 1.14 reported it.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func aSetThatGoesSecondsAfterTheAnswerCountsAsRemoved() async throws {
        let start = reading(present: 1)
        let mac = FakeMac(reading: start, blocks: catalog.map(\.assetType))
        mac.readingAfterReset = without(catalog[0], from: start)
        mac.readsBeforeDeleted = 5
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0]])

        guard case .removed = store.lastOutcome else {
            Issue.record("expected removed, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(mac.recorded == [[catalog[0]]])
    }

    /// A lock reply that clears on the second request (RemoveMacAI's issue 56).
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func aLockReplyGetsOneMoreRequest() async throws {
        let start = reading(present: 1)
        let mac = FakeMac(reading: start, blocks: catalog.map(\.assetType))
        mac.resetReplies[catalog[0].name] = [AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "com.apple.UnifiedAssetFramework -1: Could not eliminate as there are current locks",
            domain: "com.apple.UnifiedAssetFramework", code: -1)]
        // The first request leaves the set; the second one removes it.
        mac.readingAfterReset = without(catalog[0], from: start)
        mac.resetsBeforeDeleted = 2
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0]])

        #expect(mac.resets == [catalog[0].name, catalog[0].name])
        guard case .removed = store.lastOutcome else {
            Issue.record("expected removed, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(mac.recorded == [[catalog[0]]])
    }

    /// Stop holds during the second round of lock replies too: once it is
    /// clicked, no set gets another release request.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func stopHoldsDuringTheLockRetry() async throws {
        let mac = FakeMac(reading: reading(present: 2), blocks: catalog.map(\.assetType))
        let locked = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "com.apple.UnifiedAssetFramework -1: Could not eliminate as there are current locks",
            domain: "com.apple.UnifiedAssetFramework", code: -1)
        mac.failingResets[catalog[0].name] = locked
        mac.failingResets[catalog[1].name] = locked
        let store = Store(defaults: defaults.defaults, services: mac.services)
        // Stop is clicked while the first set is asked a second time.
        mac.afterReset = { count in if count == 3 { store.stop() } }

        await store.remove(sets: [catalog[0], catalog[1]])

        #expect(mac.resets == [catalog[0].name, catalog[1].name, catalog[0].name])
        #expect(!store.isStopping)
        guard case .someLeft(0, 2, _, _) = store.lastOutcome else {
            Issue.record("expected someLeft, got \(String(describing: store.lastOutcome))")
            return
        }
    }

    /// A Stop clicked while the only set's first release is out is kept, so a
    /// set that answered with a lock gets no second request.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func stopDuringTheLastReleaseHoldsBeforeTheLockRetry() async throws {
        let mac = FakeMac(reading: reading(present: 1), blocks: catalog.map(\.assetType))
        mac.failingResets[catalog[0].name] = lockReply
        let store = Store(defaults: defaults.defaults, services: mac.services)
        mac.afterReset = { count in if count == 1 { store.stop() } }

        await store.remove(sets: [catalog[0]])

        #expect(mac.resets == [catalog[0].name])
        #expect(!store.isStopping)
    }

    /// A Stop clicked in the pause after a dropped connection sends nothing more.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func stopDuringThePauseSendsNothingMore() async throws {
        let mac = FakeMac(reading: reading(present: 2), blocks: catalog.map(\.assetType))
        mac.failingResets[catalog[0].name] = dropped
        let store = Store(defaults: defaults.defaults, services: mac.services)
        mac.duringPause = { store.stop() }

        await store.remove(sets: [catalog[0], catalog[1]])

        #expect(mac.resets == [catalog[0].name])
    }

    /// Only sets macOS took, or answered with a lock, are watched. A set it
    /// refused, or one never sent because of a Stop, is not booked as Purge's
    /// removal when it goes later for another reason.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func refusedAndUnsentSetsAreNotBookedLater() async throws {
        let start = reading(present: 2)
        let mac = FakeMac(reading: start, blocks: catalog.map(\.assetType))
        mac.failingResets[catalog[0].name] = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "com.apple.UnifiedAssetFramework -1: unknown asset set",
            domain: "com.apple.UnifiedAssetFramework", code: -1)
        let store = Store(defaults: defaults.defaults, services: mac.services)
        mac.afterReset = { count in if count == 1 { store.stop() } }

        await store.remove(sets: [catalog[0], catalog[1]])
        #expect(mac.resets == [catalog[0].name])
        #expect(store.arrivalPollInterval == nil)

        mac.current.set(reading(present: 0))
        await store.refresh()
        await store.refresh()

        #expect(mac.recorded.isEmpty)
        guard case .someLeft(0, 2, _, _) = store.lastOutcome else {
            Issue.record("expected someLeft, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(Store.loadRemovedSetNames(from: defaults.defaults).isEmpty)
    }

    /// A reading that couldn't see the folder, or a single reading, never books
    /// a watched set. Two readings in a row that saw it gone do.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func oneBadReadingBooksNothing() async throws {
        let start = reading(present: 1)
        let mac = FakeMac(reading: start, blocks: catalog.map(\.assetType))
        let store = Store(defaults: defaults.defaults, services: mac.services)
        await store.remove(sets: [catalog[0]])

        let unreadable = AppleIntelligenceReading(
            sets: start.sets.map { item in
                item.set == catalog[0]
                    ? AppleIntelligenceSetReading(set: item.set, recordsOnDisk: 0, eliminating: 0, latestBytes: nil, folder: .unknown)
                    : item
            },
            readAt: Date())
        mac.current.set(unreadable)
        await store.refresh()
        await store.refresh()
        #expect(mac.recorded.isEmpty)

        // Gone once, then back: the count starts again.
        mac.current.set(without(catalog[0], from: start))
        await store.refresh()
        mac.current.set(start)
        await store.refresh()
        mac.current.set(without(catalog[0], from: start))
        await store.refresh()
        #expect(mac.recorded.isEmpty)

        await store.refresh()
        #expect(mac.recorded == [[catalog[0]]])
    }

    /// A stopped removal still watches the set macOS took, and books it when
    /// it goes later. The set never sent stays counted as left.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func aStoppedRemovalBooksAnAcceptedSetLater() async throws {
        let start = reading(present: 2)
        let mac = FakeMac(reading: start, blocks: catalog.map(\.assetType))
        let store = Store(defaults: defaults.defaults, services: mac.services)
        mac.afterReset = { count in if count == 1 { store.stop() } }

        await store.remove(sets: [catalog[0], catalog[1]])
        #expect(store.lastOutcome == .stopped(removed: 0, left: 2))
        #expect(store.arrivalPollInterval == 30)

        mac.current.set(without(catalog[0], from: start))
        await store.refresh()
        await store.refresh()

        #expect(store.lastOutcome == .stopped(removed: 1, left: 1))
        #expect(mac.recorded == [[catalog[0]]])
        #expect(store.arrivalPollInterval == nil)
    }

    /// With the profile gone, Download Again shows again only after a request
    /// failed, never while one macOS accepted is still arriving.
    @Test(.enabled(if: Store.isSupported, "the download is gated to macOS 27 on Apple silicon"))
    @MainActor func downloadAgainHidesWhileARequestArrives() async throws {
        Store.saveRemovedSetNames([catalog[0].name, catalog[1].name], to: defaults.defaults)
        // One of the two is back already, the other not yet.
        let mac = FakeMac(reading: reading(present: 1), blocks: [])
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.downloadAgain()
        #expect(store.lastOutcome == .downloadRequested)
        #expect(!store.offersDownloadAgain)

        mac.subscribeReplies = [dropped, dropped, dropped]
        await store.downloadAgain()
        guard case .downloadRequestFailed = store.lastOutcome else {
            Issue.record("expected downloadRequestFailed, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(store.offersDownloadAgain)
    }

    /// A Stop left from a removal that ended at the lookup does not cut a
    /// later download request's retries.
    @Test(.enabled(if: Store.isSupported, "the download is gated to macOS 27 on Apple silicon"))
    @MainActor func aStaleStopDoesNotCutDownloadRetries() async throws {
        // No profile, so Download Again has no System Settings step.
        let mac = FakeMac(reading: reading(present: 1), blocks: [])
        mac.failing["asset-type"] = AppleIntelligenceWorker.Outcome(ok: false, result: [:], error: "lookup failed")
        let store = Store(defaults: defaults.defaults, services: mac.services)
        mac.afterLookup = { store.stop() }

        await store.remove(sets: [catalog[0]])
        #expect(!store.isStopping)
        #expect(mac.resets.isEmpty)

        mac.subscribeReplies = [dropped]
        await store.downloadAgain()
        #expect(mac.subscribeCalls == 2)
        #expect(store.lastOutcome == .downloadRequested)
    }

    /// Two sets stayed and only one goes later: that one is booked on its own,
    /// and the other is still watched.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func oneOfTwoLeftSetsIsBookedOnItsOwn() async throws {
        let start = reading(present: 2)
        let mac = FakeMac(reading: start, blocks: catalog.map(\.assetType))
        let store = Store(defaults: defaults.defaults, services: mac.services)
        await store.remove(sets: [catalog[0], catalog[1]])
        guard case .someLeft(0, 2, _, _) = store.lastOutcome else {
            Issue.record("expected someLeft, got \(String(describing: store.lastOutcome))")
            return
        }

        mac.current.set(without(catalog[1], from: start))
        await store.refresh()
        await store.refresh()

        guard case .someLeft(1, 1, _, _) = store.lastOutcome else {
            Issue.record("expected someLeft, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(mac.recorded == [[catalog[1]]])
        #expect(store.arrivalPollInterval == 30)

        mac.current.set(reading(present: 0))
        await store.refresh()
        await store.refresh()
        #expect(mac.recorded == [[catalog[1]], [catalog[0]]])
        guard case .removed(2, _, _) = store.lastOutcome else {
            Issue.record("expected removed, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(store.arrivalPollInterval == nil)
    }

    @Test func aLateRemovalMovesTheCounts() {
        #expect(Store.outcomeAfterLateRemoval(.someLeft(removed: 1, left: 2, reason: "r", details: nil), sets: 1)
            == .someLeft(removed: 2, left: 1, reason: "r", details: nil))
        #expect(Store.outcomeAfterLateRemoval(.someLeft(removed: 1, left: 2, reason: "r", details: nil), sets: 2)
            == .removed(sets: 3, freedShownBytes: nil, freedRawBytes: nil))
        #expect(Store.outcomeAfterLateRemoval(.stopped(removed: 0, left: 2), sets: 1) == .stopped(removed: 1, left: 1))
        #expect(Store.outcomeAfterLateRemoval(.downloadRequested, sets: 1) == nil)
        #expect(Store.outcomeAfterLateRemoval(nil, sets: 1) == nil)
    }

    /// Deletion safety: the retries add requests, never names. Every release
    /// still names exactly one set, a release with no set is never sent (the
    /// service reads that as every asset on the Mac), and a set outside the
    /// confirmation is never named, however the service answers.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func retriesStillNameOneConfirmedSetPerRequest() async throws {
        let mac = FakeMac(reading: reading(present: 3), blocks: catalog.map(\.assetType))
        mac.failingResets[catalog[0].name] = dropped
        mac.failingResets[catalog[1].name] = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "com.apple.UnifiedAssetFramework -1: Could not eliminate as there are current locks",
            domain: "com.apple.UnifiedAssetFramework", code: -1)
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0], catalog[1]])

        #expect(mac.resetRequests.count == Store.connectionAttempts + 2)
        #expect(mac.resetRequests.allSatisfy { $0.count == 1 })
        #expect(Set(mac.resets) == [catalog[0].name, catalog[1].name])
        #expect(!mac.resets.contains(catalog[2].name))
    }

    /// A set that stayed and went later, while the row still watched: the
    /// failure gives way to "Removed", and the history books the set.
    @Test(.enabled(if: Store.isSupported, "the removal is gated to macOS 27 on Apple silicon"))
    @MainActor func aSetThatGoesAfterTheWatchIsBookedLater() async throws {
        let start = reading(present: 1)
        let mac = FakeMac(reading: start, blocks: catalog.map(\.assetType))
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0]])
        guard case .someLeft = store.lastOutcome else {
            Issue.record("expected someLeft, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(store.arrivalPollInterval == 30)
        #expect(mac.recorded.isEmpty)

        mac.current.set(without(catalog[0], from: start))
        await store.refresh()
        // One reading is not enough: it could be a failed read.
        #expect(mac.recorded.isEmpty)
        await store.refresh()

        guard case .removed(let sets, _, _) = store.lastOutcome else {
            Issue.record("expected removed, got \(String(describing: store.lastOutcome))")
            return
        }
        #expect(sets == 1)
        #expect(mac.recorded == [[catalog[0]]])
        #expect(Store.loadRemovedSetNames(from: defaults.defaults) == [catalog[0].name])
        #expect(store.arrivalPollInterval == nil)
    }

    /// A download request that drops once is asked again and goes through.
    @Test(.enabled(if: Store.isSupported, "the download is gated to macOS 27 on Apple silicon"))
    @MainActor func aDroppedDownloadRequestIsAskedAgain() async throws {
        let mac = FakeMac(reading: reading(present: 0), blocks: [])
        mac.subscribeReplies = [dropped]
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.downloadAgain()

        #expect(mac.subscribeCalls == 2)
        #expect(store.lastOutcome == .downloadRequested)
    }

    @Test func onlyABrokenConnectionCountsAsDropped() {
        for code in [4097, 4099, 4101] {
            #expect(AppleIntelligenceWorker.Outcome(
                ok: false, result: [:], error: "x", domain: NSCocoaErrorDomain, code: code).isConnectionDrop)
        }
        #expect(!AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "x", domain: NSCocoaErrorDomain, code: 260).isConnectionDrop)
        #expect(!AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "x", domain: "com.apple.UnifiedAssetFramework", code: -1).isConnectionDrop)
        #expect(!AppleIntelligenceWorker.Outcome(ok: false, result: [:], error: "No answer in 120 seconds").isConnectionDrop)
    }

    /// Download Again asks for nothing when nothing of Purge's is missing, so
    /// it reads Remove Profile then; and it stays offered after a failed
    /// request, when the profile is already gone, while a removed set is missing.
    @Test func theUndoButtonSaysWhatItDoes() {
        #expect(Store.undoOnlyLiftsBlock(isProfileInstalled: true, hasSetsToRequest: false))
        #expect(!Store.undoOnlyLiftsBlock(isProfileInstalled: true, hasSetsToRequest: true))
        #expect(!Store.undoOnlyLiftsBlock(isProfileInstalled: false, hasSetsToRequest: true))

        let partial = Store.offers(reading: reading(present: 2), isProfileInstalled: false, hasSetsToRequest: true)
        #expect(partial.remove && partial.downloadAgain)
        let untouched = Store.offers(reading: reading(present: 5), isProfileInstalled: false, hasSetsToRequest: false)
        #expect(untouched.remove && !untouched.downloadAgain)
        let unread = Store.offers(reading: nil, isProfileInstalled: false, hasSetsToRequest: true)
        #expect(!unread.downloadAgain)
    }

    /// A failure says what to try, naming the button the row shows. A stop or
    /// a success has nothing to try.
    @Test func aFailureSaysWhatToTry() {
        let left = AppleIntelligenceOutcome.someLeft(removed: 0, left: 3, reason: "r", details: nil)
        let steps = left.nextSteps(undoTitle: "Remove Profile")
        #expect(steps.count == 2)
        #expect(steps[1].contains("Remove Profile"))
        #expect(AppleIntelligenceOutcome.downloadRequestFailed("r", details: nil).nextSteps(undoTitle: "x").count == 2)
        #expect(AppleIntelligenceOutcome.stopped(removed: 1, left: 1).nextSteps(undoTitle: "x").isEmpty)
        #expect(AppleIntelligenceOutcome.stopped(removed: 1, left: 1).details == nil)
        #expect(AppleIntelligenceOutcome.removed(sets: 1, freedShownBytes: nil, freedRawBytes: nil)
            .nextSteps(undoTitle: "x").isEmpty)
        #expect(AppleIntelligenceOutcome.notReady("r", details: "d").nextSteps(undoTitle: "x").isEmpty)
    }

    /// The service's log is cut to entries, newest last, at a readable length.
    @Test func theServiceLogKeepsEntriesOnly() {
        let long = "2026-11-12 12:27:34.678 E  assetsubscriptiond[1:2] " + String(repeating: "a", count: 600)
        let text = """
        Timestamp               Ty Process[PID:TID]
        2026-11-12 12:27:34.670 Df assetsubscriptiond[1:2] +[UAFXPCService daemonLaunchTasks] Running UAF daemon launch tasks
            continuation of a message
        \(long)
        """
        let lines = AppleIntelligenceServiceLog.parse(text)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("Running UAF daemon launch tasks"))
        #expect(lines[1].count == AppleIntelligenceServiceLog.maxLineLength + 1)
        let many = (0..<50).map { "2026-11-12 12:00:\($0) Df x" }.joined(separator: "\n")
        let kept = AppleIntelligenceServiceLog.parse(many)
        #expect(kept.count == AppleIntelligenceServiceLog.maxLines)
        #expect(kept.last == "2026-11-12 12:00:49 Df x")
        #expect(AppleIntelligenceServiceLog.parse("").isEmpty)
    }

    /// The service's log closes the details when there is one.
    @Test func detailsEndWithTheServiceLog() {
        let details = AppleIntelligenceWorker.details(
            ["reset a: x"], serviceLog: ["l1", "l2"], purge: "1.15.0 (43)", system: "Version 27.3")
        #expect(details == "Purge 1.15.0 (43), macOS Version 27.3\n\nreset a: x\n\nassetsubscriptiond log:\nl1\nl2")
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
