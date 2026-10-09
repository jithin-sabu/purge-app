import Foundation
import Testing
@testable import Purge

/// Runtime rows come straight from `simctl` JSON, so the parsing and the Safe
/// versus Check First rule are the whole feature. Fixtures are trimmed copies of
/// real `simctl` output from a Mac with three runtimes.
@Suite("Simulator runtimes")
struct SimulatorRuntimeTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!

    private static let runtimeListJSON = """
    {
      "7AE1D6B6-5524-4FAD-B793-1D1C911E5269" : {
        "build" : "23D8133",
        "deletable" : true,
        "identifier" : "7AE1D6B6-5524-4FAD-B793-1D1C911E5269",
        "kind" : "Patchable Cryptex Disk Image",
        "lastUsedAt" : "2026-08-09T10:40:22Z",
        "mountPath" : "/Library/Developer/CoreSimulator/Volumes/iOS_23D8133",
        "path" : "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/c6f0.asset/AssetData/Restore/094-26194-058.dmg",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-3",
        "sizeBytes" : 8393503393,
        "state" : "Ready",
        "version" : "26.3.1"
      },
      "98372FEA-FA18-40D0-914B-EF89F74BAD29" : {
        "build" : "23F77",
        "deletable" : true,
        "identifier" : "98372FEA-FA18-40D0-914B-EF89F74BAD29",
        "kind" : "Patchable Cryptex Disk Image",
        "lastUsedAt" : "2026-10-05T10:00:22Z",
        "mountPath" : "/Library/Developer/CoreSimulator/Volumes/iOS_23F77",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "sizeBytes" : 8494282293,
        "state" : "Ready",
        "version" : "26.5"
      },
      "FD13D8F8-ED95-4774-9A2E-7C79EE33A65F" : {
        "build" : "22E238",
        "deletable" : true,
        "identifier" : "FD13D8F8-ED95-4774-9A2E-7C79EE33A65F",
        "kind" : "Cryptex Disk Image",
        "mountPath" : "/Library/Developer/CoreSimulator/Volumes/iOS_22E238",
        "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-4",
        "sizeBytes" : 8825558354,
        "state" : "Ready",
        "version" : "18.4"
      },
      "11111111-2222-3333-4444-555555555555" : {
        "build" : "22R123",
        "deletable" : false,
        "identifier" : "11111111-2222-3333-4444-555555555555",
        "kind" : "Patchable Cryptex Disk Image",
        "mountPath" : "/Library/Developer/CoreSimulator/Volumes/watchOS_22R123",
        "platformIdentifier" : "com.apple.platform.watchsimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-11-4",
        "sizeBytes" : 4000000000,
        "state" : "Ready",
        "version" : "11.4"
      }
    }
    """

    private static let devicesJSON = """
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-3" : [],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
          { "udid" : "A", "name" : "iPhone 17", "state" : "Shutdown" }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-4" : []
      }
    }
    """

    private static let matchJSON = """
    {
      "iphoneos27.0" : {
        "chosenRuntimeBuild" : "24A5390e",
        "defaultBuild" : "24A5390e",
        "platform" : "com.apple.platform.iphoneos",
        "sdkBuild" : "24A5390e",
        "sdkVersion" : "27.0"
      },
      "watchos27.0" : {
        "chosenRuntimeBuild" : "24R5325e",
        "platform" : "com.apple.platform.watchos"
      }
    }
    """

    private func parsed(
        deviceCounts: [String: Int]? = SimulatorRuntime.deviceCounts(fromDevicesList: Data(devicesJSON.utf8)),
        xcodeBuilds: Set<String> = []
    ) -> [SimulatorRuntime] {
        SimulatorRuntime.parseRuntimeList(
            Data(Self.runtimeListJSON.utf8),
            deviceCountsByRuntimeIdentifier: deviceCounts,
            xcodeRuntimeBuilds: xcodeBuilds,
            now: Self.now
        )
    }

    private func runtime(_ version: String, in list: [SimulatorRuntime]) -> SimulatorRuntime? {
        list.first { $0.version == version }
    }

    // MARK: - Parsing

    @Test func parsesEveryDeletableImageAndSkipsTheRest() {
        let list = parsed()
        #expect(list.map(\.version).sorted() == ["18.4", "26.3.1", "26.5"])
        #expect(list.allSatisfy { $0.platformName == "iOS" })
        // The watchOS image is marked not deletable, so it is Xcode's business.
        #expect(runtime("11.4", in: list) == nil)
    }

    @Test func carriesTheFieldsTheRowAndTheDeleteNeed() throws {
        let old = try #require(runtime("26.3.1", in: parsed()))
        #expect(old.id == "7AE1D6B6-5524-4FAD-B793-1D1C911E5269")
        #expect(old.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-26-3")
        #expect(old.build == "23D8133")
        #expect(old.sizeBytes == 8_393_503_393)
        #expect(old.locationURL.path == "/Library/Developer/CoreSimulator/Volumes/iOS_23D8133")
        #expect(old.lastUsedAt == ISO8601DateFormatter().date(from: "2026-08-09T10:40:22Z"))
        #expect(old.deviceCount == 0)
        #expect(old.isLegacyImage == false)
        #expect(old.safetyInfo.headline == "iOS 26.3.1 Runtime")
    }

    @Test func legacyImageKindIsRecognised() throws {
        let legacy = try #require(runtime("18.4", in: parsed()))
        #expect(legacy.isLegacyImage)
        #expect(legacy.lastUsedAt == nil)
        #expect(legacy.safetyInfo.explanation.contains("original download"))
    }

    @Test func deviceCountsComeFromTheDeviceList() {
        let counts = SimulatorRuntime.deviceCounts(fromDevicesList: Data(Self.devicesJSON.utf8))
        #expect(counts?["com.apple.CoreSimulator.SimRuntime.iOS-26-5"] == 1)
        #expect(counts?["com.apple.CoreSimulator.SimRuntime.iOS-26-3"] == 0)
        #expect(SimulatorRuntime.deviceCounts(fromDevicesList: Data("{}".utf8)) == nil)
    }

    @Test func xcodeBuildsComeFromTheMatchTable() {
        let builds = SimulatorRuntime.xcodeRuntimeBuilds(fromMatchList: Data(Self.matchJSON.utf8))
        #expect(builds == ["24A5390e", "24R5325e"])
    }

    @Test func platformNamesFallBackToTheRuntimeIdentifier() {
        #expect(SimulatorRuntime.platformName(
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-2-4", platformIdentifier: nil
        ) == "visionOS")
        #expect(SimulatorRuntime.platformName(
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-18-4", platformIdentifier: nil
        ) == "tvOS")
        #expect(SimulatorRuntime.platformName(
            runtimeIdentifier: "x", platformIdentifier: "com.apple.platform.appletvsimulator"
        ) == "tvOS")
    }

    @Test func garbageInputGivesNoRows() {
        #expect(SimulatorRuntime.parseRuntimeList(
            Data("not json".utf8), deviceCountsByRuntimeIdentifier: [:], xcodeRuntimeBuilds: []
        ).isEmpty)
    }

    // MARK: - Safety

    /// No simulator, not used in 30 days: the whole point of the feature.
    @Test func unusedOldRuntimeIsSafe() throws {
        let old = try #require(runtime("26.3.1", in: parsed()))
        #expect(old.safetyInfo.level == .safe)
        #expect(old.safetyInfo.explanation.hasPrefix("No simulator uses it. Last used 2 months ago."))
        #expect(old.safetyInfo.explanation.contains("Xcode downloads it again"))
    }

    /// `simctl` omits `lastUsedAt` for a runtime that was never started. That is
    /// the strongest orphan signal there is, so it stays Safe, the same reading
    /// the device rows give a missing boot date.
    @Test func neverUsedRuntimeWithNoDevicesIsSafe() throws {
        let never = try #require(runtime("18.4", in: parsed()))
        #expect(never.safetyInfo.level == .safe)
        #expect(never.safetyInfo.explanation.hasPrefix("No simulator uses it. Last use unknown."))
    }

    @Test func runtimeWithASimulatorIsCheckFirst() throws {
        let current = try #require(runtime("26.5", in: parsed()))
        #expect(current.safetyInfo.level == .medium)
        #expect(current.safetyInfo.explanation.hasPrefix("1 simulator uses it."))
    }

    @Test func recentlyUsedRuntimeIsCheckFirstEvenWithoutDevices() {
        let info = SimulatorRuntime.safetyInfo(
            platformName: "iOS", version: "26.4", state: "Ready", sizeBytes: 8_000_000_000,
            lastUsedAt: Self.now.addingTimeInterval(-5 * 86_400),
            deviceCount: 0, isXcodeDefault: false, isLegacyImage: false, now: Self.now
        )
        #expect(info.level == .medium)
        #expect(info.explanation.hasPrefix("No simulator uses it, but it was used in the last month."))
    }

    /// Deleting the runtime Xcode builds new simulators on only triggers an 8 GB
    /// download the next time one is created.
    @Test func xcodeDefaultRuntimeIsCheckFirst() throws {
        let list = parsed(xcodeBuilds: ["23D8133"])
        let xcodeDefault = try #require(runtime("26.3.1", in: list))
        #expect(xcodeDefault.safetyInfo.level == .medium)
        #expect(xcodeDefault.safetyInfo.explanation.hasPrefix("Xcode creates new simulators on this runtime."))
    }

    /// Without the device list "no simulator uses it" cannot be claimed.
    @Test func unknownDeviceCountsKeepEveryRowAtCheckFirst() {
        let list = parsed(deviceCounts: nil)
        #expect(!list.isEmpty)
        #expect(list.allSatisfy { $0.safetyInfo.level == .medium })
        #expect(list.allSatisfy { $0.safetyInfo.explanation.hasPrefix("Could not check which simulators use it.") })
    }

    @Test func unusableRuntimeIsSafeWhateverElseIsTrue() {
        let info = SimulatorRuntime.safetyInfo(
            platformName: "iOS", version: "17.0", state: "Unusable", sizeBytes: 8_000_000_000,
            lastUsedAt: Self.now, deviceCount: 3, isXcodeDefault: true, isLegacyImage: true, now: Self.now
        )
        #expect(info.level == .safe)
        #expect(info.explanation.hasPrefix("Xcode can no longer use this runtime."))
    }
}
