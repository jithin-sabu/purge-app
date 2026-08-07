import Foundation
import Testing
@testable import Purge

/// The Large Files walk must not run on the main thread. `Task.detached` is not
/// enough on its own: with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an
/// unannotated scanner type makes its own `static func run` MainActor-isolated,
/// so `await Self.run(…)` hops straight back to main and the whole
/// home-directory sweep — every `resourceValues`, `getxattr` and directory read
/// — lands on the UI thread. Nothing fails to compile when that happens, which
/// is why this is a runtime probe.
///
/// Verified to fail: removing `nonisolated` from `LargeFileScanner` makes this
/// test report `true`.
@Suite("Scanners stay off the main thread")
struct ScannerOffMainTests {
    @MainActor
    @Test func largeFileWalkDoesNotRunOnTheMainThread() async {
        LargeFileScanner.ranOnMainThread = nil

        // A huge floor means nothing is yielded, so the test does not depend on
        // what happens to be on disk. The walk still starts, and the probe is
        // set on the first directory entry it touches.
        let stream = LargeFileScanner().scanStream(minBytes: .max, staleDays: 0)
        let consumer = Task { @MainActor in
            for await _ in stream {}
        }
        for _ in 0..<200 where LargeFileScanner.ranOnMainThread == nil {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        consumer.cancel()

        #expect(LargeFileScanner.ranOnMainThread != nil, "probe never fired — the walk did not start")
        #expect(
            LargeFileScanner.ranOnMainThread == false,
            "the filesystem walk ran on the main thread — check `nonisolated` on LargeFileScanner"
        )
    }
}
