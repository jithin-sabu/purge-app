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
    /// it, so `remove` and `downloadAgain` can run whole in a test.
    @MainActor
    private final class FakeMac {
        var reading: AppleIntelligenceReading
        var blocks: [String]
        var siriLanguage: String? = "zh-TW"
        var resets: [String] = []
        var subscribed: [[String: Any]] = []
        var recorded: [[AppleIntelligenceModelSet]] = []
        /// What the worker answers for an op instead of success.
        var failing: [String: AppleIntelligenceWorker.Outcome] = [:]
        /// What the worker answers for a release of one set, by set name.
        var failingResets: [String: AppleIntelligenceWorker.Outcome] = [:]
        /// What the Mac reads as once a release has been asked for.
        var readingAfterReset: AppleIntelligenceReading?

        /// The current reading, behind a lock: the store reads it off the main actor.
        private final class ReadingBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: AppleIntelligenceReading
            init(_ value: AppleIntelligenceReading) { self.value = value }
            func get() -> AppleIntelligenceReading { lock.withLock { value } }
            func set(_ new: AppleIntelligenceReading) { lock.withLock { value = new } }
        }

        init(reading: AppleIntelligenceReading, blocks: [String]) {
            self.reading = reading
            self.blocks = blocks
        }

        var services: Store.Services {
            var services = Store.Services()
            let current = ReadingBox(reading)
            services.read = { current.get() }
            services.installedBlocks = { [blocks] in blocks }
            services.siriLanguage = { [siriLanguage] in siriLanguage }
            services.definedAliasValues = { _ in ["language_en", "language_zh", "language_zh_TW"] }
            services.recordRemoval = { [self] sets, _, _ in self.recorded.append(sets) }
            services.runWorker = { [self] op, input, _ in
                switch op {
                case "asset-type":
                    let name = input["assetSet"] as? String
                    let type = AppleIntelligenceCatalog.sets.first { $0.name == name }?.assetType
                    return AppleIntelligenceWorker.Outcome(ok: true, result: ["assetType": type as Any], error: nil)
                case "reset":
                    let names = input["assetSets"] as? [String] ?? []
                    self.resets += names
                    if let after = self.readingAfterReset { current.set(after) }
                    return names.first.flatMap { self.failingResets[$0] } ?? self.failing[op]
                        ?? AppleIntelligenceWorker.Outcome(ok: true, result: [:], error: nil)
                case "subscribe":
                    self.subscribed = input["subscriptions"] as? [[String: Any]] ?? []
                    return self.failing[op] ?? AppleIntelligenceWorker.Outcome(ok: true, result: [:], error: nil)
                default:
                    return AppleIntelligenceWorker.Outcome(ok: true, result: [:], error: nil)
                }
            }
            return services
        }
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
    /// recorded sets that are absent, with each language alias resolved for
    /// the Siri language, and leaves a present set alone.
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
        let aliases = mac.subscribed.first?["usageAliases"] as? [String: String]
        #expect(aliases == ["com.apple.Settings.AppleIntelligence": "language_zh_TW"])
        let spatial = mac.subscribed.last?["usageAliases"] as? [String: String]
        #expect(spatial == ["spatialPhotos.relive.main": "default"])
        #expect(store.lastOutcome == .downloadRequested)
        // Set 1 is on the Mac, so the record let go of it at the reading.
        #expect(Store.loadRemovedSetNames(from: defaults.defaults) == [catalog[0].name, catalog[4].name])
    }

    // MARK: A failure the user can read and report (#343)

    /// What the worker sends when macOS's asset service drops the connection.
    private static let droppedText = "NSCocoaErrorDomain 4097: Couldn’t communicate with a helper application."
        + "; NSDebugDescription: connection to service named com.apple.siri.uaf.subscription.service"

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

    /// The log keeps an error's userInfo private: macOS chooses what goes in
    /// it, and it could name a file. The domain, code and description go in
    /// the clear, and so do Purge's and the worker's own fixed sentences.
    @Test func theLogLeavesOutWhatMacOSPutInUserInfo() {
        let withPath = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:],
            error: "NSCocoaErrorDomain 260: The file couldn’t be opened.; NSFilePath: /Users/someone/Library/x",
            domain: NSCocoaErrorDomain, code: 260,
            summary: "NSCocoaErrorDomain 260: The file couldn’t be opened.")
        #expect(AppleIntelligenceWorker.clearText(of: withPath) == "NSCocoaErrorDomain 260: The file couldn’t be opened.")
        #expect(!AppleIntelligenceWorker.clearText(of: withPath).contains("/Users/"))

        let noSummary = AppleIntelligenceWorker.Outcome(
            ok: false, result: [:], error: "X 7: y; NSFilePath: /Users/someone/z", domain: "X", code: 7)
        #expect(AppleIntelligenceWorker.clearText(of: noSummary) == "X 7")

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
        let mac = FakeMac(reading: reading(present: 2), blocks: catalog.map(\.assetType))
        mac.failing["reset"] = dropped
        let store = Store(defaults: defaults.defaults, services: mac.services)

        await store.remove(sets: [catalog[0], catalog[1]])

        #expect(mac.resets == [catalog[0].name, catalog[1].name])
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
        #expect(store.lastOutcome?.details == details)
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
