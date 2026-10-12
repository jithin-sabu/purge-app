import AppKit
import Combine
import Foundation

/// The Apple Intelligence models the Overview shows, and the two things Purge
/// can do with them: Remove, and Download Again (issue #133).
///
/// Remove installs a profile that blocks the downloads, asks Apple's asset
/// service to release each set, and measures what the volume gave back.
/// Download Again waits for the user to remove that profile, then asks the
/// service for the sets. Both private calls run in a throwaway child process,
/// `io.getpurge.assetworker`. Nothing here ever runs on its own: not scheduled,
/// not part of Clean Safe Items.
///
/// macOS 27 only: on 15 and 26 Apple's own switch releases the models, and the
/// records there have not been measured. Not 28 either until it is checked: a
/// renamed request key there could make the service read a release as naming
/// no sets, which it takes as every asset on the Mac.
@MainActor
final class AppleIntelligenceModelStore: ObservableObject {
    static let shared = AppleIntelligenceModelStore()

    enum Phase: Equatable {
        case idle
        /// Checking that every set still maps to its asset type before removing.
        case checking
        /// The profile is open in System Settings; waiting for the user to install it.
        case waitingForProfileInstall
        case releasing
        case measuring
        /// System Settings is open on the profile; waiting for the user to remove it.
        case waitingForProfileRemoval
        case requestingDownload
    }

    /// Nil until the first reading lands.
    @Published private(set) var reading: AppleIntelligenceReading?
    @Published private(set) var hasTriedReading = false
    /// Asset types the installed profile blocks; empty when none is installed.
    @Published private(set) var installedBlocks: [String] = []
    @Published private(set) var otherAccounts: [AppleIntelligenceAccount] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastOutcome: AppleIntelligenceOutcome?
    /// The user asked a removal to stop. It takes effect between sets, because a
    /// request already sent to the service can't be taken back.
    @Published private(set) var isStopping = false

    private var latestPass = 0
    private var waitCancelled = false
    /// The sets as last read, and when they last changed, so a download request
    /// is considered over once nothing more arrives.
    private var previousSets: [AppleIntelligenceSetReading]?
    private var lastArrivalChange = Date()
    /// The Download Again request macOS accepted, until its models settle. It
    /// is kept in defaults because closing the window quits Purge in on-demand
    /// mode: without it a relaunch before the models arrive forgets the request,
    /// and the row, its progress and its retry go with it.
    private var downloadRequest: DownloadRequest? {
        didSet { Self.saveDownloadRequest(downloadRequest, to: defaults) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        downloadRequest = Self.loadDownloadRequest(from: defaults)
    }

    /// How long the user gets to act in System Settings before Purge gives up.
    static let settingsWait: TimeInterval = 10 * 60

    /// macOS 27 on Apple silicon, where the spike was run.
    nonisolated static let isSupported: Bool = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        return isSupported(os: ProcessInfo.processInfo.operatingSystemVersion, machine: machine)
    }()

    /// Every 27.x, and nothing before or after it. Point releases keep the
    /// service's keys; a new major version needs the spike run again first.
    nonisolated static func isSupported(os: OperatingSystemVersion, machine: String) -> Bool {
        os.majorVersion == 27 && machine == "arm64"
    }

    var isBusy: Bool { phase != .idle }
    var isWaitingInSettings: Bool { phase == .waitingForProfileInstall || phase == .waitingForProfileRemoval }
    var isProfileInstalled: Bool { !installedBlocks.isEmpty }
    /// A removal can stop while it checks the sets or between releases.
    var canStop: Bool { phase == .checking || phase == .releasing }

    /// Remove while any set is still on the Mac. Download Again whenever the
    /// block is installed, even beside Remove after a partial removal, since it
    /// is the only way back in the app; and when nothing is on the Mac.
    var offersRemove: Bool { Self.offers(reading: reading, isProfileInstalled: isProfileInstalled).remove }
    var offersDownloadAgain: Bool { Self.offers(reading: reading, isProfileInstalled: isProfileInstalled).downloadAgain }

    nonisolated static func offers(
        reading: AppleIntelligenceReading?,
        isProfileInstalled: Bool
    ) -> (remove: Bool, downloadAgain: Bool) {
        let present = reading?.isAnythingPresent
        return (present == true, isProfileInstalled || present == false)
    }

    /// Whether the row has anything to say: models on disk, a block in place, or
    /// a removal this session or a download still pending. A Mac with none of
    /// those shows no row at all, even though Download Again would work there:
    /// it asks for all five sets, so it is not offered to a Mac that never had them.
    var isRelevant: Bool {
        Self.isSupported && Self.isRelevant(reading: reading, isProfileInstalled: isProfileInstalled, lastOutcome: lastOutcome)
    }

    nonisolated static func isRelevant(
        reading: AppleIntelligenceReading?,
        isProfileInstalled: Bool,
        lastOutcome: AppleIntelligenceOutcome?
    ) -> Bool {
        (reading?.isAnythingPresent ?? false) || isProfileInstalled || lastOutcome != nil
    }

    /// Models arriving after Download Again: the block is gone and files are landing.
    var isDownloading: Bool {
        guard case .downloadRequested = lastOutcome else { return false }
        return !isProfileInstalled
    }

    func refresh() async {
        guard Self.isSupported else { return }
        _ = await readLatest()
    }

    private func readLatest() async -> AppleIntelligenceReading {
        latestPass += 1
        let pass = latestPass
        let fresh = await Task.detached(priority: .utility) { AppleIntelligenceModelReader.read() }.value
        let blocks = AppleIntelligenceDownloadBlock.installedBlocks()
        hasTriedReading = true
        if pass == latestPass {
            reading = fresh
            installedBlocks = blocks
            noteArrivals(fresh)
        }
        return fresh
    }

    /// After Download Again, the row says "downloading" and re-reads every 20
    /// seconds until the sets stop changing. See `downloadWatch`.
    private func noteArrivals(_ fresh: AppleIntelligenceReading) {
        if previousSets != fresh.sets {
            lastArrivalChange = Date()
        }
        previousSets = fresh.sets
        guard let request = downloadRequest else { return }
        let next = Self.arrivalOutcome(
            current: lastOutcome,
            request: request,
            now: fresh.sets,
            lastArrivalChange: lastArrivalChange,
            at: Date()
        )
        lastOutcome = next.outcome
        if next.requestDone { downloadRequest = nil }
    }

    /// What the row says after a reading while a request is pending, and
    /// whether the request is over and can be forgotten.
    ///
    /// No outcome means Purge relaunched since the request, so it picks up
    /// where it was: still watching, or "nothing has arrived yet" with Download
    /// Again there to retry. A request with nothing arrived for a week is
    /// dropped, so a Mac that never downloads doesn't keep the row for good.
    nonisolated static func arrivalOutcome(
        current: AppleIntelligenceOutcome?,
        request: DownloadRequest,
        now sets: [AppleIntelligenceSetReading],
        lastArrivalChange: Date,
        at now: Date
    ) -> (outcome: AppleIntelligenceOutcome?, requestDone: Bool) {
        let arrived = hasArrivals(since: request.sets, now: sets)
        let pending = pendingOutcome(requestedAt: request.requestedAt, now: now)
        switch current ?? pending {
        case .downloadRequested:
            // Not read for a week, as in menu bar mode with the Overview never
            // opened: drop it now rather than say "nothing yet" first.
            if !arrived, now.timeIntervalSince(request.requestedAt) >= downloadRequestExpiry {
                return (nil, true)
            }
            // Settling counts from the last change; giving up counts from the request,
            // so a change to a set that was already there doesn't push it back.
            switch downloadWatch(
                anythingArrived: arrived,
                quietFor: now.timeIntervalSince(arrived ? lastArrivalChange : request.requestedAt)
            ) {
            case .keepWatching: return (.downloadRequested, false)
            case .settled: return (nil, true)
            case .nothingArrived: return (.downloadNotStarted, false)
            }
        case .downloadNotStarted:
            // macOS got to it later: watch again until the rest settle, then the
            // row goes back to showing the size.
            if arrived { return (.downloadRequested, false) }
            if pending == nil { return (nil, true) }
            return (.downloadNotStarted, false)
        case .none:
            // Too old to pick up again.
            return (nil, true)
        case .removed, .someLeft, .profileNotInstalled, .notReady,
             .profileStillInstalled, .downloadRequestFailed:
            // Another action has taken over from the request.
            return (current, true)
        }
    }

    /// What a request of this age says on its own: still watching for the first
    /// fifteen minutes, then "nothing has arrived yet" until it expires. Nil once
    /// it expires, or when it is dated in the future because the clock moved back.
    nonisolated static func pendingOutcome(requestedAt: Date, now: Date) -> AppleIntelligenceOutcome? {
        let age = now.timeIntervalSince(requestedAt)
        guard age >= 0, age < downloadRequestExpiry else { return nil }
        return age < downloadStartWait ? .downloadRequested : .downloadNotStarted
    }

    /// A week covers a Mac that waits for power, Wi-Fi or a quiet moment before
    /// macOS downloads. Past that, turning Apple Intelligence on in System
    /// Settings asks for the models the usual way.
    nonisolated static let downloadRequestExpiry: TimeInterval = 7 * 24 * 60 * 60

    /// How often the row re-reads while it waits for models: every 20 seconds
    /// while they arrive, and once a minute after Purge has said nothing came,
    /// so a late download still shows without leaving the Overview.
    var arrivalPollInterval: TimeInterval? {
        if isDownloading { return 20 }
        if case .downloadNotStarted = lastOutcome { return 60 }
        return nil
    }

    /// Whether any set gained records or bytes, or appeared, since `before`.
    nonisolated static func hasArrivals(
        since before: [DownloadRequest.SetAtRequest],
        now: [AppleIntelligenceSetReading]
    ) -> Bool {
        now.contains { item in
            guard let old = before.first(where: { $0.name == item.set.name }) else { return item.isPresent }
            return item.recordsOnDisk > old.recordsOnDisk
                || (item.latestBytes ?? 0) > (old.latestBytes ?? 0)
                || (item.isPresent && !old.isPresent)
        }
    }

    enum DownloadWatch: Equatable {
        case keepWatching
        /// Models arrived and nothing changed for a while: done.
        case settled
        /// Nothing at all arrived: stop saying "downloading".
        case nothingArrived
    }

    /// A set can take minutes to start after the one before it, so arrivals
    /// count as over only after five quiet minutes. With nothing arrived, the
    /// watch gives up after fifteen, for a Mac that is offline or that macOS
    /// decided not to download to.
    nonisolated static let downloadSettleTime: TimeInterval = 5 * 60
    nonisolated static let downloadStartWait: TimeInterval = 15 * 60

    nonisolated static func downloadWatch(anythingArrived: Bool, quietFor: TimeInterval) -> DownloadWatch {
        if anythingArrived {
            return quietFor >= downloadSettleTime ? .settled : .keepWatching
        }
        return quietFor >= downloadStartWait ? .nothingArrived : .keepWatching
    }

    func refreshAccounts() async {
        otherAccounts = await AppleIntelligenceAccounts.others()
    }

    func cancelWaiting() {
        waitCancelled = true
        SettingsGuidePanel.shared.hide()
    }

    /// Stops a removal before its next request to the service.
    func stop() {
        guard canStop else { return }
        isStopping = true
    }

    // MARK: Remove

    /// Blocks the downloads, releases every set still present, and records what
    /// the volume gave back. Stops at the first step the Mac does not pass.
    func remove() async {
        guard !isBusy, Self.isSupported else { return }
        // Busy before the first await, so a second click can't start another run.
        phase = .checking
        isStopping = false
        lastOutcome = nil
        downloadRequest = nil
        let before = await readLatest()
        let targets = before.present.map(\.set)
        guard !targets.isEmpty else {
            phase = .idle
            return
        }

        // Every set has to map to the catalog's asset type on this macOS, or a
        // renamed set would be sent to the service under a stale name.
        for set in targets {
            // Nothing has been changed yet, so a stop here leaves no trace.
            guard !isStopping else {
                phase = .idle
                isStopping = false
                return
            }
            let mapping = await AppleIntelligenceWorker.run("asset-type", ["assetSet": set.name], timeout: 30)
            guard mapping.ok, mapping.result["assetType"] as? String == set.assetType else {
                phase = .idle
                lastOutcome = .notReady(mapping.ok
                    ? String(localized: "This version of macOS names \(set.title) differently, so Purge left them alone.")
                    : mapping.problem)
                return
            }
        }
        guard !isStopping else {
            phase = .idle
            isStopping = false
            return
        }

        // 1. The block first, so nothing comes back between release and the reading.
        // The profile replaces any earlier one of Purge's, so it carries every
        // block already installed as well as today's sets.
        let blockTypes = AppleIntelligenceDownloadBlock.typesToBlock(
            installed: installedBlocks, adding: targets.map(\.assetType))
        if !blockTypes.allSatisfy({ installedBlocks.contains($0) }) {
            do {
                let url = AppleIntelligenceDownloadBlock.profileFileURL
                try AppleIntelligenceDownloadBlock.profileData(blocking: blockTypes).write(to: url)
                NSWorkspace.shared.open(url)
            } catch {
                phase = .idle
                lastOutcome = .notReady(String(localized: "Purge couldn't write the profile: \(error.localizedDescription)"))
                return
            }
            phase = .waitingForProfileInstall
            try? await Task.sleep(for: .seconds(1))
            openProfilesPane()
            SettingsGuidePanel.shared.show(.installProfile) { [weak self] in self?.cancelWaiting() }
            let installed = await waitUntil {
                let now = AppleIntelligenceDownloadBlock.installedBlocks()
                return blockTypes.allSatisfy { now.contains($0) }
            }
            SettingsGuidePanel.shared.hide()
            // System Settings keeps its own copy once opened; the file in Downloads
            // would only linger.
            try? FileManager.default.removeItem(at: AppleIntelligenceDownloadBlock.profileFileURL)
            installedBlocks = AppleIntelligenceDownloadBlock.installedBlocks()
            guard installed else {
                phase = .idle
                // A cancel is the user changing their mind: the row goes back to
                // how it was, with nothing to report.
                lastOutcome = waitCancelled ? nil : .profileNotInstalled
                return
            }
        }

        // 2. Release, one set per request so one the service rejects does not stop the rest.
        phase = .releasing
        let shownBefore = VolumeCapacityReader.read()?.availableBytes
        let rawBefore = VolumeRawCapacityReader.readAvailableBytes()
        var failures: [String: String] = [:]
        var lockReplies: [AppleIntelligenceModelSet] = []
        var stopped = false
        for set in targets {
            if isStopping {
                stopped = true
                break
            }
            let reset = await AppleIntelligenceWorker.run("reset", ["assetSets": [set.name]], timeout: 120)
            if reset.ok { continue }
            // macOS can answer "current locks" and still have removed the set
            // (pared, RemoveMacAI issue 15, and the spike all saw it), so those
            // are judged by their folders below.
            if reset.problem.contains("current locks") {
                lockReplies.append(set)
            } else {
                failures[set.name] = reset.problem
            }
        }

        // 3. What is left, and what the volume gave back once it settled.
        phase = .measuring
        isStopping = false
        let freedShown = await VolumeCapacityReader.settledGain(since: shownBefore, attempts: 15) {
            VolumeCapacityReader.read()?.availableBytes
        }
        let after = await readLatest()
        let rawAfter = VolumeRawCapacityReader.readAvailableBytes()
        let freedRaw: Int64? = {
            guard let rawBefore, let rawAfter else { return nil }
            let gained = rawAfter - rawBefore
            return gained >= VolumeCapacityReader.noiseFloorBytes ? gained : nil
        }()
        var left = 0
        for set in targets {
            let stillThere = after.sets.first { $0.set.name == set.name }?.isPresent ?? true
            if stillThere {
                left += 1
                if lockReplies.contains(set) {
                    failures[set.name] = String(localized: "macOS says these are still in use")
                }
            }
        }
        let removed = targets.count - left
        phase = .idle
        if left == 0 {
            lastOutcome = .removed(sets: removed, freedShownBytes: freedShown, freedRawBytes: freedRaw)
        } else {
            // The service's own words over Purge's generic one, and a stable
            // pick when several sets stayed.
            let generic = String(localized: "macOS says these are still in use")
            let reasons = failures.sorted { $0.key < $1.key }.map(\.value)
            // if/else rather than a ternary around the closure: Xcode 26.6 on CI
            // crashed on that shape before.
            let reason: String
            if stopped {
                reason = String(localized: "you stopped the removal")
            } else {
                reason = reasons.first { $0 != generic } ?? reasons.first ?? String(localized: "macOS hasn't finished removing them")
            }
            lastOutcome = .someLeft(removed: removed, left: left, reason: reason)
        }
        if removed > 0 {
            CleanupHistoryStore.shared.appendAppleIntelligenceRemoval(
                sets: targets.filter { set in !(after.sets.first { $0.set.name == set.name }?.isPresent ?? true) },
                bytesBefore: before,
                freedShownBytes: freedShown
            )
        }
    }

    // MARK: Download again

    /// Lifts the block, then asks the asset service for the sets. macOS
    /// downloads them in the background; the row shows them arriving.
    func downloadAgain() async {
        guard !isBusy, Self.isSupported else { return }
        // Busy before the first await, so a second click can't start another run.
        phase = .measuring
        lastOutcome = nil
        downloadRequest = nil
        let setsAtRequest = await readLatest().sets
        if isProfileInstalled {
            phase = .waitingForProfileRemoval
            openProfilesPane()
            SettingsGuidePanel.shared.show(.removeProfile) { [weak self] in self?.cancelWaiting() }
            let removed = await waitUntil { AppleIntelligenceDownloadBlock.installedBlocks().isEmpty }
            SettingsGuidePanel.shared.hide()
            installedBlocks = AppleIntelligenceDownloadBlock.installedBlocks()
            guard removed else {
                phase = .idle
                lastOutcome = waitCancelled ? nil : .profileStillInstalled
                return
            }
        }
        phase = .requestingDownload
        let sets = AppleIntelligenceCatalog.sets
        let names = sets.map(\.recovery.name)
        // A reset can leave an older request of ours behind, and the service
        // skips an identical subscription, so clear ours first. One that was
        // never there answers with an error, which is fine.
        _ = await AppleIntelligenceWorker.run("unsubscribe", [
            "subscriber": AppleIntelligenceCatalog.subscriber, "names": names,
        ], timeout: 60)
        let subscriptions: [[String: Any]] = sets.map { set -> [String: Any] in
            [
                "name": set.recovery.name,
                "usageAliases": set.recovery.usageAliases,
                "assetSetUsages": set.recovery.assetSetUsages,
            ]
        }
        let subscribe = await AppleIntelligenceWorker.run("subscribe", [
            "subscriber": AppleIntelligenceCatalog.subscriber, "subscriptions": subscriptions,
        ], timeout: 60)
        phase = .idle
        if subscribe.ok {
            downloadRequest = DownloadRequest(requestedAt: Date(), sets: setsAtRequest)
            lastOutcome = .downloadRequested
        } else {
            lastOutcome = .downloadRequestFailed(subscribe.problem)
        }
        lastArrivalChange = Date()
        _ = await readLatest()
    }

    // MARK: Pending request

    /// A Download Again request as it is kept between launches.
    nonisolated struct DownloadRequest: Codable, Equatable, Sendable {
        /// One set when Download Again was asked for. After a partial removal
        /// some are already on the Mac, so arrivals are judged against these,
        /// not against whether anything is present.
        nonisolated struct SetAtRequest: Codable, Equatable, Sendable {
            let name: String
            let recordsOnDisk: Int
            let latestBytes: Int64?
            let isPresent: Bool

            init(_ reading: AppleIntelligenceSetReading) {
                name = reading.set.name
                recordsOnDisk = reading.recordsOnDisk
                latestBytes = reading.latestBytes
                isPresent = reading.isPresent
            }
        }

        /// When macOS accepted the request.
        let requestedAt: Date
        let sets: [SetAtRequest]

        init(requestedAt: Date, sets: [AppleIntelligenceSetReading]) {
            self.requestedAt = requestedAt
            self.sets = sets.map(SetAtRequest.init)
        }
    }

    nonisolated static let downloadRequestKey = "appleIntelligence.downloadRequest"

    nonisolated static func loadDownloadRequest(from defaults: UserDefaults) -> DownloadRequest? {
        guard let data = defaults.data(forKey: downloadRequestKey) else { return nil }
        return try? JSONDecoder().decode(DownloadRequest.self, from: data)
    }

    nonisolated static func saveDownloadRequest(_ request: DownloadRequest?, to defaults: UserDefaults) {
        if let request, let data = try? JSONEncoder().encode(request) {
            defaults.set(data, forKey: downloadRequestKey)
        } else {
            defaults.removeObject(forKey: downloadRequestKey)
        }
    }

    // MARK: Helpers

    private func openProfilesPane() {
        for string in AppleIntelligenceDownloadBlock.profilesPaneURLs {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Polls once a second until `condition` holds, the user cancels, or the
    /// settings wait runs out.
    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        waitCancelled = false
        let deadline = Date().addingTimeInterval(Self.settingsWait)
        while Date() < deadline, !waitCancelled {
            if condition() { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
}
