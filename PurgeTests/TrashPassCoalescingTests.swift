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

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var maxActive: Int { lock.withLock { _maxActive } }
    var passes: Int { lock.withLock { _passes } }

    func setBytes(_ bytes: Int64) {
        lock.withLock { _bytes = bytes }
    }

    func measure(_ urls: [URL]) -> [String: Int64] {
        let bytes: Int64 = lock.withLock {
            _passes += 1
            active += 1
            _maxActive = max(_maxActive, active)
            return _bytes
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
    /// Up to ten seconds: the first pass starts from a `Task` on the main actor,
    /// and a shared CI runner under a full test run can take more than two
    /// seconds to get to it (#174 CI).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
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
        let store = TrashStore(trashURLs: urls, measureSizes: { du.measure($0) })

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
    @Test func aCallDuringAPassGetsALaterPass() async throws {
        let urls = try makeTrash()
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        let du = FakeDu(delay: 0.2)
        let store = TrashStore(trashURLs: urls, measureSizes: { du.measure($0) })

        // Once the `init` pass has started with the old size, change it.
        await waitUntil { du.passes == 1 }
        #expect(du.passes == 1)
        du.setBytes(4000)
        await store.refresh(trigger: "after-change")

        #expect(store.trashBytes == 4000)
        #expect(du.passes == 2)
        #expect(du.maxActive == 1)
    }

    @Test func refreshesInTurnEachMeasure() async throws {
        let urls = try makeTrash()
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        let du = FakeDu(delay: 0.01)
        let store = TrashStore(trashURLs: urls, measureSizes: { du.measure($0) })

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
