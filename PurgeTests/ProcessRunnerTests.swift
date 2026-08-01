import Foundation
import Testing
@testable import Purge

/// These pin the freeze that shipped in 1.2.9: `simctl list devices --json` printed more than
/// the 64 KB pipe buffer, the scanner called `waitUntilExit()` before reading, and the child
/// blocked mid-write while the app blocked waiting for it to exit — on the main thread, so the
/// whole app beach-balled at launch. Every case below hangs forever against that old code.
@Suite("ProcessRunner")
struct ProcessRunnerTests {
    /// Comfortably past the 64 KB kernel pipe buffer that made the original deadlock possible.
    private static let floodBytes = 512 * 1024

    private func runShell(_ script: String, timeout: TimeInterval = 30) -> ProcessRunner.Output? {
        ProcessRunner.run(executablePath: "/bin/sh", arguments: ["-c", script], timeout: timeout)
    }

    @Test("Output larger than the pipe buffer comes back whole")
    func drainsLargeStdout() async throws {
        let bytes = Self.floodBytes
        let result = try #require(runShell("/usr/bin/head -c \(bytes) /dev/zero"))

        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.count == bytes)
    }

    /// The subtler half: a child can just as easily wedge on a full *stderr* buffer while the
    /// parent reads stdout. `du` does exactly this — one "Permission denied" line per
    /// unreadable directory — so both pipes have to drain concurrently.
    @Test("A child flooding both pipes at once still completes")
    func drainsBothPipesConcurrently() async throws {
        let bytes = Self.floodBytes
        let result = try #require(
            runShell("/usr/bin/head -c \(bytes) /dev/zero; /usr/bin/head -c \(bytes) /dev/zero >&2")
        )

        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.count == bytes)
        #expect(result.stderr.count == bytes)
    }

    @Test("A child that never exits is killed at the timeout")
    func killsHungChild() async throws {
        let started = Date()
        let result = try #require(runShell("/bin/sleep 600", timeout: 1))

        #expect(result.timedOut)
        #expect(!result.succeeded)
        // Timeout plus the SIGTERM grace period, with room for a loaded CI machine.
        #expect(Date().timeIntervalSince(started) < 15)
    }

    /// The reported freeze happened on a machine running a process throttler, and the second
    /// spindump caught `simctl` suspended. SIGTERM only queues for a stopped process, so the
    /// runner has to escalate to SIGKILL or the wait never ends.
    @Test("A suspended child is still reaped")
    func killsSuspendedChild() async throws {
        let started = Date()
        // Stops itself before writing anything, so no pipe ever reaches EOF.
        let result = try #require(runShell("kill -STOP $$; /bin/echo done", timeout: 1))

        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test("Exit status and stderr survive a failing command")
    func reportsFailure() async throws {
        let result = try #require(runShell("/bin/echo oops >&2; exit 3"))

        #expect(!result.succeeded)
        #expect(result.status == 3)
        #expect(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines) == "oops")
    }

    @Test("A missing binary reports launch failure rather than trapping")
    func missingBinaryReturnsNil() async throws {
        let result = ProcessRunner.run(
            executablePath: "/nonexistent/definitely-not-here",
            arguments: [],
            timeout: 5
        )
        #expect(result == nil)
    }

    /// A child inheriting the parent's stdin can block on input that never arrives.
    @Test("Reading stdin gets EOF instead of hanging")
    func stdinIsNullDevice() async throws {
        let result = try #require(runShell("/bin/cat", timeout: 5))

        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    /// The second freeze, caused by the first fix: draining on two helper queues meant every
    /// `run` blocked its thread waiting for work that needed *more* threads. Callers like
    /// `CacheScanner.runSizeJobs` invoke this straight from Swift concurrency tasks, so those
    /// blocked threads were the cooperative pool — only as wide as the core count. Saturate it
    /// and the helper reads never got scheduled. This hangs against that version.
    @Test("Saturating the cooperative pool still completes every child")
    func survivesCooperativePoolSaturation() async throws {
        let jobs = max(ProcessInfo.processInfo.activeProcessorCount * 3, 24)
        let bytes = 256 * 1024

        let results = await withTaskGroup(of: Int?.self, returning: [Int?].self) { group in
            for _ in 0..<jobs {
                group.addTask {
                    // Deliberately the blocking entry point, called from a Swift task, floods
                    // both pipes — exactly the shape of a `du` chunk under CacheScanner.
                    ProcessRunner.run(
                        executablePath: "/bin/sh",
                        arguments: ["-c", "/usr/bin/head -c \(bytes) /dev/zero; /usr/bin/head -c \(bytes) /dev/zero >&2"],
                        timeout: 60
                    )?.stdout.count
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == jobs)
        #expect(results.allSatisfy { $0 == bytes }, "some children did not drain: \(results)")
    }

    @Test("runAsync leaves the main actor free while the child runs")
    @MainActor
    func asyncVariantDoesNotBlockMainActor() async throws {
        // Fails the debug precondition in `run` if the wait happens on the main queue, and
        // deadlocks the flag below if `runAsync` blocks the main actor instead of suspending.
        var mainActorRanDuringChild = false
        async let child = ProcessRunner.runAsync(
            executablePath: "/bin/sleep",
            arguments: ["1"],
            timeout: 10
        )

        await Task.yield()
        mainActorRanDuringChild = true

        let result = try #require(await child)
        #expect(!result.timedOut)
        #expect(mainActorRanDuringChild)
    }
}
