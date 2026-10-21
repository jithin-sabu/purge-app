import Foundation

/// A package manager whose installs the uninstaller lists and hands back to it
/// (#225). The manager knows the dependencies and keeps its own records, so it
/// does the removal; Purge moves no file for these.
nonisolated enum PackageManager: String, CaseIterable, Sendable {
    case homebrew
    case npm
    case pipx
    case uv
    case cargo

    var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .npm: return "npm"
        case .pipx: return "pipx"
        case .uv: return "uv"
        case .cargo: return "Cargo"
        }
    }

    /// The command as people type it, without the package name.
    var commandPrefix: [String] {
        switch self {
        case .homebrew: return ["brew", "uninstall", "--formula"]
        case .npm: return ["npm", "uninstall", "-g"]
        case .pipx: return ["pipx", "uninstall"]
        case .uv: return ["uv", "tool", "uninstall"]
        case .cargo: return ["cargo", "uninstall"]
        }
    }

    /// Package names the manager accepts, and nothing that could read as an
    /// option. Names come from folder names on disk, so they are checked
    /// before they reach a command line.
    func isValidPackageName(_ name: String) -> Bool {
        let pattern: String
        switch self {
        case .homebrew: pattern = #"^[a-z0-9][a-z0-9@+._-]*$"#
        case .npm: pattern = #"^(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*$"#
        case .pipx, .uv: pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
        case .cargo: pattern = #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#
        }
        return name.count <= 214 && name.range(of: pattern, options: .regularExpression) != nil
    }
}

/// One tool a package manager installed: where it lives, and the exact
/// command that removes it.
nonisolated struct PackageManagerTool: Equatable, Sendable, Identifiable {
    let manager: PackageManager
    let name: String
    /// What the manager installed, sized for the row. The manager removes
    /// these; the check after a run looks for them.
    let locations: [URL]
    /// Which install of the manager owns it, when there is more than one,
    /// such as "Node 20.20.0" for npm under nvm.
    let context: String?
    /// The manager's program, or nil when Purge could not find it. The row
    /// then offers the command to copy only.
    let executable: URL?
    /// The arguments after `executable`.
    let arguments: [String]
    /// The whole environment the command runs with.
    let environment: [String: String]
    var sizeBytes: Int64 = 0

    var id: String { manager.rawValue + ":" + (locations.first?.standardizedFileURL.path ?? name) }

    /// The command as people type it, for the confirm and for copying.
    var command: String { (manager.commandPrefix + [name]).joined(separator: " ") }

    var canRun: Bool { executable != nil }
}
