import Foundation

enum ReinstallSafetyEvaluator {
    nonisolated private static func exists(_ dir: URL, _ relative: String) -> Bool {
        let url = dir.appendingPathComponent(relative).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Whether a removed artifact can be brought back cleanly.
    ///
    /// Both checks are resolved against the artifact's own parent directory, which is
    /// the project root for a top-level folder like `node_modules` and a subdirectory
    /// for a nested one like `ios/Pods`. Rules use `..` where the evidence lives a
    /// level up (sbt's `project/target`, Bundler's `vendor/bundle`).
    nonisolated static func evaluate(artifactKind: DeletableArtifactKind, artifactURL: URL) -> ReinstallSafetyStatus {
        status(for: ProjectArtifactCatalog.rules(forKind: artifactKind), artifactURL: artifactURL)
    }

    /// Used when a folder is being deleted without a scan row behind it, so the only
    /// thing known about it is its name.
    ///
    /// Every rule sharing that folder name is considered, not just the first one found.
    /// `target` belongs to Rust, Maven and sbt, and `_build` to both Elixir and Dune;
    /// picking one arbitrarily would report "no lockfile" for a perfectly rebuildable
    /// project simply because a different ecosystem happened to be listed first.
    nonisolated static func evaluateByFolderNameDeleting(path: URL) -> ReinstallSafetyStatus {
        let name = path.lastPathComponent.lowercased()
        let matching = ProjectArtifactCatalog.rules.filter {
            URL(fileURLWithPath: $0.folder).lastPathComponent.lowercased() == name
        }
        return status(for: matching, artifactURL: path)
    }

    /// A kind can carry several rules (Python's `venv` and `.venv`, Zig's two cache
    /// folder names). Any single rule finding complete evidence is enough.
    ///
    /// Rules that require no evidence at all are skipped rather than returned on, so
    /// the verdict does not depend on the order rules happen to sit in the catalog.
    /// Only when *no* rule asked for evidence does this report `.notApplicable`.
    nonisolated private static func status(
        for rules: [ProjectArtifactRule],
        artifactURL: URL
    ) -> ReinstallSafetyStatus {
        guard !rules.isEmpty else { return .notApplicable }
        let parent = artifactURL.deletingLastPathComponent()
        var anyRuleWantedEvidence = false

        for rule in rules {
            guard !rule.rebuildMarkers.isEmpty || !rule.lockfiles.isEmpty else { continue }
            anyRuleWantedEvidence = true

            if !rule.rebuildMarkers.isEmpty {
                guard rule.rebuildMarkers.contains(where: { exists(parent, $0) }) else { continue }
            }
            if !rule.lockfiles.isEmpty {
                guard rule.lockfiles.contains(where: { exists(parent, $0) }) else { continue }
            }
            return .reinstallable
        }

        return anyRuleWantedEvidence ? .missingLockfile : .notApplicable
    }
}
