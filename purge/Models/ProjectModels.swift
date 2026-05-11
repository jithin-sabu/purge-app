import Foundation
import SwiftUI

enum NodePackageManager: String, Hashable, Sendable {
    case npm
    case pnpm
    case yarn

    nonisolated var badgeLabel: String { rawValue }

    nonisolated var installCommand: String {
        switch self {
        case .npm: return "npm install"
        case .pnpm: return "pnpm install"
        case .yarn: return "yarn install"
        }
    }

    nonisolated static func detect(in projectDirectory: URL) -> NodePackageManager {
        if FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent("pnpm-lock.yaml").path) {
            return .pnpm
        }
        if FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent("yarn.lock").path) {
            return .yarn
        }
        if FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent("package-lock.json").path)
            || FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent("npm-shrinkwrap.json").path) {
            return .npm
        }
        return .npm
    }
}

enum ProjectType: Hashable, Sendable {
    case node
    case rust
    case flutter
    case xcode
    case python
    case androidGradle

    var displayName: String {
        switch self {
        case .node: return "Node"
        case .rust: return "Rust"
        case .flutter: return "Flutter"
        case .xcode: return "Xcode"
        case .python: return "Python"
        case .androidGradle: return "Android"
        }
    }

    var systemImageName: String {
        switch self {
        case .node: return "cube.box.fill"
        case .rust: return "gearshape.2.fill"
        case .flutter: return "wind"
        case .xcode: return "hammer.fill"
        case .python: return "ladybug.fill"
        case .androidGradle: return "android"
        }
    }
}

/// High-level grouping of removable folders tied to one project directory.
enum DeletableArtifactKind: String, Hashable, Sendable {
    case nodeModules = "node_modules"
    case venv
    case dotGradle = ".gradle"
    case target
    case pods = "Pods"
    case dartTool = ".dart_tool"
    case flutterBuild = "Flutter build"

    /// `explanations.json` lookup key used for headline and explanation.
    nonisolated var explanationKey: String {
        switch self {
        case .nodeModules: return "node_modules"
        case .venv: return "venv"
        case .dotGradle: return "gradle"
        case .target: return "target"
        case .pods: return "Pods"
        case .dartTool: return "flutter"
        case .flutterBuild: return "flutter"
        }
    }

    nonisolated var rowTag: String {
        switch self {
        case .nodeModules: return "Dependencies"
        case .venv: return "Python env"
        case .dotGradle: return "Gradle"
        case .target: return "Rust build"
        case .pods: return "Pods"
        case .dartTool: return "Dart tool cache"
        case .flutterBuild: return "Flutter build"
        }
    }
}

/// One folder under a detected project shown in lists and selectable for deletion.
struct ProjectCacheArtifact: Identifiable, Hashable {
    var id: String { path.path }

    let kind: DeletableArtifactKind
    /// Path to delete.
    let path: URL
    let projectRoot: URL
    let sizeBytes: Int64
    let lastModified: Date
    var isSelected: Bool
    /// Initial SafetyInfo headline comes from explanations; reinstall command varies by artifact.
    /// Mutable so manual user overrides and recategorize results can update it in place.
    var safetyInfo: SafetyInfo

    /// Filled asynchronously after filesystem scan completes.
    var reinstallSafety: ReinstallSafetyStatus

    /// Per-session Git cleanliness for the enclosing repo (`unknown` until resolved).
    var gitStatus: GitWorktreeStatus

    var formattedSize: String { formatBytes(sizeBytes) }
}

/// A collapsible Dev Tools group: multiple artifacts under one project root.
struct ProjectGroup: Identifiable, Hashable {
    var id: String { rootPath.path }

    let displayName: String
    let rootPath: URL
    let inferredTypes: [ProjectType]

    /// Sorted by descending size elsewhere.
    var artifacts: [ProjectCacheArtifact]

    var totalBytes: Int64 {
        artifacts.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    var formattedTotal: String { formatBytes(totalBytes) }
}
