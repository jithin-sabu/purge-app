import Foundation
import Testing
@testable import Purge

/// The Command-line tools section in the store (#225), with the scan faked.
/// Nothing here reaches a delete that succeeds: the in-use refusal stops before
/// the Trash, and the hand-off runs a manager that fails, so the user's History
/// is never written.
@MainActor
@Suite("Command-line tools in the store")
struct CommandLineToolStoreTests {
    private let fm = FileManager.default

    private func makeFolder() throws -> URL {
        let folder = fm.temporaryDirectory
            .appendingPathComponent("CommandLineToolStoreTests-\(UUID().uuidString)/.tool", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.standardizedFileURL
    }

    private func standalone(_ folder: URL, size: Int64 = 4_000) -> StandaloneCommandLineTool {
        StandaloneCommandLineTool(
            install: CommandLineToolInstall(
                name: "tool", folder: folder, shims: [], launchAgents: [], kept: [], source: .shim
            ),
            sizeBytes: size,
            settingsFiles: [".env"]
        )
    }

    @Test
    func scanFillsTheSectionAndNothingIsPreselected() async throws {
        let folder = try makeFolder()
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent()) }
        let fake = FakeScans()
        fake.commandLineTools = CommandLineToolScanResult(standalone: [standalone(folder)], managed: [])
        let store = fake.makeStore()

        store.requestScanIfNeeded(.commandLineTools)
        #expect(await eventually { store.hasSessionResults(for: .commandLineTools) })
        #expect(store.commandLineTools.standalone.map(\.id) == [folder.path])
        #expect(store.commandLineToolSelectedIDs.isEmpty)
        #expect(store.commandLineToolRemovalPlan == nil)
        store.requestCommandLineToolRemoval()
        #expect(store.commandLineToolRemovalPlan == nil)
        fake.cleanUp()
    }

    /// A process with a file open in the folder keeps the sheet open with the
    /// reason, and nothing is removed.
    @Test
    func removalIsRefusedWhileAProcessUsesTheFolder() async throws {
        let folder = try makeFolder()
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent()) }
        let file = folder.appendingPathComponent("log.txt")
        try Data("x\n".utf8).write(to: file)
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", file.path]
        tail.standardOutput = FileHandle.nullDevice
        try tail.run()
        defer { tail.terminate() }
        try await Task.sleep(for: .milliseconds(300))

        let fake = FakeScans()
        fake.commandLineTools = CommandLineToolScanResult(standalone: [standalone(folder)], managed: [])
        let store = fake.makeStore()
        await store.scanCommandLineTools()
        store.toggleCommandLineToolSelected(id: folder.path)
        store.requestCommandLineToolRemoval()
        #expect(store.commandLineToolRemovalPlan?.tools.count == 1)

        await store.confirmCommandLineToolRemoval()

        let plan = try #require(store.commandLineToolRemovalPlan)
        #expect(plan.phase == .review)
        #expect(plan.refusal?.contains("tail") == true)
        #expect(fm.fileExists(atPath: folder.path))
        #expect(store.commandLineTools.standalone.count == 1)
        #expect(store.manualDeletionSession == nil)
        fake.cleanUp()
    }

    /// Package-manager rows are ticked like the others. When the manager
    /// refuses, its row in the sheet says so, the row stays in the list, the
    /// tool is still there, and nothing is written to History.
    @Test
    func managerFailureStaysInTheSheet() async throws {
        let folder = try makeFolder()
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent()) }
        let tool = PackageManagerTool(
            manager: .homebrew, name: "jq", locations: [folder], context: nil,
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: ["uninstall", "--formula", "jq"], environment: ["PATH": "/usr/bin:/bin"],
            sizeBytes: 1_000
        )
        let missing = PackageManagerTool(
            manager: .pipx, name: "black", locations: [folder], context: nil, executable: nil,
            arguments: ["uninstall", "black"], environment: [:], sizeBytes: 500
        )
        let fake = FakeScans()
        fake.commandLineTools = CommandLineToolScanResult(standalone: [], managed: [tool, missing])
        let store = fake.makeStore()
        await store.scanCommandLineTools()

        store.setAllCommandLineToolsSelected(true, ids: [tool.id, missing.id])
        #expect(store.selectedCommandLineToolCount == 2)
        #expect(store.selectedCommandLineToolBytes == 1_500)
        store.requestCommandLineToolRemoval()
        #expect(store.commandLineToolRemovalPlan?.managed.count == 2)
        await store.confirmCommandLineToolRemoval()

        let plan = try #require(store.commandLineToolRemovalPlan)
        #expect(plan.phase == .finished)
        guard case .failed = plan.state(of: tool.id) else {
            Issue.record("A failed run must show as failed in the sheet")
            fake.cleanUp()
            return
        }
        #expect(plan.state(of: missing.id) == .managerMissing)
        #expect(plan.failedCount == 2)
        #expect(store.commandLineTools.managed.map(\.id) == [tool.id, missing.id])
        #expect(store.lastDeletionReport == nil)
        #expect(fm.fileExists(atPath: folder.path))
        #expect(!store.isDeleting)
        store.closeCommandLineToolRemoval()
        #expect(store.commandLineToolRemovalPlan == nil)
        fake.cleanUp()
    }

    @Test
    func reviewOrRunningHandoffHoldsAScheduledClean() async throws {
        let folder = try makeFolder()
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent()) }
        let fake = FakeScans()
        fake.commandLineTools = CommandLineToolScanResult(standalone: [standalone(folder)], managed: [])
        let store = fake.makeStore()
        await store.scanCommandLineTools()
        store.setAllCommandLineToolsSelected(true, ids: [folder.path])
        store.requestCommandLineToolRemoval()
        #expect(store.isReviewingOrCleaning)
        store.closeCommandLineToolRemoval()
        #expect(!store.isReviewingOrCleaning)
        fake.cleanUp()
    }

    private func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
        var waited: TimeInterval = 0
        var last = Date()
        while !condition() {
            guard waited < timeout else { return false }
            try? await Task.sleep(for: .milliseconds(10))
            let now = Date()
            waited += min(now.timeIntervalSince(last), 0.25)
            last = now
        }
        return true
    }
}
