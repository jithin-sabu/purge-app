import Foundation
import Testing
@testable import Purge

/// One parser and one listing for `simctl list devices -j` (#178).
@Suite("Simulator device list")
struct SimulatorDeviceListTests {
    private static let json = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [
          {
            "udid": "5B0A7C1E-2F4D-4E8A-9C3B-1D2E3F405162",
            "name": "iPhone 17",
            "state": "Shutdown",
            "isAvailable": true,
            "lastBootedAt": "2026-10-01T09:30:00Z",
            "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/5B0A7C1E-2F4D-4E8A-9C3B-1D2E3F405162/data"
          },
          { "name": "No UDID", "state": "Booted" }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5": []
      }
    }
    """

    @Test func readsEveryField() throws {
        let list = try #require(SimulatorDeviceList.parse(Data(Self.json.utf8)))
        let device = try #require(list.devicesByRuntime["com.apple.CoreSimulator.SimRuntime.iOS-26-3"]?.first)

        #expect(device.udid == "5B0A7C1E-2F4D-4E8A-9C3B-1D2E3F405162")
        #expect(device.name == "iPhone 17")
        #expect(device.state == "Shutdown")
        #expect(device.isAvailable)
        #expect(device.lastBootedAt == ISO8601DateFormatter().date(from: "2026-10-01T09:30:00Z"))
        #expect(device.dataPath?.hasSuffix("/data") == true)
    }

    /// A device the list names without a UDID still counts toward its runtime,
    /// so a runtime is never shown with fewer simulators than it has.
    @Test func countsEveryDevicePerRuntime() throws {
        let list = try #require(SimulatorDeviceList.parse(Data(Self.json.utf8)))

        #expect(list.countsByRuntime == [
            "com.apple.CoreSimulator.SimRuntime.iOS-26-3": 2,
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": 0,
        ])
    }

    @Test func findsAUDIDInAnyCase() throws {
        let list = try #require(SimulatorDeviceList.parse(Data(Self.json.utf8)))

        #expect(list.contains(udid: "5b0a7c1e-2f4d-4e8a-9c3b-1d2e3f405162"))
        #expect(!list.contains(udid: "00000000-0000-0000-0000-000000000000"))
    }

    /// A list with something that is not a device entry is marked unreadable,
    /// and every entry still counts toward the runtime.
    @Test func aListWithAnUnreadableEntryIsMarked() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [null, {"udid": "5B0A7C1E-2F4D-4E8A-9C3B-1D2E3F405162", "state": "Shutdown"}],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [{"udid": "6C1B8D2F-3A5E-4F9B-8D4C-2E3F40516273", "state": "Shutdown"}],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-6": "not a list"
        }}
        """
        let list = try #require(SimulatorDeviceList.parse(Data(json.utf8)))

        #expect(list.unreadableRuntimes == [
            "com.apple.CoreSimulator.SimRuntime.iOS-26-3",
            "com.apple.CoreSimulator.SimRuntime.iOS-26-6",
        ])
        #expect(list.countsByRuntime["com.apple.CoreSimulator.SimRuntime.iOS-26-3"] == 2)
        // Still found, so a delete is never judged done because of its neighbour.
        #expect(list.contains(udid: "5B0A7C1E-2F4D-4E8A-9C3B-1D2E3F405162"))
    }

    @Test func somethingElseIsNotADeviceList() {
        #expect(SimulatorDeviceList.parse(Data("{}".utf8)) == nil)
        #expect(SimulatorDeviceList.parse(Data("not json".utf8)) == nil)
    }

    /// The device rows and the runtime rows both ask; `simctl` runs once.
    @Test func theListingRunsOnceForEveryAsker() async {
        let runs = RunCount()
        let listing = DevScanner.DeviceListingOnce {
            runs.add()
            try? await Task.sleep(for: .milliseconds(50))
            return ProcessRunner.Output(status: 0, stdout: Data(Self.json.utf8), stderr: Data(), timedOut: false)
        }

        async let first = listing.output()
        async let second = listing.output()
        let answers = await [first, second]
        let third = await listing.output()

        #expect(runs.value == 1)
        #expect(answers.allSatisfy { $0?.stdout == Data(Self.json.utf8) })
        #expect(third?.stdout == Data(Self.json.utf8))
    }

    @Test func nothingRunsUntilSomeoneAsks() async {
        let runs = RunCount()
        let scanner = DevScanner()
        let listing = DevScanner.DeviceListingOnce {
            runs.add()
            return nil
        }

        // No CoreSimulator: the runtime scan stops before it asks.
        _ = await scanner.discoverSimulatorRuntimes(coreSimulatorPresent: false, deviceListing: listing)

        #expect(runs.value == 0)
    }

    private final class RunCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
