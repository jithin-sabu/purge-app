import Foundation
import Testing
@testable import Purge

/// Xcode 27.1 shipped an iOS 27.1 runtime that runs only iPhone Duo, while every
/// other iPhone needs iOS 27.0. The newer version is the one to delete, which the
/// row has to say, because the version numbers suggest the opposite.
@Suite("Runtimes say which devices they run")
struct SimulatorRuntimeDeviceReachTests {
    private static func deviceTypes(_ names: [String]) -> String {
        names.map { "{\"name\": \"\($0)\"}" }.joined(separator: ", ")
    }

    private static let iPhones = ["iPhone 18 Pro", "iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro Max", "iPhone 16e"]

    /// The shape of `simctl list runtimes -j`, trimmed to what is read.
    private static let runtimesJSON = """
    {"runtimes": [
      {"buildversion": "24A434", "platform": "iOS", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
       "supportedDeviceTypes": [\(deviceTypes(iPhones))]},
      {"buildversion": "24A94425", "platform": "iOS", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
       "supportedDeviceTypes": [\(deviceTypes(["iPhone Duo"]))]},
      {"buildversion": "24R362", "platform": "watchOS", "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0",
       "supportedDeviceTypes": [\(deviceTypes(["Apple Watch Series 11 (46mm)", "Apple Watch Ultra 3 (49mm)", "Apple Watch SE 3 (44mm)", "Apple Watch Series 11 (42mm)"]))]}
    ]}
    """

    @Test func marksTheDeviceSpecificRuntimeAndTheGeneralOne() {
        let reach = SimulatorRuntime.deviceReachByBuild(fromRuntimesList: Data(Self.runtimesJSON.utf8))
        #expect(reach["24A94425"] == .only(["iPhone Duo"]))
        #expect(reach["24A434"] == .onlyGeneralRuntime)
    }

    /// A platform with only general runtimes, or only one runtime, says nothing new.
    @Test func leavesOrdinaryPlatformsAlone() {
        let reach = SimulatorRuntime.deviceReachByBuild(fromRuntimesList: Data(Self.runtimesJSON.utf8))
        #expect(reach["24R362"] == nil)
    }

    /// Two general runtimes: neither is the only one, so neither is marked.
    @Test func twoGeneralRuntimesAreNotTheOnlyOne() {
        let json = """
        {"runtimes": [
          {"buildversion": "A", "platform": "iOS", "supportedDeviceTypes": [\(Self.deviceTypes(Self.iPhones))]},
          {"buildversion": "B", "platform": "iOS", "supportedDeviceTypes": [\(Self.deviceTypes(Self.iPhones))]},
          {"buildversion": "C", "platform": "iOS", "supportedDeviceTypes": [\(Self.deviceTypes(["iPhone Duo"]))]}
        ]}
        """
        let reach = SimulatorRuntime.deviceReachByBuild(fromRuntimesList: Data(json.utf8))
        #expect(reach["A"] == nil)
        #expect(reach["B"] == nil)
        #expect(reach["C"] == .only(["iPhone Duo"]))
    }

    @Test func unreadableListMarksNothing() {
        #expect(SimulatorRuntime.deviceReachByBuild(fromRuntimesList: Data("not json".utf8)).isEmpty)
    }

    /// The reach leads the explanation and changes nothing else: still Check First.
    @Test func explanationLeadsWithTheReach() {
        func info(_ reach: SimulatorRuntime.DeviceReach?) -> SafetyInfo {
            SimulatorRuntime.safetyInfo(
                platformName: "iOS", version: "27.1", state: "Ready", sizeBytes: 7_870_000_000,
                lastUsedAt: nil, deviceCount: 0, isXcodeDefault: false, isLegacyImage: false,
                deviceReach: reach
            )
        }
        let plain = info(nil)
        let duo = info(.only(["iPhone Duo"]))
        #expect(duo.explanation.hasPrefix("Only runs iPhone Duo simulators. "))
        #expect(duo.explanation.hasSuffix(plain.explanation))
        #expect(duo.level == .medium)
        #expect(info(.onlyGeneralRuntime).explanation.hasPrefix("The only iOS runtime here that runs most devices. "))
    }
}
