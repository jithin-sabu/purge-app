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

/// The command-line tools the user ticked, both kinds, from review to done.
/// Drives one sheet: script installs move to the Trash after the in-use check,
/// then each package manager removes its own tools, one at a time.
nonisolated struct CommandLineToolRemovalPlan: Identifiable, Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        case review
        /// Stopping background jobs and checking nothing is in use.
        case checking
        case working
        case finished
    }

    /// Where one tool stands once the removal runs.
    nonisolated enum ItemState: Equatable, Sendable {
        case waiting
        case running
        case movedToTrash
        case removedByManager
        case failed(String)
        /// Purge found no program for the manager; nothing ran.
        case managerMissing
    }

    let id = UUID()
    let tools: [StandaloneCommandLineTool]
    let managed: [PackageManagerTool]
    var phase = Phase.review
    /// Why Purge would not start, shown in the sheet. Nothing ran.
    var refusal: String?
    /// Keyed by tool id.
    var states: [String: ItemState] = [:]

    var totalBytes: Int64 {
        tools.reduce(Int64(0)) { $0 + $1.sizeBytes } + managed.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }
    var itemCount: Int { tools.count + managed.count }
    var launchAgents: [LaunchAgentJob] { tools.flatMap(\.install.launchAgents) }

    func state(of id: String) -> ItemState { states[id] ?? .waiting }

    var failedCount: Int {
        states.values.filter { state in
            switch state {
            case .failed, .managerMissing: return true
            case .waiting, .running, .movedToTrash, .removedByManager: return false
            }
        }.count
    }
}
