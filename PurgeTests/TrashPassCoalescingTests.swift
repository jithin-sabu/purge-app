import Foundation
import Testing
@testable import Purge

/// Stands in for `du`: counts passes, records how many overlap, and reports the
/// size it is set to when the pass started.
private final class FakeDu: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var _maxActive = 0
    private var _passes = 0
    private var _bytes: Int64 = 1000
    private let delay: TimeInterval
    /// With `holdsFirstPass`, the first pass waits here once it has read the size,
    /// until `releaseFirstPass()`.
    private let firstPassGate: DispatchSemaphore?

    init(delay: TimeInterval, holdsFirstPass: Bool = false) {
        self.delay = delay
        firstPassGate = holdsFirstPass ? DispatchSemaphore(value: 0) : nil
    }

    /// Safe to call more than once, and before the first pass has started.
    func releaseFirstPass() {
        firstPassGate?.signal()
    }

    var maxActive: Int { lock.withLock { _maxActive } }
    var passes: Int { lock.withLock { _passes } }

    func setBytes(_ bytes: Int64) {
        lock.withLock { _bytes = bytes }
    }

    func measure(_ urls: [URL]) -> [String: Int64] {
        let (bytes, pass): (Int64, Int) = lock.withLock {
            _passes += 1
            active += 1
            _maxActive = max(_maxActive, active)
            return (_bytes, _passes)
        }
        if pass == 1 {
            firstPassGate?.wait()
        }
        Thread.sleep(forTimeInterval: delay)
        lock.withLock { active -= 1 }
        return Dictionary(uniqueKeysWithValues: urls.map { ($0.path, bytes / Int64(urls.count)) })
    }
}

/// The Trash is sized one pass at a time, and refreshes asked for while one runs
/// share one more pass after it (#190). Every caller still gets a pass that
/// started after it asked.
@Suite("Trash size passes")
@MainActor
struct TrashPassCoalescingTests {
    /// No deadline of its own. A pass is sized in a utility-priority task, and in a
    /// full parallel test run on a shared CI runner that task can wait longer than
    /// any fixed deadline. Two seconds failed in #174's CI, and ten seconds failed
    /// on main afterwards. The test's time limit stops a real hang, and cancelling
    /// ends the wait.
    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The 30-second poll is off, so every pass a test counts is one it asked for.
    private func makeStore(_ urls: [URL], _ du: FakeDu) -> TrashStore {
        TrashStore(trashURLs: urls, measureSizes: { du.measure($0) }, pollsWhileActive: false)
    }

    private func makeTrash() throws -> [URL] {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-trash-passes-\(UUID().uuidString)", isDirectory: true)
        let urls = [parent.appendingPathComponent("a"), parent.appendingPathComponent("b")]
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.appendingPathComponent("item").path, contents: Data("x".utf8))
        }
        return urls
    }

    @Test func aBurstOfRefreshesNeverOverlaps() async throws {
        let urls = try makeTrash()
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        let du = FakeDu(delay: 0.15)
        let store = makeStore(urls, du)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask { @MainActor in await store.refresh(trigger: "test-\(i)") }
            }
        }

        #expect(du.maxActive == 1)
        // The pass `init` started, plus at most one shared by the five calls.
        #expect((1...2).contains(du.passes))
        #expect(store.trashBytes == 1000)
        #expect(store.access == .readable)
    }

    /// A call made while a pass runs waits for a pass that started after it, so it
    /// sees what the Trash held when it asked, not before.
    @Test(.timeLimit(.minutes(2)))
    func aCallDuringAPassGetsALaterPass() async throws {
        let urls = try makeTrash()
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        let du = FakeDu(delay: 0.2, holdsFirstPass: true)
        // A pass held forever would keep a pool thread, so let it go on every way out.
        defer { du.releaseFirstPass() }
        let store = makeStore(urls, du)

        // The `init` pass has read the old size and is held. Change the size.
        try await waitUntil { du.passes == 1 }
        du.setBytes(4000)
        // The held pass can finish now, but it reports back on the main actor, which
        // this test keeps until `refresh` has asked. So the call always lands while
        // the first pass runs, however long that pass took to start.
        du.releaseFirstPass()
        await store.refresh(trigger: "after-change")

        #expect(store.trashBytes == 4000)
        #expect(du.passes == 2)
        #expect(du.maxActive == 1)
    }

    @Test func refreshesInTurnEachMeasure() async throws {
        let urls = try makeTrash()
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        let du = FakeDu(delay: 0.01)
        let store = makeStore(urls, du)

        await store.refresh(trigger: "first")
        du.setBytes(2000)
        await store.refresh(trigger: "second")
        #expect(store.trashBytes == 2000)
        du.setBytes(3000)
        await store.refresh(trigger: "third")
        #expect(store.trashBytes == 3000)
        #expect(du.maxActive == 1)
    }
}
