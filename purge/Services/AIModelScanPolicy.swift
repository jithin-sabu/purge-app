import Foundation

/// Bounds for locally downloaded AI models (Ollama, LM Studio).
///
/// These live in hidden directories outside the Large Files scan roots, so they
/// need their own roots and their own deletion gate. Kept separate from
/// `LargeFileScanPolicy` because a model row stands for several files at once —
/// an Ollama model is a manifest plus the blobs it owns — and the eligibility
/// rule has to admit those blobs by their content-addressed names.
enum AIModelScanPolicy {
    enum Runtime: String, CaseIterable {
        case ollama
        case lmStudio

        var displayName: String {
            switch self {
            case .ollama: return "Ollama"
            case .lmStudio: return "LM Studio"
            }
        }
    }

    /// Ollama honours `OLLAMA_MODELS` for users who move the store to an
    /// external drive, so the default path is a fallback rather than a given.
    nonisolated static func ollamaRoot(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["OLLAMA_MODELS"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return home.appendingPathComponent(".ollama/models", isDirectory: true).standardizedFileURL
    }

    /// Current LM Studio location first, then the pre-0.3 cache location. Both
    /// are checked because an upgrade leaves the old directory behind.
    nonisolated static func lmStudioRoots(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".lmstudio/models", isDirectory: true),
            home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true)
        ].map(\.standardizedFileURL)
    }

    nonisolated static func allRoots(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        [ollamaRoot(home: home, environment: environment)] + lmStudioRoots(home: home)
    }

    /// A path may be removed only if it sits strictly inside one of the model
    /// roots. The roots themselves are never deletable — emptying
    /// `~/.ollama/models` wholesale is not something a row should ever mean.
    nonisolated static func isEligibleForDeletion(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return false }

        return allRoots(home: home, environment: environment).contains { root in
            path.hasPrefix(root.path + "/")
        }
    }
}
