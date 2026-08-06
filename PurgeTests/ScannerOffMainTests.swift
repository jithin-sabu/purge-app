import Foundation
import Testing
@testable import Purge

/// Lock-protected recorder written from a background executor.
private final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sawMainThread = false
    private var samples = 0

    func record() {
        lock.lock()
        defer { lock.unlock() }
        if Thread.isMainThread { sawMainThread = true }
        samples += 1
    }

    var hitMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawMainThread
    }

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

/// Covers the concurrency risk introduced by moving the scans off the main actor.
///
/// Background: the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
/// `CacheScanner`, `DevScanner`, `LargeFileScanner`, and `AIModelScanner` were implicitly
/// main-actor isolated and the `Task.detached` inside each `scanStream` hopped straight
/// back to the main actor — every scan walked the filesystem on the UI thread. They are
/// now explicitly `nonisolated`.
///
/// That isolation property itself is deliberately **not** asserted here. It is only
/// observable from inside the awaited callee, which would mean adding a hook to
/// production code purely for the test; and in Swift 5 language mode isolation on
/// synchronous code is diagnosed but not enforced at runtime, so the obvious
/// "construct it from a detached task" test passes either way and would be a test that
/// cannot fail. It was verified instead with a temporary in-app probe logging
/// `Thread.isMainThread` at the top of each scanner's run function (`true` before the
/// change, `false` after) — repeat that if the isolation is ever in doubt.
///
/// What *is* worth pinning down is the consequence: work that used to be main-actor
/// serialised now runs concurrently on background executors.
@Suite("Off-main scanning")
struct ScannerOffMainTests {
    /// `CacheScanner` resolves friendly app names during its scan, which goes through
    /// Launch Services. That used to happen on the main actor and now does not, so this
    /// guards against it being main-thread-only in practice or returning inconsistent
    /// results under the concurrent access the scan now subjects it to.
    @Test func appDisplayNameIsSafeToResolveConcurrentlyOffMain() async {
        let recorder = ThreadRecorder()
        let bundleID = "com.apple.finder"
        let expected = await Task.detached { appDisplayName(forBundleID: bundleID) }.value
        #expect(expected != nil)

        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    recorder.record()
                    return appDisplayName(forBundleID: bundleID)
                }
            }
            for await name in group {
                #expect(name == expected)
            }
        }

        #expect(recorder.sampleCount == 16)
        #expect(!recorder.hitMainThread)
    }

    /// `CacheItem` resolves and stores its `id` and `standardizedPaths` at init instead of
    /// recomputing them per access — `standardizedFileURL` stats the filesystem, and doing
    /// it inside SwiftUI body evaluation issued thousands of syscalls per render. The
    /// stored values must match what the computed versions produced.
    @Test func cacheItemPrecomputesIdentityConsistently() {
        let path = URL(fileURLWithPath: "/tmp/./purge-test/../purge-test/cache")
        let location = CacheLocation(
            path: path,
            sizeBytes: 512,
            lastModified: Date(),
            folderName: "com.example.test"
        )
        let info = SafetyInfo(
            level: .safe, headline: "h", explanation: "e", recoverySteps: "r", reinstallCommand: nil
        )

        let ungrouped = CacheItem(definitionKey: nil, location: location, appName: "T", safetyInfo: info)
        #expect(ungrouped.id == "path:\(path.standardizedFileURL.path)")
        #expect(ungrouped.standardizedPaths == [path.standardizedFileURL.path])
        // The stored path is what `sizeBytes(at:)` matches against, including when the
        // caller passes a non-standardized URL.
        #expect(ungrouped.sizeBytes(at: path) == 512)

        let grouped = CacheItem(
            definitionKey: "some-key", locations: [location], appName: "T", safetyInfo: info
        )
        #expect(grouped.id == "def:some-key")
        #expect(grouped.standardizedPaths == [path.standardizedFileURL.path])

        // Re-deriving through `withLocations` must not lose the identity.
        #expect(grouped.withLocations([location]).id == grouped.id)
        #expect(ungrouped.withLocations([location]).id == ungrouped.id)
    }

    /// The sidebar hero's counting animation is tuned to the scan flush cadence, so the
    /// exposed seconds value must actually match `ScanCoalesce.flushInterval`. A wrong
    /// `Duration` decomposition here would silently desynchronise the digit roll.
    @MainActor
    @Test func scanFlushIntervalIsExposedInSeconds() {
        #expect(abs(PurgeStore.scanFlushIntervalSeconds - 0.14) < 0.0001)
    }

    /// `DevTool.id` is likewise stored now; it must still be order-independent across
    /// `paths`, because that is what made it a stable identity in the first place.
    @Test func devToolIdIsStableRegardlessOfPathOrder() {
        let a = URL(fileURLWithPath: "/tmp/purge-test/a")
        let b = URL(fileURLWithPath: "/tmp/purge-test/b")
        let info = SafetyInfo(
            level: .safe, headline: "h", explanation: "e", recoverySteps: "r", reinstallCommand: nil
        )
        func tool(_ paths: [URL]) -> DevTool {
            DevTool(
                definitionKey: "k", toolName: "T", paths: paths,
                sizeBytes: 0, isDetected: true, safetyInfo: info
            )
        }
        #expect(tool([a, b]).id == tool([b, a]).id)
        #expect(tool([a]).id != tool([b]).id)
    }
}
