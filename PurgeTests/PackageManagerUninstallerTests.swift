import Foundation
import Testing
@testable import Purge

/// Running a package manager's own uninstall (#225), with the runner faked:
/// the exact command and environment, success only when the tool is gone, and
/// the manager's own words when it refuses.
@Suite("Package-manager uninstaller")
struct PackageManagerUninstallerTests {
    private let fm = FileManager.default

    private func makeTool(executable: URL? = URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                          name: String = "jq") throws -> (PackageManagerTool, URL) {
        let folder = fm.temporaryDirectory
            .appendingPathComponent("PackageManagerUninstallerTests-\(UUID().uuidString)/Cellar/\(name)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = PackageManagerTool(
            manager: .homebrew, name: name, locations: [folder], context: nil, executable: executable,
            arguments: ["uninstall", "--formula", name], environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        )
        return (tool, folder)
    }

    private func output(_ status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false)
        -> ProcessRunner.Output {
        ProcessRunner.Output(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timedOut)
    }

    @Test
    func runsTheExactCommandAndChecksTheToolIsGone() async throws {
        let (tool, folder) = try makeTool()
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let seen = Recorder()
        let outcome = await PackageManagerUninstaller.uninstall(tool) { path, arguments, environment in
            seen.record(path, arguments, environment)
            try? FileManager.default.removeItem(at: folder)
            return output(0, stdout: "Uninstalling /opt/homebrew/Cellar/jq/1.7.1... (20 files, 1.4MB)")
        }
        #expect(outcome == .removed)
        #expect(seen.path == "/opt/homebrew/bin/brew")
        #expect(seen.arguments == ["uninstall", "--formula", "jq"])
        #expect(seen.environment == ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"])
    }

    @Test
    func managerRefusalShowsItsOwnMessage() async throws {
        let (tool, folder) = try makeTool()
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let message = "Error: Refusing to uninstall /opt/homebrew/Cellar/jq/1.7.1\nbecause it is required by yq, which is currently installed."
        let outcome = await PackageManagerUninstaller.uninstall(tool) { _, _, _ in output(1, stderr: message + "\n\n") }
        #expect(outcome == .failed(message))
    }

    @Test
    func successWithTheToolStillThereIsNotRemoved() async throws {
        let (tool, folder) = try makeTool()
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(await PackageManagerUninstaller.uninstall(tool) { _, _, _ in output(0) } == .stillPresent)
    }

    @Test
    func timeoutAndLaunchFailureAreFailures() async throws {
        let (tool, folder) = try makeTool()
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        if case .failed = await PackageManagerUninstaller.uninstall(tool, runner: { _, _, _ in output(-1, timedOut: true) }) {} else {
            Issue.record("A timed-out run must be a failure")
        }
        if case .failed = await PackageManagerUninstaller.uninstall(tool, runner: { _, _, _ in nil }) {} else {
            Issue.record("A run that could not start must be a failure")
        }
    }

    @Test
    func nothingRunsWithoutAManagerOrWhenTheToolIsGone() async throws {
        let (missing, folder) = try makeTool(executable: nil)
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let seen = Recorder()
        let runner: PackageManagerUninstaller.Runner = { path, arguments, environment in
            seen.record(path, arguments, environment)
            return output(0)
        }
        #expect(await PackageManagerUninstaller.uninstall(missing, runner: runner) == .managerMissing)
        let (present, _) = try makeTool()
        try fm.removeItem(at: present.locations[0])
        #expect(await PackageManagerUninstaller.uninstall(present, runner: runner) == .gone)
        #expect(seen.path == nil)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (String, [String], [String: String])?

    func record(_ path: String, _ arguments: [String], _ environment: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        values = (path, arguments, environment)
    }

    var path: String? { lock.lock(); defer { lock.unlock() }; return values?.0 }
    var arguments: [String]? { lock.lock(); defer { lock.unlock() }; return values?.1 }
    var environment: [String: String]? { lock.lock(); defer { lock.unlock() }; return values?.2 }
}
