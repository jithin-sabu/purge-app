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
        sizeBytes: Int64 = 8_393_503_393
    ) -> SimulatorRuntime {
        let safety = SimulatorRuntime.safetyInfo(
            platformName: "iOS", version: version, state: "Ready", sizeBytes: sizeBytes,
            lastUsedAt: nil, deviceCount: deviceCount, isXcodeDefault: false, isLegacyImage: false
        )
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
    /// move things to the Trash, and a runtime cannot come back from there.
    @Test func safeRuntimeStaysOutOfTheOneClickSafeClean() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime()
        #expect(row.safetyInfo.level == .safe)
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()

        #expect(store.manualSafeCleanupCandidates().isEmpty)
    }

    @Test func excludingARuntimeDropsItsRow() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime()
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()
        store.setSimulatorRuntimeSelected(id: row.id, isSelected: true)

        store.excludeFromScans(row)

        #expect(store.simulatorRuntimes.isEmpty)
        #expect(store.selectedCount == 0)
        ExcludedPathsStore.remove(path: row.locationURL)
    }
}
