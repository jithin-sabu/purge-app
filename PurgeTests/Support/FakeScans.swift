import Foundation
@testable import Purge

/// Scans that record what they were asked for. App Caches scans, project discovery,
/// the git status check and the Full Disk Access steps can be held open until the
/// test finishes them.
///
/// Exclusions and safety choices the store saves go to the test run's scratch
/// folder (`TestHost.supportDirectory()`), which every test in the run shares, so
/// use paths no other test uses.
@MainActor
final class FakeScans {
    var hasAccess = false
    var holdsGeneral = false
    var holdsDeveloper = false
    var holdsProjects = false
    var holdsLargeFiles = false
    var holdsGitStatus = false
    var holdsFullAccessSteps = false
    var holdsEverythingElse = false
    /// Yielded by an Everything else walk as soon as it starts. A held walk then
    /// stays open until it is let go.
    var everythingElseEvents: [EverythingElseMeasureEvent] = []
    /// What the Command-line tools scan returns (#225).
    var commandLineTools = CommandLineToolScanResult()
    private(set) var everythingElseAccesses: [ScanAccess] = []
    /// Yielded by a Dev Tools scan that is not held, before it finishes.
    var developerEvents: [DeveloperScanEvent] = []
    /// Yielded by project discovery as soon as it starts. A held discovery then
    /// stays open until it is let go.
    var projectEvents: [DeveloperScanEvent] = []
    /// Yielded by a Large Files walk as soon as it starts. A held walk then stays
    /// open until it is let go; one that is not held ends with `.finished`.
    var largeFileEvents: [LargeFileScanEvent] = []
    /// How many Large Files walks have started. The AI model passes list nothing.
    private(set) var largeFileScanCount = 0
    /// What the git status check answers, by standardized path, once it returns.
    /// A path with no answer comes back clean, as a folder outside any repository does.
    var gitAnswers: [String: GitWorktreeStatus] = [:]
    private(set) var generalAccesses: [ScanAccess] = []
    private(set) var developerAccesses: [ScanAccess] = []
    private(set) var projectScanCount = 0
    /// The paths of every git status check, in the order the checks started.
    private(set) var gitStatusRequests: [[URL]] = []
    /// Git status checks that have returned their answers to the store.
    private(set) var gitStatusAnswerCount = 0
    /// Full Disk Access steps as they start, plus anything a test adds.
    var log: [String] = []
    /// Every scan in the order it started: App Caches with its access, and the steps.
    private(set) var events: [String] = []

    private var heldGeneral: [AsyncStream<CacheScanEvent>.Continuation] = []
    private var heldDeveloper: [AsyncStream<DeveloperScanEvent>.Continuation] = []
    private var heldProjects: [AsyncStream<DeveloperScanEvent>.Continuation] = []
    private var heldLargeFiles: [AsyncStream<LargeFileScanEvent>.Continuation] = []
    private var heldGitStatus: [CheckedContinuation<Void, Never>] = []
    private var heldSteps: [CheckedContinuation<Void, Never>] = []
    private var heldEverythingElse: [AsyncStream<EverythingElseMeasureEvent>.Continuation] = []
    private let suite = ThrowawayDefaults()

    func makeStore() -> PurgeStore {
        let store = PurgeStore(defaults: defaults, scanSources: sources)
        store.refreshPermission()
        return store
    }

    /// The throwaway defaults the store reads and writes, for seeding saved records.
    var defaults: UserDefaults { suite.defaults }

    func finishHeldSteps() {
        let steps = heldSteps
        heldSteps = []
        steps.forEach { $0.resume() }
    }

    func finishHeldGeneral() {
        let held = heldGeneral
        heldGeneral = []
        held.forEach { $0.finish() }
    }

    func finishHeldProjects() {
        let held = heldProjects
        heldProjects = []
        held.forEach { $0.finish() }
    }

    /// Lets every held Large Files walk run to its end.
    func finishHeldLargeFiles() {
        let held = heldLargeFiles
        heldLargeFiles = []
        for continuation in held {
            continuation.yield(.finished(LargeFileScanSummary(minBytes: 0)))
            continuation.finish()
        }
    }

    /// Sends more events to a held Everything else walk.
    func yieldEverythingElse(_ events: [EverythingElseMeasureEvent]) {
        for continuation in heldEverythingElse {
            events.forEach { continuation.yield($0) }
        }
    }

    func finishHeldEverythingElse() {
        let held = heldEverythingElse
        heldEverythingElse = []
        held.forEach { $0.finish() }
    }

    /// Lets every held git status check return, with `gitAnswers` as they are now.
    func finishHeldGitStatus() {
        let held = heldGitStatus
        heldGitStatus = []
        held.forEach { $0.resume() }
    }

    /// Releases every held scan and stops holding new ones, so a scan that starts
    /// after this call cannot hang the test either.
    func cleanUp() {
        holdsGeneral = false
        holdsDeveloper = false
        holdsProjects = false
        holdsLargeFiles = false
        holdsGitStatus = false
        holdsFullAccessSteps = false
        holdsEverythingElse = false
        finishHeldEverythingElse()
        finishHeldGeneral()
        heldDeveloper.forEach { $0.finish() }
        finishHeldProjects()
        finishHeldLargeFiles()
        finishHeldGitStatus()
        finishHeldSteps()
        suite.remove()
    }

    private var sources: ScanSources {
        ScanSources(
            fullDiskAccess: { self.hasAccess },
            general: { access in
                self.generalAccesses.append(access)
                self.events.append("general \(access)")
                let (stream, continuation) = AsyncStream<CacheScanEvent>.makeStream()
                if self.holdsGeneral {
                    self.heldGeneral.append(continuation)
                } else {
                    continuation.finish()
                }
                return stream
            },
            developer: { access in
                self.developerAccesses.append(access)
                let (stream, continuation) = AsyncStream<DeveloperScanEvent>.makeStream()
                if self.holdsDeveloper {
                    self.heldDeveloper.append(continuation)
                } else {
                    self.developerEvents.forEach { continuation.yield($0) }
                    continuation.finish()
                }
                return stream
            },
            projects: { _ in
                self.projectScanCount += 1
                let (stream, continuation) = AsyncStream<DeveloperScanEvent>.makeStream()
                self.projectEvents.forEach { continuation.yield($0) }
                if self.holdsProjects {
                    self.heldProjects.append(continuation)
                } else {
                    continuation.finish()
                }
                return stream
            },
            largeFiles: { minBytes, _ in
                self.largeFileScanCount += 1
                self.events.append("largeFiles")
                let (stream, continuation) = AsyncStream<LargeFileScanEvent>.makeStream()
                self.largeFileEvents.forEach { continuation.yield($0) }
                if self.holdsLargeFiles {
                    self.heldLargeFiles.append(continuation)
                } else {
                    continuation.yield(.finished(LargeFileScanSummary(minBytes: minBytes)))
                    continuation.finish()
                }
                return stream
            },
            aiModels: { _, _, _, _ in
                let (stream, continuation) = AsyncStream<LargeFile>.makeStream()
                continuation.finish()
                return stream
            },
            fullAccessStep: { step, _ in
                self.log.append("step \(step.rawValue)")
                self.events.append("step \(step.rawValue)")
                if self.holdsFullAccessSteps {
                    await withCheckedContinuation { self.heldSteps.append($0) }
                }
            },
            everythingElse: { access in
                self.everythingElseAccesses.append(access)
                self.events.append("everythingElse \(access)")
                let (stream, continuation) = AsyncStream<EverythingElseMeasureEvent>.makeStream()
                self.everythingElseEvents.forEach { continuation.yield($0) }
                if self.holdsEverythingElse {
                    self.heldEverythingElse.append(continuation)
                } else {
                    continuation.finish()
                }
                return stream
            },
            commandLineTools: {
                self.events.append("commandLineTools")
                return self.commandLineTools
            },
            gitStatuses: { urls in
                self.gitStatusRequests.append(urls)
                if self.holdsGitStatus {
                    await withCheckedContinuation { self.heldGitStatus.append($0) }
                }
                var answers: [String: GitWorktreeStatus] = [:]
                for url in urls {
                    let key = url.standardizedFileURL.path
                    answers[key] = self.gitAnswers[key] ?? .clean
                }
                self.gitStatusAnswerCount += 1
                return answers
            }
        )
    }
}
