import Foundation

/// The Command-line tools scan (#225): standalone installs from
/// `CommandLineToolScanPolicy` and package-manager tools from
/// `PackageManagerToolScanner`, each sized in one `du` pass.
///
/// `nonisolated` and `@concurrent` keep the folder reads and the sizing off
/// the main actor, like the other scanners.
nonisolated struct CommandLineToolScanner: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var managerRoots: PackageManagerToolScanner.Roots = .live()

    @concurrent func scan() async -> CommandLineToolScanResult {
        // A model store moved with `launchctl setenv` is never a tool's folder (#318).
        LaunchdEnvironment.refresh()
        return Self.run(home: home, managerRoots: managerRoots)
    }

    static func run(home: URL, managerRoots: PackageManagerToolScanner.Roots) -> CommandLineToolScanResult {
        // The two kinds are found in different folders, so side by side.
        let (installs, found) = ConcurrentMap.both(
            { CommandLineToolScanPolicy.pairedInstalls(home: home) },
            { PackageManagerToolScanner.tools(roots: managerRoots) }
        )
        var managed = found
        let urls = installs.map(\.folder) + managed.flatMap(\.locations)
        let sizes = FolderSizing.directorySizes(at: urls, split: .spread)
        func size(_ url: URL) -> Int64 { sizes[url.standardizedFileURL.path] ?? 0 }

        let standalone = installs.map { install in
            StandaloneCommandLineTool(
                install: install,
                sizeBytes: size(install.folder),
                settingsFiles: CommandLineToolScanPolicy.settingsFiles(in: install.folder)
            )
        }
        for index in managed.indices {
            managed[index].sizeBytes = managed[index].locations.reduce(Int64(0)) { $0 + size($1) }
        }
        return CommandLineToolScanResult(
            standalone: standalone.sorted { $0.sizeBytes > $1.sizeBytes },
            managed: managed.sorted { $0.sizeBytes > $1.sizeBytes }
        )
    }
}
