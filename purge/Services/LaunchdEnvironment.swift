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

    /// The values as last read. Empty in the test host until a test refreshes
    /// with its own runner.
    static var values: [String: String] {
        store.withLock { $0 }
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
        var read: [String: String] = [:]
        for name in names {
            if let value = value(of: name, runner: run) { read[name] = value }
        }
        let result = read
        store.withLock { $0 = result }
        return result
    }

    /// `launchctl getenv NAME` prints the value, or nothing when it is unset.
    static func value(of name: String, runner: Runner) -> String? {
        guard let output = runner(launchctlPath, ["getenv", name]), output.succeeded else { return nil }
        let value = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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

    private static let store = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private static let liveRunner: Runner = { path, arguments in
        ProcessRunner.run(executablePath: path, arguments: arguments, timeout: 2)
    }
}
