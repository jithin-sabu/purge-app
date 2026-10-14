import Foundation
import Testing
@testable import Purge

/// Safe means Clean Safe Items and scheduled cleans take the item without asking,
/// and they only move things to the Trash. Simulators are removed for good, so no
/// simulator row is ever Safe (#136).
@MainActor
@Suite("Simulator device safety")
struct SimulatorDeviceSafetyTests {
    private static let day: TimeInterval = 24 * 60 * 60

    private func info(isAvailable: Bool = true, lastBootedAt: Date?) -> SafetyInfo {
        SimulatorDevice.safetyInfo(
            isAvailable: isAvailable,
            lastBootedAt: lastBootedAt,
            deviceName: "iPhone 17",
            runtimeVersion: "iOS 26.5"
        )
    }

    /// `simctl` omits the date for some devices that have been used, so a missing
    /// date can't count as unused.
    @Test func unknownLastUseIsCheckFirst() {
        let unknown = info(lastBootedAt: nil)
        #expect(unknown.level == .medium)
        #expect(unknown.explanation.hasPrefix("Last use unknown."))
    }

    @Test func recentlyUsedDeviceIsCheckFirst() {
        let recent = info(lastBootedAt: Date().addingTimeInterval(-5 * Self.day))
        #expect(recent.level == .medium)
        #expect(recent.explanation.hasPrefix("Used in the last month."))
    }

    /// The device can still hold apps and data. The explanation says how long it
    /// has been, so the user can still tell a forgotten device from one in use.
    @Test func deviceUnusedForMonthsIsCheckFirstAndSaysHowLong() {
        let old = info(lastBootedAt: Date().addingTimeInterval(-90 * Self.day))
        #expect(old.level == .medium)
        #expect(old.explanation.hasPrefix("Last used"))
        #expect(old.explanation.contains("months ago"))
    }

    /// Removing a runtime, which Purge can do, makes its devices unavailable. Their
    /// data comes back with the runtime, so the delete is not a free one.
    @Test func unavailableDeviceIsCheckFirst() {
        for lastBootedAt in [nil, Date().addingTimeInterval(-5 * Self.day), Date().addingTimeInterval(-90 * Self.day)] {
            let unavailable = info(isAvailable: false, lastBootedAt: lastBootedAt)
            #expect(unavailable.level == .medium)
            #expect(unavailable.explanation.hasPrefix("Xcode can no longer run this device."))
        }
    }

    /// Every branch of both simulator safety functions, devices and runtimes. A new
    /// branch that returns Safe fails here.
    @Test func noSimulatorRowIsEverSafe() {
        let dates: [Date?] = [nil, Date(), Date().addingTimeInterval(-40 * Self.day), Date().addingTimeInterval(-400 * Self.day)]
        for isAvailable in [true, false] {
            for lastBootedAt in dates {
                #expect(info(isAvailable: isAvailable, lastBootedAt: lastBootedAt).level == .medium)
            }
        }
        for state in ["Ready", "Unusable", "Mounting", ""] {
            for lastUsedAt in dates {
                for deviceCount in [nil, 0, 1, 3] as [Int?] {
                    for isXcodeDefault in [nil, true, false] as [Bool?] {
                        for isLegacyImage in [true, false] {
                            let runtime = SimulatorRuntime.safetyInfo(
                                platformName: "iOS", version: "18.4", state: state, sizeBytes: 8_000_000_000,
                                lastUsedAt: lastUsedAt, deviceCount: deviceCount,
                                isXcodeDefault: isXcodeDefault, isLegacyImage: isLegacyImage
                            )
                            #expect(runtime.level == .medium)
                        }
                    }
                }
            }
        }
    }

    /// Same rule as simulator runtimes: the safe clean and the scheduled clean only
    /// move things to the Trash, so a simulator stays out of both. Devices are never
    /// Safe; the row is forced Safe here to prove the one-click clean skips it even so.
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
        let device = SimulatorDevice(
            id: id,
            deviceName: "iPhone 17",
            runtimeVersion: "iOS 26.5",
            isAvailable: true,
            lastBootedAt: Date().addingTimeInterval(-90 * Self.day),
            sizeOnDisk: nil,
            folderURL: folder,
            isSelected: false,
            safetyInfo: SafetyInfo(
                level: .safe,
                headline: "iPhone 17 · iOS 26.5",
                explanation: "",
                recoverySteps: "",
                reinstallCommand: nil
            )
        )
        // A device row is published once its size arrives.
        scans.developerEvents = [.simulatorFound(device), .simulatorSizeResolved(id: id, sizeBytes: 2_147_483_648)]
        let store = scans.makeStore()
        await store.scanDeveloper()

        #expect(store.simulatorDevices.map(\.id) == [id])
        #expect(store.manualSafeCleanupCandidates().isEmpty)
        #expect(store.safeCleanupSummary.totalBytes == 0)
    }
}
