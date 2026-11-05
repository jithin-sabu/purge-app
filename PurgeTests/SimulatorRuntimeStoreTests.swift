import Foundation
import Testing
@testable import Purge

/// Runtime rows ride the Dev Tools scan and the manual clean, and stay out of the
/// one-click safe clean: removing one is not a trash move.
@MainActor
@Suite("Simulator runtime store rows")
struct SimulatorRuntimeStoreTests {
    private func runtime(
        id: String = "7AE1D6B6-5524-4FAD-B793-1D1C911E5269",
        version: String = "26.3.1",
        build: String = "23D8133",
        deviceCount: Int = 0,
        sizeBytes: Int64 = 8_393_503_393,
        level: SafetyLevel? = nil
    ) -> SimulatorRuntime {
        var safety = SimulatorRuntime.safetyInfo(
            platformName: "iOS", version: version, state: "Ready", sizeBytes: sizeBytes,
            lastUsedAt: nil, deviceCount: deviceCount, isXcodeDefault: false
        )
        if let level {
            safety = SafetyInfo(
                level: level,
                headline: safety.headline,
                explanation: safety.explanation,
                recoverySteps: safety.recoverySteps,
                reinstallCommand: safety.reinstallCommand
            )
        }
        return SimulatorRuntime(
            id: id,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-3",
            platformName: "iOS",
            version: version,
            build: build,
            kind: "Patchable Cryptex Disk Image",
            state: "Ready",
            sizeBytes: sizeBytes,
            lastUsedAt: nil,
            deviceCount: deviceCount,
            locationURL: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes/iOS_\(version)", isDirectory: true),
            safetyInfo: safety
        )
    }

    @Test func scanPublishesRuntimeRowsSizedOnArrival() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.developerEvents = [.simulatorRuntimeFound(runtime())]
        let store = scans.makeStore()

        await store.scanDeveloper()

        #expect(store.simulatorRuntimes.map(\.id) == ["7AE1D6B6-5524-4FAD-B793-1D1C911E5269"])
        #expect(store.devToolsTotals.count == 1)
        #expect(store.devToolsTotals.bytes == 8_393_503_393)
    }

    /// A scan that found only runtimes has something to list. Dev Tools showed
    /// its empty state for it, because its checks left runtimes out (#292).
    @Test func runtimesAloneAreSomethingToList() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        scans.developerEvents = [.simulatorRuntimeFound(runtime())]
        let store = scans.makeStore()
        #expect(!store.hasLiveDevToolsRows)
        #expect(store.isAwaitingFirstDevToolsScan)

        await store.scanDeveloper()

        #expect(store.devTools.isEmpty && store.projectGroups.isEmpty && store.simulatorDevices.isEmpty)
        #expect(store.hasLiveDevToolsRows)
    }

    /// Runtimes listed before any scan has finished end the wait for the first
    /// scan. The tab said "Dev Tools not scanned yet" over them (#292). The scan
    /// above can't show this: finishing it ends the wait on its own.
    @Test func runtimesAloneEndTheFirstScanWait() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        #expect(store.isAwaitingFirstDevToolsScan)

        store.simulatorRuntimes = [runtime()]

        #expect(!store.hasSessionCacheScan)
        #expect(!store.isAwaitingFirstDevToolsScan)
    }

    @Test func selectedRuntimeBecomesACandidateAtItsMountPath() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime()
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()

        store.setSimulatorRuntimeSelected(id: row.id, isSelected: true)

        #expect(store.selectedCount == 1)
        #expect(store.selectedTotalBytes == row.sizeBytes)
        let candidate = try #require(store.deletionCandidates.first)
        #expect(candidate.path == row.locationURL.standardizedFileURL)
        #expect(candidate.title == "iOS 26.3.1 Runtime")
        #expect(candidate.sizeBytes == row.sizeBytes)
        #expect(store.selectedDeveloperDeletionCandidates.map(\.path) == [candidate.path])

        store.setSimulatorRuntimeSelected(id: row.id, isSelected: false)
        #expect(store.selectedCount == 0)
    }

    /// Same rule as simulator devices: the safe clean and the scheduled clean only
    /// move things to the Trash, and a runtime cannot come back from there. Runtimes
    /// are never Safe (#136); the row is forced Safe here to prove the one-click
    /// clean skips it even so.
    @Test func safeRuntimeStaysOutOfTheOneClickSafeClean() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime(level: .safe)
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()

        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    /// The exclusion is kept by identifier, not by the path the row showed, which
    /// changes when macOS mounts the image (#178). Its own id and build, so the
    /// other tests here never see it.
    @Test func excludingARuntimeDropsItsRow() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime(id: "178D0001-0000-4000-8000-000000000001", build: "178STORE1")
        defer { ExcludedSimulatorRuntimesStore.remove(imageID: row.id) }
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()
        store.setSimulatorRuntimeSelected(id: row.id, isSelected: true)

        store.excludeFromScans(row)

        #expect(store.simulatorRuntimes.isEmpty)
        #expect(store.selectedCount == 0)
        #expect(store.excludedSimulatorRuntimes.map(\.imageID).contains(row.id))
        #expect(!ExcludedPathsStore.contains(path: row.locationURL))
    }

    /// Excluded from the list while the confirm sheet is open, as from a second
    /// window: the clean leaves that runtime alone and takes the other one, and
    /// the excluded one is not reported as skipped (#178).
    @Test func aRuntimeExcludedWhileTheSheetIsOpenIsLeftAlone() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let excluded = runtime(id: "178D0002-0000-4000-8000-000000000002", version: "26.2", build: "178STORE2")
        let kept = runtime(id: "178D0003-0000-4000-8000-000000000003", version: "26.1", build: "178STORE3")
        defer { ExcludedSimulatorRuntimesStore.remove(imageID: excluded.id) }
        scans.developerEvents = [.simulatorRuntimeFound(excluded), .simulatorRuntimeFound(kept)]
        let removed = RemovedIDs()
        let deleter = FileDeleter(simulatorRuntimeRemover: { id in
            removed.add(id)
            return .removed(freed: .unknown, download: .notKept, isLegacyImage: false)
        })
        let store = scans.makeStore(fileDeleter: deleter)
        await store.scanDeveloper()
        store.setSimulatorRuntimeSelected(id: excluded.id, isSelected: true)
        store.setSimulatorRuntimeSelected(id: kept.id, isSelected: true)
        store.presentDeletionSheet(candidates: store.deletionCandidates)

        store.excludeFromScans(excluded)
        store.userConfirmedDeletionFromPrimarySheet()

        #expect(await eventually { store.manualDeletionSession?.phase == .complete })
        let session = try #require(store.manualDeletionSession)
        #expect(removed.ids == [kept.id])
        #expect(session.failedItems.isEmpty)
        #expect(session.removedPermanentlyCount == 1)
    }

    /// The scan moves a runtime excluded by path before #178 to the runtime list.
    /// Settings reads that list from the store, so the store reads it again once
    /// the scan ends; otherwise Settings showed nothing excluded.
    @Test func aScanThatMovesAnOldExclusionUpdatesSettings() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime(id: "178D0004-0000-4000-8000-000000000004", build: "178STORE4")
        defer {
            ExcludedSimulatorRuntimesStore.remove(imageID: row.id)
            ExcludedPathsStore.remove(path: row.locationURL)
        }
        ExcludedPathsStore.write(path: row.locationURL, displayName: "iOS 26.3.1 Runtime")
        let store = scans.makeStore()
        #expect(!store.excludedSimulatorRuntimes.contains { $0.imageID == row.id })

        // What DevScanner does with the runtime it lists.
        #expect(ExcludedSimulatorRuntimesStore.isExcluded(row))
        await store.scanDeveloper()

        #expect(store.excludedSimulatorRuntimes.contains { $0.imageID == row.id })
        #expect(!store.excludedPaths.contains(row.locationURL.path))
    }

    private final class RemovedIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []

        func add(_ id: String) { lock.withLock { list.append(id) } }
        var ids: [String] { lock.withLock { list } }
    }

    /// When Apple keeps a runtime's download, the completion screen says so, and
    /// the total counts what the volume gave back, not the listed size (#165).
    @Test func keptDownloadIsNamedOnTheCompletionScreen() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime()
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in
            .removed(freed: .unknown, download: .kept(bytes: 9_116_354_048), isLegacyImage: false)
        })
        let store = scans.makeStore(fileDeleter: deleter)
        let session = try await cleanTheRuntime(row, in: store)

        #expect(session.finalBytesMovedToTrash == 0)
        #expect(session.removedPermanentlyCount == 1)
        #expect(session.notes == [
            "macOS kept the iOS 26.3.1 Runtime download (\(formatBytes(9_116_354_048))), so that space is still in use."
        ])
    }

    /// A runtime that fails once and goes on Retry while Apple keeps its download
    /// gets the same line as one that went the first time.
    @Test func keptDownloadIsNamedAfterARetry() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime()
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let attempts = Attempts()
        // if/else, not a ternary in a closure: CI's Xcode 26.6 crashed on that.
        let deleter = FileDeleter(simulatorRuntimeRemover: { _ in
            if attempts.next() == 1 {
                return .failed("runtime still listed after 180s")
            }
            return .removed(freed: .unknown, download: .kept(bytes: 9_116_354_048), isLegacyImage: false)
        })
        let store = scans.makeStore(fileDeleter: deleter)
        let session = try await cleanTheRuntime(row, in: store)
        let failure = try #require(session.failedItems.first)
        #expect(session.notes.isEmpty)

        _ = await store.retryCleanFailure(failure, session: session)

        #expect(session.failedItems.isEmpty)
        #expect(session.notes == [
            "macOS kept the iOS 26.3.1 Runtime download (\(formatBytes(9_116_354_048))), so that space is still in use."
        ])
    }

    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    /// Scans, ticks the runtime and confirms the clean, then waits for the
    /// completion screen.
    private func cleanTheRuntime(_ row: SimulatorRuntime, in store: PurgeStore) async throws -> DeletionSession {
        await store.scanDeveloper()
        store.setSimulatorRuntimeSelected(id: row.id, isSelected: true)
        store.presentDeletionSheet(candidates: store.deletionCandidates)
        store.userConfirmedDeletionFromPrimarySheet()
        for _ in 0..<500 where store.manualDeletionSession?.phase != .complete {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let session = try #require(store.manualDeletionSession)
        #expect(session.phase == .complete)
        return session
    }
}
