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
/// records there have not been measured.
@MainActor
final class AppleIntelligenceModelStore: ObservableObject {
    static let shared = AppleIntelligenceModelStore()

    enum Phase: Equatable {
        case idle
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

    private var latestPass = 0
    private var waitCancelled = false

    /// How long the user gets to act in System Settings before Purge gives up.
    static let settingsWait: TimeInterval = 10 * 60

    /// macOS 27 on Apple silicon, where the spike was run.
    nonisolated static let isSupported: Bool = {
        let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(version) else { return false }
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        return machine == "arm64"
    }()

    var isBusy: Bool { phase != .idle }
    var isWaitingInSettings: Bool { phase == .waitingForProfileInstall || phase == .waitingForProfileRemoval }
    var isProfileInstalled: Bool { !installedBlocks.isEmpty }

    /// Whether the row has anything to say: models on disk, a block in place, or
    /// a removal this session. A Mac with none of those shows no row at all.
    var isRelevant: Bool {
        Self.isSupported && ((reading?.isAnythingPresent ?? false) || isProfileInstalled || lastOutcome != nil)
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
        }
        return fresh
    }

    func refreshAccounts() async {
        otherAccounts = await AppleIntelligenceAccounts.others()
    }

    func cancelWaiting() {
        waitCancelled = true
    }

    // MARK: Remove

    /// Blocks the downloads, releases every set still present, and records what
    /// the volume gave back. Stops at the first step the Mac does not pass.
    func remove() async {
        guard !isBusy, Self.isSupported else { return }
        lastOutcome = nil
        let before = await readLatest()
        let targets = before.present.map(\.set)
        guard !targets.isEmpty else { return }

        // Every set has to map to the catalog's asset type on this macOS, or a
        // renamed set would be sent to the service under a stale name.
        phase = .measuring
        for set in targets {
            let mapping = await AppleIntelligenceWorker.run("asset-type", ["assetSet": set.name], timeout: 30)
            guard mapping.ok, mapping.result["assetType"] as? String == set.assetType else {
                phase = .idle
                lastOutcome = .notReady(mapping.ok
                    ? String(localized: "This version of macOS names \(set.title) differently, so Purge left them alone.")
                    : mapping.problem)
                return
            }
        }

        // 1. The block first, so nothing comes back between release and the reading.
        let blockTypes = targets.map(\.assetType)
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
            let installed = await waitUntil {
                let now = AppleIntelligenceDownloadBlock.installedBlocks()
                return blockTypes.allSatisfy { now.contains($0) }
            }
            installedBlocks = AppleIntelligenceDownloadBlock.installedBlocks()
            guard installed else {
                phase = .idle
                lastOutcome = waitCancelled ? .cancelled : .profileNotInstalled
                return
            }
        }

        // 2. Release, one set per request so one the service rejects does not stop the rest.
        phase = .releasing
        let shownBefore = VolumeCapacityReader.read()?.availableBytes
        let rawBefore = VolumeRawCapacityReader.readAvailableBytes()
        var failures: [String: String] = [:]
        var lockReplies: [AppleIntelligenceModelSet] = []
        for set in targets {
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
        let freedShown = await Self.settledGain(since: shownBefore, read: { VolumeCapacityReader.read()?.availableBytes })
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
            let reason = failures.values.first ?? String(localized: "macOS hasn't finished removing them")
            lastOutcome = .someLeft(removed: removed, left: left, reason: reason)
        }
        if removed > 0 {
            CleanupHistoryStore.shared.appendAppleIntelligenceRemoval(
                sets: targets.filter { set in !(after.sets.first { $0.set.name == set.name }?.isPresent ?? true) },
                bytesBefore: before,
                freedShownBytes: freedShown,
                freedRawBytes: freedRaw
            )
        }
    }

    // MARK: Download again

    /// Lifts the block, then asks the asset service for the sets. macOS
    /// downloads them in the background; the row shows them arriving.
    func downloadAgain() async {
        guard !isBusy, Self.isSupported else { return }
        lastOutcome = nil
        _ = await readLatest()
        if isProfileInstalled {
            phase = .waitingForProfileRemoval
            openProfilesPane()
            let removed = await waitUntil { AppleIntelligenceDownloadBlock.installedBlocks().isEmpty }
            installedBlocks = AppleIntelligenceDownloadBlock.installedBlocks()
            guard removed else {
                phase = .idle
                lastOutcome = waitCancelled ? .cancelled : .profileStillInstalled
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
        lastOutcome = subscribe.ok ? .downloadRequested : .downloadRequestFailed(subscribe.problem)
        _ = await readLatest()
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

    /// Free space gained since `before`, once two readings a second apart agree,
    /// as `LocalSnapshotStore` does it. Nil when the figure never settles or
    /// stays under the noise floor.
    nonisolated static func settledGain(since before: Int64?, read: @Sendable () -> Int64?) async -> Int64? {
        guard let before else { return nil }
        let noise = VolumeCapacityReader.noiseFloorBytes
        var previous: Int64?
        for attempt in 0..<15 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            guard let after = read() else { return nil }
            let gained = after - before
            if let previous, abs(gained - previous) < noise {
                return gained >= noise ? gained : nil
            }
            previous = gained
        }
        return nil
    }
}
