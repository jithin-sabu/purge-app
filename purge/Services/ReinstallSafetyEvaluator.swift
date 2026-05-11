import Foundation

enum ReinstallSafetyEvaluator {
    nonisolated private static func hasFile(_ dir: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    /// Parent folder relative to artifact (for `something/node_modules` parent is project root).
    nonisolated static func evaluate(artifactKind: DeletableArtifactKind, artifactURL: URL) -> ReinstallSafetyStatus {
        switch artifactKind {
        case .nodeModules:
            let parent = artifactURL.deletingLastPathComponent()
            guard hasFile(parent, "package.json") else { return .missingLockfile }
            let hasLock = hasFile(parent, "package-lock.json")
                || hasFile(parent, "npm-shrinkwrap.json")
                || hasFile(parent, "yarn.lock")
                || hasFile(parent, "pnpm-lock.yaml")
            return hasLock ? .reinstallable : .missingLockfile

        case .venv:
            let parent = artifactURL.deletingLastPathComponent()
            let ok = hasFile(parent, "requirements.txt") || hasFile(parent, "pyproject.toml")
            return ok ? .reinstallable : .missingLockfile

        case .target:
            let parent = artifactURL.deletingLastPathComponent()
            return hasFile(parent, "Cargo.toml") ? .reinstallable : .missingLockfile

        case .dotGradle:
            let parent = artifactURL.deletingLastPathComponent()
            let ok = gradleEvidenceExists(in: parent)
            return ok ? .reinstallable : .missingLockfile

        case .pods:
            let podsParent = artifactURL.deletingLastPathComponent()
            return hasFile(podsParent, "Podfile.lock") ? .reinstallable : .missingLockfile

        case .dartTool, .flutterBuild:
            let parent = artifactURL.deletingLastPathComponent()
            guard hasFile(parent, "pubspec.yaml") else { return .missingLockfile }
            return hasFile(parent, "pubspec.lock") ? .reinstallable : .missingLockfile
        }
    }

    nonisolated private static func gradleEvidenceExists(in projectRoot: URL) -> Bool {
        if hasFile(projectRoot, "build.gradle") || hasFile(projectRoot, "build.gradle.kts")
            || hasFile(projectRoot, "settings.gradle") || hasFile(projectRoot, "settings.gradle.kts") {
            return true
        }
        let android = projectRoot.appendingPathComponent("android", isDirectory: true)
        return hasFile(android, "build.gradle") || hasFile(android, "build.gradle.kts")
    }

    /// For paths like global Derived Data (always safe reinstall-wise).
    nonisolated static func evaluateGlobalCachePath(lastPathComponent: String) -> ReinstallSafetyStatus {
        switch lastPathComponent.lowercased() {
        case "deriveddata":
            return .notApplicable
        default:
            return .notApplicable
        }
    }

    nonisolated static func evaluateByFolderNameDeleting(path: URL) -> ReinstallSafetyStatus {
        let name = path.lastPathComponent.lowercased()
        switch name {
        case "node_modules":
            return evaluate(artifactKind: .nodeModules, artifactURL: path)
        case "venv", ".venv":
            let parent = path.deletingLastPathComponent()
            return hasFile(parent, "requirements.txt") || hasFile(parent, "pyproject.toml")
                ? .reinstallable : .missingLockfile
        case ".gradle":
            let parent = path.deletingLastPathComponent()
            return gradleEvidenceExists(in: parent) ? .reinstallable : .missingLockfile
        case "target":
            return evaluate(artifactKind: .target, artifactURL: path)
        case "pods":
            return evaluate(artifactKind: .pods, artifactURL: path)
        case "deriveddata":
            return .notApplicable
        default:
            return .notApplicable
        }
    }
}
