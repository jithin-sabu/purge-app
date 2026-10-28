import Foundation
import Testing
@testable import Purge

/// The Not Sure and unsaved-git alerts say the files go to the Trash and can be
/// put back. That is only true when nothing in the cleanup is deleted permanently,
/// so a simulator or runtime in the selection must add the simctl sentence.
/// Every test stops at the alert and cancels, so nothing reaches the engine.
/// The paths do not exist on disk.
@MainActor
@Suite("Deletion confirmation wording")
struct DeletionConfirmationWordingTests {
    private static let simctlSentence = "deleted permanently through simctl"
    private static let putBack = "so you can put them back"

    private let home = FileManager.default.homeDirectoryForCurrentUser

    private func candidate(
        _ url: URL,
        level: SafetyLevel = .medium,
        gitStatus: GitWorktreeStatus = .unknown
    ) -> PurgeStore.DeletionCandidate {
        PurgeStore.DeletionCandidate(
            title: url.lastPathComponent,
            path: url,
            sizeBytes: 1,
            safetyInfo: SafetyInfo(level: level, headline: url.lastPathComponent, explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: gitStatus
        )
    }

    private func unusedPath(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
            .appendingPathComponent("PurgeConfirmWordingTests-\(UUID().uuidString)", isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private func unusedDevicePath() throws -> URL {
        let url = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private func runtime() -> SimulatorRuntime {
        SimulatorRuntime(
            id: "7AE1D6B6-5524-4FAD-B793-1D1C911E5269",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-3",
            platformName: "iOS",
            version: "26.3.1",
            build: "23D8133",
            kind: "Patchable Cryptex Disk Image",
            state: "Ready",
            sizeBytes: 8_393_503_393,
            lastUsedAt: nil,
            deviceCount: 0,
            locationURL: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes/iOS_26.3.1", isDirectory: true),
            safetyInfo: SimulatorRuntime.safetyInfo(
                platformName: "iOS", version: "26.3.1", state: "Ready", sizeBytes: 8_393_503_393,
                lastUsedAt: nil, deviceCount: 0, isXcodeDefault: false
            )
        )
    }

    /// Opens the Not Sure alert. Any `.unknown` pick stops the flow there.
    private func notSureMessage(_ store: PurgeStore, _ picks: [PurgeStore.DeletionCandidate]) throws -> String {
        store.presentDeletionSheet(candidates: picks)
        store.userConfirmedDeletionFromPrimarySheet()
        try #require(store.showHighRiskDeletionSecondConfirm)
        let message = store.highRiskDeletionSecondConfirmMessage
        store.cancelHighRiskDeletionSecondStep()
        return message
    }

    /// Opens the unsaved-git alert. A `.dirty` pick stops the flow there.
    private func gitMessage(_ store: PurgeStore, _ picks: [PurgeStore.DeletionCandidate]) throws -> String {
        store.presentDeletionSheet(candidates: picks)
        store.userConfirmedDeletionFromPrimarySheet()
        try #require(store.showUncommittedGitFriction)
        let message = store.uncommittedGitFrictionMessage
        store.cancelDeletionFrictionFlow()
        return message
    }

    @Test func notSureFoldersOnlySayTheTrash() throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let folder = try unusedPath("Library/Caches")

        let message = try notSureMessage(store, [candidate(folder, level: .unknown)])

        #expect(message.contains(Self.putBack))
        #expect(!message.contains(Self.simctlSentence))
    }

    @Test func notSureWithASimulatorNamesSimctl() throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let folder = try unusedPath("Library/Caches")

        let message = try notSureMessage(store, [candidate(folder, level: .unknown), candidate(try unusedDevicePath())])

        #expect(message.contains(Self.simctlSentence))
    }

    @Test func notSureWithARuntimeNamesSimctl() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime()
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()
        let folder = try unusedPath("Library/Caches")

        let message = try notSureMessage(store, [candidate(folder, level: .unknown), candidate(row.locationURL)])

        #expect(message.contains(Self.simctlSentence))
    }

    @Test func unsavedProjectOnlySaysTheTrash() throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let project = try unusedPath("Developer")

        let message = try gitMessage(store, [candidate(project, gitStatus: .dirty)])

        #expect(message.contains(Self.putBack))
        #expect(!message.contains(Self.simctlSentence))
    }

    @Test func unsavedProjectWithASimulatorNamesSimctl() throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let project = try unusedPath("Developer")

        let message = try gitMessage(store, [candidate(project, gitStatus: .dirty), candidate(try unusedDevicePath())])

        #expect(message.contains(Self.simctlSentence))
        #expect(!message.contains(Self.putBack))
    }
}
