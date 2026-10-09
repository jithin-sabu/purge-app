import Foundation
@testable import Purge

/// Scans that record what they were asked for. App Caches scans and the Full Disk
/// Access steps can be held open until the test finishes them.
@MainActor
final class FakeScans {
    var hasAccess = false
    var holdsGeneral = false
    var holdsDeveloper = false
    var holdsFullAccessSteps = false
    private(set) var generalAccesses: [ScanAccess] = []
    private(set) var developerAccesses: [ScanAccess] = []
    /// Full Disk Access steps as they start, plus anything a test adds.
    var log: [String] = []
    /// Every scan in the order it started: App Caches with its access, and the steps.
    private(set) var events: [String] = []

    private var heldGeneral: [AsyncStream<CacheScanEvent>.Continuation] = []
    private var heldDeveloper: [AsyncStream<DeveloperScanEvent>.Continuation] = []
    private var heldSteps: [CheckedContinuation<Void, Never>] = []
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

    /// Releases every held scan and stops holding new ones, so a scan that starts
    /// after this call cannot hang the test either.
    func cleanUp() {
        holdsGeneral = false
        holdsDeveloper = false
        holdsFullAccessSteps = false
        heldGeneral.forEach { $0.finish() }
        heldDeveloper.forEach { $0.finish() }
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
                    continuation.finish()
                }
                return stream
            },
            projects: { _ in Self.finishedStream() },
            fullAccessStep: { step, _ in
                self.log.append("step \(step.rawValue)")
                self.events.append("step \(step.rawValue)")
                if self.holdsFullAccessSteps {
                    await withCheckedContinuation { self.heldSteps.append($0) }
                }
            }
        )
    }

    private static func finishedStream() -> AsyncStream<DeveloperScanEvent> {
        let (stream, continuation) = AsyncStream<DeveloperScanEvent>.makeStream()
        continuation.finish()
        return stream
    }
}
