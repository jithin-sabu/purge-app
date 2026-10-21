import Foundation
import Testing
@testable import Purge

/// The in-use check before a command-line tool's folder goes (#225), and the
/// background job stop that comes before it.
@Suite("Command-line tool in-use check")
struct OpenFileCheckTests {
    private let listing = """
        p100
        cloginwindow
        fcwd
        n/
        p200
        chermes
        ftxt
        n/Users/a/.hermes/hermes-agent/.hermes/bin/python3
        f3
        n/Users/a/.hermes/state.db
        p300
        cgrok
        fcwd
        n/Users/a/.hermes-other/x
        """

    @Test
    func processWithAFileInsideTheFolderIsAHolder() {
        let holders = OpenFileCheck.holders(in: listing, folders: ["/Users/a/.hermes"])
        #expect(holders == [OpenFileCheck.Holder(pid: 200, command: "hermes")])
    }

    @Test
    func listingThatCouldNotBeReadRefuses() {
        let folder = URL(fileURLWithPath: "/Users/a/.hermes")
        #expect(OpenFileCheck.check(folders: [folder], lister: { nil }) == .unavailable)
        #expect(OpenFileCheck.check(folders: [URL(fileURLWithPath: "/Users/a/.nothing")], lister: { listing }) == .free)
    }

    /// A real process with a file open in the folder refuses the removal.
    @Test
    func runningProcessWithAnOpenFileRefusesTheRemoval() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("OpenFileCheckTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("log.txt")
        try Data("x\n".utf8).write(to: file)

        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", file.path]
        tail.standardOutput = FileHandle.nullDevice
        try tail.run()
        defer { tail.terminate() }

        var result = OpenFileCheck.Result.free
        for _ in 0..<20 {
            result = await Task.detached { OpenFileCheck.check(folders: [folder]) }.value
            if case .inUse = result { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(result == .inUse([OpenFileCheck.Holder(pid: tail.processIdentifier, command: "tail")]))
    }

    // MARK: launchctl

    private func output(_ status: Int32, stderr: String = "") -> ProcessRunner.Output {
        ProcessRunner.Output(status: status, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false)
    }

    @Test
    func stopBootsOutTheOneJobInTheUsersDomain() {
        let calls = CallLog()
        let outcome = LaunchAgentStopper.stop(label: "com.example.daemon", uid: 501) { path, arguments in
            calls.append(path, arguments)
            return output(0)
        }
        #expect(outcome == .stopped)
        #expect(calls.entries == [["/bin/launchctl", "bootout", "gui/501/com.example.daemon"]])
    }

    @Test
    func jobThatIsNotLoadedCountsAsStopped() {
        #expect(LaunchAgentStopper.stop(label: "x", uid: 501) { _, _ in output(3) } == .notLoaded)
        #expect(LaunchAgentStopper.stop(label: "x", uid: 501) { _, _ in output(113) } == .notLoaded)
    }

    @Test
    func otherFailuresRefuse() {
        #expect(LaunchAgentStopper.stop(label: "x", uid: 501) { _, _ in output(5, stderr: "Boot-out failed: 5: Input/output error") }
            == .failed("Boot-out failed: 5: Input/output error"))
        if case .failed = LaunchAgentStopper.stop(label: "x", uid: 501, runner: { _, _ in nil }) {} else {
            Issue.record("A launchctl that could not run must refuse")
        }
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    func append(_ path: String, _ arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        calls.append([path] + arguments)
    }

    var entries: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
