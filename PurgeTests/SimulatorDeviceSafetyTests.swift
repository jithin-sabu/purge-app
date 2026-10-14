import Foundation
import Testing
@testable import Purge

/// Deleting a simulator device removes its apps and data with no Trash copy, so a
/// device is Safe only when it is known to be unused (#136).
@MainActor
@Suite("Simulator device safety")
struct SimulatorDeviceSafetyTests {
    private static let day: TimeInterval = 24 * 60 * 60

    private func level(isAvailable: Bool = true, lastBootedAt: Date?) -> SafetyLevel {
        SimulatorDevice.safetyInfo(
            isAvailable: isAvailable,
            lastBootedAt: lastBootedAt,
            deviceName: "iPhone 17",
            runtimeVersion: "iOS 26.5"
        ).level
    }

    /// `simctl` omits the date for some devices that have been used, so a missing
    /// date can't count as unused.
    @Test func unknownLastUseIsCheckFirst() {
        #expect(level(lastBootedAt: nil) == .medium)
    }

    @Test func recentlyUsedDeviceIsCheckFirst() {
        #expect(level(lastBootedAt: Date().addingTimeInterval(-5 * Self.day)) == .medium)
    }

    @Test func deviceUnusedForThirtyDaysIsSafe() {
        #expect(level(lastBootedAt: Date().addingTimeInterval(-90 * Self.day)) == .safe)
    }

    @Test func unavailableDeviceIsSafe() {
        #expect(level(isAvailable: false, lastBootedAt: nil) == .safe)
        #expect(level(isAvailable: false, lastBootedAt: Date().addingTimeInterval(-5 * Self.day)) == .safe)
    }

    /// Same rule as simulator runtimes: the safe clean and the scheduled clean only
    /// move things to the Trash, so a Safe device stays out of both.
    @Test func safeDeviceStaysOutOfTheOneClickSafeClean() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let id = UUID()
        // A path the allowlist offers, under a UDID no real simulator has. The scan
        // is fake, so nothing on disk is read or moved.
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: folder.path))
        let lastBootedAt = Date().addingTimeInterval(-90 * Self.day)
        let device = SimulatorDevice(
            id: id,
            deviceName: "iPhone 17",
            runtimeVersion: "iOS 26.5",
            isAvailable: true,
            lastBootedAt: lastBootedAt,
            sizeOnDisk: nil,
            folderURL: folder,
            isSelected: false,
            safetyInfo: SimulatorDevice.safetyInfo(
                isAvailable: true, lastBootedAt: lastBootedAt, deviceName: "iPhone 17", runtimeVersion: "iOS 26.5"
            )
        )
        #expect(device.safetyInfo.level == .safe)
        // A device row is published once its size arrives.
        scans.developerEvents = [.simulatorFound(device), .simulatorSizeResolved(id: id, sizeBytes: 2_147_483_648)]
        let store = scans.makeStore()
        await store.scanDeveloper()

        #expect(store.simulatorDevices.map(\.id) == [id])
        #expect(store.manualSafeCleanupCandidates().isEmpty)
        #expect(store.safeCleanupSummary.totalBytes == 0)
    }
}
