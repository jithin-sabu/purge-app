import Foundation
import Testing
@testable import Purge

/// Remove reads the list again before it deletes, and deletes only what the
/// confirmation showed and the list still says may go (#178).
@MainActor
@Suite("Local snapshot removal")
struct LocalSnapshotStoreTests {
    private static let oldest = "com.apple.TimeMachine.2026-11-01-080000.local"
    private static let older = "com.apple.TimeMachine.2026-11-01-090000.local"
    private static let fromBackup = "com.apple.TimeMachine.2026-11-01-100000.backup"
    private static let newest = "com.apple.TimeMachine.2026-11-01-110000.local"

    /// A Mac's snapshots as `tmutil` would list and delete them.
    private final class FakeTimeMachine: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String]
        private var readable = true
        private var stuck: Set<String> = []
        private var deleted: [[String]] = []
        private var available: [Int64]

        init(_ names: [String], available: [Int64] = []) {
            self.names = names
            self.available = available
        }

        var deleteCalls: [[String]] { lock.withLock { deleted } }

        func failReadings() { lock.withLock { readable = false } }
        /// Time Machine dropping a snapshot on its own.
        func expire(_ name: String) { lock.withLock { names.removeAll { $0 == name } } }
        func refuse(stamp: String) { lock.withLock { _ = stuck.insert(stamp) } }

        func read() -> LocalSnapshots? {
            lock.withLock {
                readable ? LocalSnapshotReader.parse(names.joined(separator: "\n"), timeZone: .gmt) : nil
            }
        }

        func delete(_ stamps: [String]) {
            lock.withLock {
                deleted.append(stamps)
                names.removeAll { name in stamps.contains { !stuck.contains($0) && name.contains($0) } }
            }
        }

        /// Free space, one figure per reading; the last one repeats.
        func capacity() -> VolumeCapacity? {
            lock.withLock {
                guard let next = available.first else { return nil }
                if available.count > 1 { available.removeFirst() }
                return VolumeCapacity(totalBytes: 1_000_000_000_000, availableBytes: next)
            }
        }

        @MainActor func makeStore() -> LocalSnapshotStore {
            LocalSnapshotStore(
                read: { self.read() },
                delete: { self.delete($0) },
                readCapacity: { self.capacity() }
            )
        }
    }

    private func planned(_ names: [String]) -> [LocalSnapshot] {
        LocalSnapshotReader.parse(names.joined(separator: "\n"), timeZone: .gmt).all
    }

    private func stamp(_ name: String) -> String {
        LocalSnapshotReader.parse(name, timeZone: .gmt).all[0].stamp
    }

    @Test func removesThePlannedSnapshotsStillListed() async {
        let mac = FakeTimeMachine([Self.oldest, Self.older, Self.fromBackup, Self.newest])
        let store = mac.makeStore()

        await store.remove(planned([Self.oldest, Self.older]))

        #expect(mac.deleteCalls == [[stamp(Self.oldest), stamp(Self.older)]])
        #expect(store.lastRemoval?.outcome == .removed(count: 2, freedBytes: nil))
        #expect(store.snapshots?.all.map(\.name) == [Self.fromBackup, Self.newest])
        #expect(!store.isRemoving)
    }

    /// The confirmation showed two, then Time Machine dropped the newer ones: the
    /// older of the two is now the newest and is kept.
    @Test func sparesOneThatBecameTheNewest() async {
        let mac = FakeTimeMachine([Self.oldest, Self.older, Self.newest])
        let store = mac.makeStore()
        let confirmed = planned([Self.oldest, Self.older])

        mac.expire(Self.newest)
        await store.remove(confirmed)

        #expect(mac.deleteCalls == [[stamp(Self.oldest)]])
        #expect(store.lastRemoval?.outcome == .removed(count: 1, freedBytes: nil))
    }

    @Test func neverRemovesTheSnapshotFromTheLastBackup() async {
        let mac = FakeTimeMachine([Self.oldest, Self.fromBackup, Self.newest])
        let store = mac.makeStore()

        await store.remove(planned([Self.oldest, Self.fromBackup]))

        #expect(mac.deleteCalls == [[stamp(Self.oldest)]])
    }

    @Test func doesNothingWhenThePlannedOnesHaveGone() async {
        let mac = FakeTimeMachine([Self.fromBackup, Self.newest])
        let store = mac.makeStore()

        await store.remove(planned([Self.oldest, Self.older]))

        #expect(mac.deleteCalls.isEmpty)
        #expect(store.lastRemoval == nil)
    }

    /// Without a fresh list nothing is deleted, and the row says it couldn't check.
    @Test func deletesNothingWhenTheListCantBeRead() async {
        let mac = FakeTimeMachine([Self.oldest, Self.older, Self.newest])
        mac.failReadings()
        let store = mac.makeStore()

        await store.remove(planned([Self.oldest]))

        #expect(mac.deleteCalls.isEmpty)
        #expect(store.lastRemoval?.outcome == .unverified)
    }

    /// Judged by what the list shows afterwards, not by what was asked for.
    @Test func reportsASnapshotTimeMachineKept() async {
        let mac = FakeTimeMachine([Self.oldest, Self.older, Self.newest])
        mac.refuse(stamp: stamp(Self.older))
        let store = mac.makeStore()

        await store.remove(planned([Self.oldest, Self.older]))

        #expect(store.lastRemoval?.outcome == .someLeft(removed: 1, left: 1))
    }

    /// Two snapshots with one stamp are deleted by one `tmutil` call.
    @Test func asksForEachStampOnce() async {
        let twin = "com.apple.TimeMachine.2026-11-01-080000.backup"
        let mac = FakeTimeMachine([Self.oldest, twin, Self.fromBackup, Self.newest])
        let store = mac.makeStore()

        await store.remove(planned([Self.oldest, twin]))

        #expect(mac.deleteCalls == [[stamp(Self.oldest)]])
        #expect(store.lastRemoval?.outcome == .removed(count: 2, freedBytes: nil))
    }

    /// The space is claimed once the free space settles above the noise floor.
    @Test func claimsTheSpaceOnceItSettles() async {
        let before: Int64 = 100_000_000_000
        let gain: Int64 = 4_000_000_000
        let mac = FakeTimeMachine([Self.oldest, Self.newest], available: [before, before + gain])
        let store = mac.makeStore()

        await store.remove(planned([Self.oldest]))

        #expect(store.lastRemoval?.outcome == .removed(count: 1, freedBytes: gain))
    }

    /// While one removal waits on `tmutil`, a second click does nothing.
    @Test func aSecondRemoveWhileOneRunsDoesNothing() async {
        let mac = FakeTimeMachine([Self.oldest, Self.older, Self.newest])
        let gate = Gate()
        let store = LocalSnapshotStore(
            read: { mac.read() },
            delete: { stamps in
                mac.delete(stamps)
                while !gate.isOpen { try? await Task.sleep(for: .milliseconds(10)) }
            },
            readCapacity: { nil }
        )

        let first = Task { await store.remove(planned([Self.oldest])) }
        #expect(await eventually { store.isRemoving && mac.deleteCalls.count == 1 })
        await store.remove(planned([Self.older]))

        #expect(mac.deleteCalls == [[stamp(Self.oldest)]])
        gate.open()
        await first.value
        #expect(!store.isRemoving)
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false

        var isOpen: Bool { lock.withLock { opened } }
        func open() { lock.withLock { opened = true } }
    }
}
