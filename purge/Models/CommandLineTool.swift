import Foundation

/// A standalone install as the uninstaller lists it: the install set, its size,
/// and the settings files that go with the folder (#225).
nonisolated struct StandaloneCommandLineTool: Equatable, Sendable, Identifiable {
    let install: CommandLineToolInstall
    var sizeBytes: Int64
    /// Top-level files in the folder that look like settings or keys, by name.
    let settingsFiles: [String]

    var id: String { install.id }
    var name: String { install.name }
    var folder: URL { install.folder }

    /// Always Check First: the folder can hold settings, keys and history.
    static let safetyLevel = SafetyLevel.medium
}

/// What the Command-line tools scan found.
nonisolated struct CommandLineToolScanResult: Equatable, Sendable {
    var standalone: [StandaloneCommandLineTool] = []
    var managed: [PackageManagerTool] = []

    var isEmpty: Bool { standalone.isEmpty && managed.isEmpty }
    var totalBytes: Int64 {
        standalone.reduce(Int64(0)) { $0 + $1.sizeBytes } + managed.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }
}

/// The standalone installs the user ticked, awaiting confirmation. Drives the
/// review sheet; the sheet stays open to say why when the removal is refused.
nonisolated struct CommandLineToolRemovalPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    let tools: [StandaloneCommandLineTool]
    /// True while Purge stops background jobs and checks nothing is in use.
    var isChecking = false
    /// Why Purge would not remove them, shown in the sheet. Nil until a refusal.
    var refusal: String?

    var totalBytes: Int64 { tools.reduce(Int64(0)) { $0 + $1.sizeBytes } }
    var pathCount: Int { tools.reduce(0) { $0 + $1.install.removalPaths.count } }
    var launchAgents: [LaunchAgentJob] { tools.flatMap(\.install.launchAgents) }
}

/// A package-manager tool the user asked to uninstall, and where that stands.
/// The manager does the removal; the sheet shows its command first.
nonisolated struct PackageManagerHandoff: Identifiable, Equatable, Sendable {
    nonisolated enum State: Equatable, Sendable {
        case ready
        case running
        case failed(String)
    }

    let id = UUID()
    let tool: PackageManagerTool
    var state: State = .ready
}
