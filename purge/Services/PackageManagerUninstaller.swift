import Foundation

/// Runs a package manager's own uninstall command for one tool the user
/// picked and confirmed (#225). Purge deletes no file here: the manager does,
/// permanently, with its own dependency checks. Purge never adds a flag that
/// skips those checks, such as `--ignore-dependencies`.
///
/// Like simulator runtimes and the Apple Intelligence models, this is never
/// part of Clean Safe Items or a scheduled clean.
nonisolated enum PackageManagerUninstaller {
    nonisolated enum Outcome: Equatable, Sendable {
        case removed
        /// The manager refused or failed. The message is its own last lines.
        case failed(String)
        /// The manager said it worked, but what it installed is still there.
        case stillPresent
        /// Purge found no program for this manager; copy the command instead.
        case managerMissing
        /// The row no longer matches the disk; nothing was run.
        case gone
    }

    typealias Runner = @Sendable (
        _ executablePath: String, _ arguments: [String], _ environment: [String: String]
    ) async -> ProcessRunner.Output?

    /// Homebrew can take a while to unlink a big formula.
    static let timeout: TimeInterval = 300
    static let messageLineLimit = 6

    static func uninstall(_ tool: PackageManagerTool, runner: Runner = liveRunner) async -> Outcome {
        guard let executable = tool.executable else { return .managerMissing }
        guard tool.manager.isValidPackageName(tool.name),
              tool.arguments.last == tool.name,
              tool.locations.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return .gone }
        guard let output = await runner(executable.path, tool.arguments, tool.environment) else {
            return .failed(String(localized: "Purge couldn't start \(tool.manager.displayName)."))
        }
        if output.timedOut {
            return .failed(String(localized: "\(tool.manager.displayName) didn't finish in time."))
        }
        guard output.status == 0 else {
            return .failed(lastLines(of: output.stderrText.isEmpty ? output.stdoutText : output.stderrText)
                ?? String(localized: "\(tool.manager.displayName) stopped with an error."))
        }
        let remaining = tool.locations.filter { FileManager.default.fileExists(atPath: $0.path) }
        return remaining.isEmpty ? .removed : .stillPresent
    }

    /// The manager's last few non-empty lines, for the failure message.
    static func lastLines(of text: String) -> String? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(messageLineLimit).joined(separator: "\n")
    }

    static let liveRunner: Runner = { path, arguments, environment in
        await ProcessRunner.runAsync(
            executablePath: path,
            arguments: arguments,
            timeout: timeout,
            environment: environment
        )
    }
}
