import Foundation
import Testing
@testable import Purge

/// A device delete must be checked, not trusted: it is done only when simctl no
/// longer lists the UDID and the folder is gone. When it fails, the reason simctl
/// gave has to reach the result screen instead of a blanket "Try again" (#161).
/// Every simctl call here is a fake; no real simulator is touched.
@Suite("Simulator device removal")
struct SimulatorDeviceRemovalTests {
    private let udid = "0C6F3F7E-6B0E-4E59-9E57-5D1C8F1A2B3C"
    private let folder = URL(fileURLWithPath: "/nonexistent/CoreSimulator/Devices/0C6F3F7E-6B0E-4E59-9E57-5D1C8F1A2B3C")

    static let licenseText = """
        You have not agreed to the Xcode license agreements. You must agree to both license agreements below in order to use Xcode.
        """
    static let missingToolText = """
        xcrun: error: unable to find utility "simctl", not a developer tool or in PATH
        """
    static let outOfDateText = """
        CoreSimulator is out of date. Current version (1010.10) is older than build version (1010.15).
        """

    private static func output(_ status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> ProcessRunner.Output {
        ProcessRunner.Output(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timedOut)
    }

    private static func listing(udids: [String]) -> String {
        let devices = udids.map { "{\"udid\": \"\($0)\", \"state\": \"Shutdown\", \"name\": \"iPhone 17\"}" }
        return "{\"devices\": {\"com.apple.CoreSimulator.SimRuntime.iOS-26-5\": [\(devices.joined(separator: ", "))]}}"
    }

    /// A fake simctl: `delete` answers with `deleteOutput`, `list` with `listOutput`.
    private final class FakeSimctl: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        let deleteOutput: ProcessRunner.Output?
        let listOutput: ProcessRunner.Output?

        init(delete: ProcessRunner.Output?, list: ProcessRunner.Output?) {
            deleteOutput = delete
            listOutput = list
        }

        func run(_ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output? {
            lock.lock(); calls.append(arguments); lock.unlock()
            return arguments.first == "delete" ? deleteOutput : listOutput
        }
    }

    private func remove(_ fake: FakeSimctl, folderExists: Bool) -> SimulatorDeviceRemoval {
        FileDeleter.removeSimulatorDevice(
            udid: udid,
            folder: folder,
            runSimctl: { fake.run($0, $1) },
            folderExists: { _ in folderExists },
            pollInterval: 0
        )
    }

    // MARK: - The remover

    @Test func removedWhenUnlistedAndFolderGone() {
        let fake = FakeSimctl(delete: Self.output(0), list: Self.output(0, stdout: Self.listing(udids: [])))
        #expect(remove(fake, folderExists: false) == .removed)
        #expect(fake.calls.first == ["delete", udid])
    }

    @Test func exitZeroWithTheDeviceStillListedIsAFailure() {
        let fake = FakeSimctl(delete: Self.output(0), list: Self.output(0, stdout: Self.listing(udids: [udid])))
        guard case .failed(let reason, _) = remove(fake, folderExists: false) else {
            Issue.record("a device still listed must not count as removed")
            return
        }
        #expect(reason == .unknown)
    }

    @Test func exitZeroWithTheFolderStillThereIsAFailure() {
        let fake = FakeSimctl(delete: Self.output(0), list: Self.output(0, stdout: Self.listing(udids: [])))
        guard case .failed = remove(fake, folderExists: true) else {
            Issue.record("a device folder still on disk must not count as removed")
            return
        }
    }

    @Test func nonzeroExitWithTheDeviceStillListedIsAFailure() {
        let fake = FakeSimctl(
            delete: Self.output(148, stderr: "Invalid device: \(udid)"),
            list: Self.output(0, stdout: Self.listing(udids: [udid]))
        )
        guard case .failed(let reason, let detail) = remove(fake, folderExists: true) else {
            Issue.record("expected a failure")
            return
        }
        #expect(reason == .unknown)
        #expect(detail.contains("exit 148"))
        #expect(detail.contains("Invalid device"))
    }

    /// An unreadable list never counts as gone, even after exit 0.
    @Test func unreadableListIsNotProofOfRemoval() {
        let fake = FakeSimctl(delete: Self.output(0), list: Self.output(1, stderr: "list failed"))
        guard case .failed = remove(fake, folderExists: false) else {
            Issue.record("expected a failure")
            return
        }
    }

    @Test(arguments: [
        (Int32(69), SimulatorDeviceRemovalTests.licenseText, CleanFailureReason.xcodeLicenseNotAccepted),
        (Int32(72), SimulatorDeviceRemovalTests.missingToolText, CleanFailureReason.simulatorToolsMissing),
        (Int32(1), SimulatorDeviceRemovalTests.outOfDateText, CleanFailureReason.simulatorServiceNeedsRestart),
    ])
    func knownSimctlErrorsKeepTheirReason(status: Int32, stderr: String, expected: CleanFailureReason) {
        let failure = Self.output(status, stderr: stderr)
        let fake = FakeSimctl(delete: failure, list: failure)
        guard case .failed(let reason, let detail) = remove(fake, folderExists: true) else {
            Issue.record("expected a failure")
            return
        }
        #expect(reason == expected)
        #expect(detail.contains(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func noSimctlAtAllFailsWithoutAskingAgain() {
        let fake = FakeSimctl(delete: nil, list: nil)
        #expect(remove(fake, folderExists: true) == .failed(.simulatorToolsMissing, detail: "could not launch simctl"))
        #expect(fake.calls.count == 1)
    }

    // MARK: - Reading simctl's errors

    @Test func xcrunRefusalIsToldApartFromSimctlsOwnErrors() {
        #expect(Simctl.xcrunRefused(Self.output(72, stderr: Self.missingToolText)))
        #expect(Simctl.xcrunRefused(Self.output(69, stderr: Self.licenseText)))
        // simctl ran and answered: the framework copy must not be asked to delete again.
        #expect(!Simctl.xcrunRefused(Self.output(148, stderr: "Invalid device: \(udid)")))
        #expect(!Simctl.xcrunRefused(Self.output(1, stderr: Self.outOfDateText)))
        #expect(!Simctl.xcrunRefused(Self.output(0)))
        #expect(!Simctl.xcrunRefused(Self.output(0, stderr: "xcrun: error: x", timedOut: true)))
    }

    @Test func timeoutStaysUnknown() {
        #expect(CleanFailureReason.fromSimctl(Self.output(0, timedOut: true)) == .unknown)
    }

    @Test func retryIsOfferedOnlyWhereItCanWork() {
        #expect(CleanFailureReason.xcodeLicenseNotAccepted.showsRetry)
        #expect(!CleanFailureReason.simulatorServiceNeedsRestart.showsRetry)
        #expect(!CleanFailureReason.simulatorToolsMissing.showsRetry)
        #expect(CleanFailureReason.unknown.showsRetry)
    }

    // MARK: - The engine

    /// A device path the allowlist offers, under a UDID no real simulator has. The
    /// fake remover means nothing on disk is read or moved.
    private func unusedDevicePath() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var asked: [String] = []
        func record(_ udid: String) {
            lock.lock(); asked.append(udid); lock.unlock()
        }
    }

    @Test func failedDeviceDeleteKeepsItsReason() async throws {
        let device = try unusedDevicePath()
        let recorder = Recorder()
        let deleter = FileDeleter(simulatorDeviceRemover: { udid, _ in
            recorder.record(udid)
            return .failed(.xcodeLicenseNotAccepted, detail: "exit 69")
        })
        let key = device.standardizedFileURL.path
        let report = try await deleter.deleteItems(
            at: [device],
            pathToDisplayName: [key: "iPhone 17 · iOS 26.5"],
            pathToExpectedSizeBytes: [key: 2_000_000_000]
        )

        #expect(recorder.asked == [device.lastPathComponent])
        #expect(report.deletedItems.isEmpty)
        #expect(report.bytesRemovedDirectly == 0)
        let failed = try #require(report.failedItems.first)
        #expect(failed.reason == .xcodeLicenseNotAccepted)
        #expect(failed.sizeBytes == 2_000_000_000)
        #expect(failed.displayName == "iPhone 17 · iOS 26.5")
    }

    @Test func removedDeviceCountsAsRemovedDirectly() async throws {
        let device = try unusedDevicePath()
        let deleter = FileDeleter(simulatorDeviceRemover: { _, _ in .removed })
        let key = device.standardizedFileURL.path
        let report = try await deleter.deleteItems(at: [device], pathToExpectedSizeBytes: [key: 42])

        #expect(report.bytesRemovedDirectly == 42)
        #expect(report.bytesMovedToTrash == 0)
        let item = try #require(report.deletedItems.first)
        #expect(item.movedToTrash == false)
        #expect(report.failedItems.isEmpty)
    }

    @Test func retryReturnsTheSameReason() async throws {
        let device = try unusedDevicePath()
        let deleter = FileDeleter(simulatorDeviceRemover: { _, _ in
            .failed(.simulatorServiceNeedsRestart, detail: "exit 1")
        })
        let result = await deleter.retryDeleteItem(at: device, displayName: nil, expectedSizeBytes: 1)
        guard case .failure(let reason) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(reason == .simulatorServiceNeedsRestart)
    }
}

/// The scan may offer a device only when the delete has a route to it (#161).
@Suite("Simulator device listing")
struct SimulatorDeviceListingTests {
    private let udid = "5A1E2B3C-4D5E-4F60-8172-93A4B5C6D7E8"

    /// A devices folder in the temp directory with one shut-down device and its
    /// `device.plist`, the shape the plist fallback reads.
    private func makeDevicesRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorDeviceListingTests-\(UUID().uuidString)/Devices", isDirectory: true)
        let device = root.appendingPathComponent(udid, isDirectory: true)
        try FileManager.default.createDirectory(at: device.appendingPathComponent("data"), withIntermediateDirectories: true)
        let plist: NSDictionary = [
            "UDID": udid,
            "name": "iPhone 17",
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            "state": 1,
        ]
        try plist.write(to: device.appendingPathComponent("device.plist"))
        return root
    }

    private func output(_ status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> ProcessRunner.Output {
        ProcessRunner.Output(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timedOut)
    }

    @Test func noSimctlOffersNoDevices() throws {
        let root = try makeDevicesRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(DevScanner().simulatorDevices(fromListing: nil, devicesRoot: root).isEmpty)
    }

    @Test(arguments: [
        "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH",
        "You have not agreed to the Xcode license agreements.",
        "CoreSimulator is out of date. Current version (1010.10) is older than build version (1010.15).",
    ])
    func failedListOffersNoDevicesFromThePlists(stderr: String) throws {
        let root = try makeDevicesRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let failed = output(72, stderr: stderr)
        #expect(DevScanner().simulatorDevices(fromListing: failed, devicesRoot: root).isEmpty)
    }

    @Test func slowListStillFallsBackToThePlists() throws {
        let root = try makeDevicesRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let devices = DevScanner().simulatorDevices(fromListing: output(0, timedOut: true), devicesRoot: root)
        #expect(devices.map(\.id.uuidString) == [udid])
    }

    @Test func listedDeviceIsOffered() throws {
        let root = try makeDevicesRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let dataPath = root.appendingPathComponent("\(udid)/data").path
        let json = """
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
              {"udid": "\(udid)", "state": "Shutdown", "name": "iPhone 17", "isAvailable": true, "dataPath": "\(dataPath)"}
            ]}}
            """
        let devices = DevScanner().simulatorDevices(fromListing: output(0, stdout: json), devicesRoot: root)
        #expect(devices.map(\.id.uuidString) == [udid])
    }
}
