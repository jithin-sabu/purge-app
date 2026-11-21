import Foundation
import os

/// Variables set in the user's launchd domain with `launchctl setenv` (#318).
///
/// Ollama's own docs tell Mac users to move the model store this way, because
/// Ollama.app reads launchd's environment, not a shell profile. Purge gets that
/// environment only as it was when Purge started, so a login item or a Dock
/// launch before the `setenv` never sees it. This reads it again.
///
/// Reading runs `launchctl`, so it happens only in `refresh()`, off the main
/// thread, at the start of each AI model scan, command-line tool scan and
/// user-picked delete. Every other read takes the value from then.
nonisolated enum LaunchdEnvironment {
    typealias Runner = @Sendable (_ executablePath: String, _ arguments: [String]) -> ProcessRunner.Output?

    /// The names read: Ollama's store, where Go keeps its module cache
    /// (#397), and the toolchain rustup is told to use (#406).
    static let names = ["OLLAMA_MODELS", "GOMODCACHE", "GOPATH", "GOENV", "RUSTUP_TOOLCHAIN"]

    static let launchctlPath = "/bin/launchctl"

    /// What one read of a name found. A read that failed is not an unset name:
    /// rustup's rule keeps every toolchain on it (#406).
    nonisolated enum Read: Equatable, Sendable {
        case value(String)
        case unset
        /// `launchctl` couldn't start, timed out, or exited with an error.
        case failed
    }

    /// The values as last read. Empty in the test host until a test refreshes
    /// with its own runner.
    static var values: [String: String] {
        store.withLock { $0.values }
    }

    /// What the last `refresh()` found for `name`. Unset before any refresh.
    static func lastRead(_ name: String) -> Read {
        store.withLock { state in
            if state.failed.contains(name) { return .failed }
            return state.values[name].map { .value($0) } ?? .unset
        }
    }

    /// Reads one name from launchd now, for a check that can't trust a read
    /// from the start of a clean. Runs `launchctl`, so never on the main
    /// thread. The test host answers from the last refresh unless the test
    /// passes a runner.
    static func readNow(_ name: String, runner: Runner? = nil) -> Read {
        if let runner { return read(name, runner: runner) }
        guard !RemovedAppHandoff.runsInTestHost else { return lastRead(name) }
        return read(name, runner: liveRunner)
    }

    /// Reads each name from launchd. The test host never runs `launchctl`
    /// unless the test passes a runner.
    @discardableResult
    static func refresh(runner: Runner? = nil) -> [String: String] {
        let run: Runner
        if let runner {
            run = runner
        } else {
            guard !RemovedAppHandoff.runsInTestHost else { return values }
            run = liveRunner
        }
        var state = State()
        for name in names {
            switch read(name, runner: run) {
            case .value(let value): state.values[name] = value
            case .unset: break
            case .failed: state.failed.insert(name)
            }
        }
        let result = state
        store.withLock { $0 = result }
        return result.values
    }

    /// `launchctl getenv NAME` prints the value, or nothing when it is unset,
    /// and exits with 0 either way.
    static func read(_ name: String, runner: Runner) -> Read {
        guard let output = runner(launchctlPath, ["getenv", name]), output.succeeded else { return .failed }
        let value = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? .unset : .value(value)
    }

    /// The value of `name`, or nil when it is unset or couldn't be read.
    static func value(of name: String, runner: Runner) -> String? {
        if case .value(let value) = read(name, runner: runner) { return value }
        return nil
    }

    /// `environment` with each name it lacks filled in from launchd. A value
    /// Purge was started with wins: it is what a Terminal launch asked for.
    static func merged(
        into environment: [String: String],
        launchd: [String: String] = LaunchdEnvironment.values
    ) -> [String: String] {
        var result = environment
        for (name, value) in launchd where (result[name] ?? "").isEmpty {
            result[name] = value
        }
        return result
    }

    private struct State: Sendable {
        var values: [String: String] = [:]
        /// Names whose last read failed.
        var failed: Set<String> = []
    }

    private static let store = OSAllocatedUnfairLock<State>(initialState: State())

    private static let liveRunner: Runner = { path, arguments in
        ProcessRunner.run(executablePath: path, arguments: arguments, timeout: 2)
    }
}
