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
            build: "23D8133",
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

    @Test func excludingARuntimeDropsItsRow() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime()
        defer { ExcludedPathsStore.remove(path: row.locationURL) }
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()
        store.setSimulatorRuntimeSelected(id: row.id, isSelected: true)

        store.excludeFromScans(row)

        #expect(store.simulatorRuntimes.isEmpty)
        #expect(store.selectedCount == 0)
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
