import Foundation

/// Lists the tools package managers installed (#225), from their folders on
/// disk. No manager runs to list anything: Homebrew's receipts, npm's global
/// `node_modules`, the pipx and uv tool folders, and Cargo's install record
/// already say what is there.
///
/// Each tool comes with the manager's own uninstall command, built from an
/// absolute program path and a fixed environment, because the app does not
/// inherit the user's shell `PATH`. Only Homebrew formulae installed on
/// request are listed: dependencies are Homebrew's call, and casks are apps
/// that Installed apps already lists.
nonisolated enum PackageManagerToolScanner {
    nonisolated struct Roots: Sendable {
        var home: URL
        var homebrewPrefixes: [URL]

        static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Roots {
            Roots(home: home, homebrewPrefixes: [
                URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
                URL(fileURLWithPath: "/usr/local", isDirectory: true)
            ])
        }
    }

    /// Bundled with Node itself; removing either breaks every other package.
    static let npmBundledPackages: Set<String> = ["npm", "corepack"]

    /// Every tool found, without sizes, sorted by manager then name.
    static func tools(roots: Roots) -> [PackageManagerTool] {
        homebrewFormulae(roots: roots)
            + npmGlobals(roots: roots)
            + pipxVenvs(roots: roots)
            + uvTools(roots: roots)
            + cargoInstalls(roots: roots)
    }

    // MARK: Homebrew

    static func homebrewFormulae(roots: Roots) -> [PackageManagerTool] {
        var tools: [PackageManagerTool] = []
        for prefix in roots.homebrewPrefixes {
            let cellar = prefix.appendingPathComponent("Cellar", isDirectory: true)
            let brew = prefix.appendingPathComponent("bin/brew")
            for name in directoryNames(in: cellar) {
                let folder = cellar.appendingPathComponent(name, isDirectory: true)
                guard PackageManager.homebrew.isValidPackageName(name),
                      isInstalledOnRequest(formula: folder) else { continue }
                tools.append(tool(
                    .homebrew, name: name, locations: [folder], context: nil,
                    executable: executableIfPresent(brew),
                    environment: homebrewEnvironment(prefix: prefix, home: roots.home)
                ))
            }
        }
        return tools
    }

    /// What `brew` runs with: its own `bin` first on `PATH`, no auto-update, no
    /// hints, no cleanup pass, and no prompts. Shared with the cask uninstall
    /// (`HomebrewCaskCatalog`, #254).
    static func homebrewEnvironment(prefix: URL, home: URL) -> [String: String] {
        environment(roots: Roots(home: home, homebrewPrefixes: [prefix]), path: [prefix.appendingPathComponent("bin").path], extra: [
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            "NONINTERACTIVE": "1"
        ])
    }

    /// Whether any installed version's receipt says the user asked for it.
    static func isInstalledOnRequest(formula folder: URL) -> Bool {
        for version in directoryNames(in: folder) {
            let receipt = folder.appendingPathComponent(version).appendingPathComponent("INSTALL_RECEIPT.json")
            guard let data = try? Data(contentsOf: receipt),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if json["installed_on_request"] as? Bool == true { return true }
        }
        return false
    }

    // MARK: npm

    /// A Node install whose `lib/node_modules` holds global packages.
    nonisolated struct NodePrefix: Equatable, Sendable {
        let prefix: URL
        let context: String?
    }

    static func nodePrefixes(roots: Roots) -> [NodePrefix] {
        var prefixes = roots.homebrewPrefixes.map { NodePrefix(prefix: $0, context: nil) }
        let nvm = roots.home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        for version in directoryNames(in: nvm).sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            let shown = version.hasPrefix("v") ? String(version.dropFirst()) : version
            prefixes.append(NodePrefix(
                prefix: nvm.appendingPathComponent(version, isDirectory: true),
                context: String(localized: "Node \(shown)")
            ))
        }
        if let custom = npmrcPrefix(home: roots.home),
           !prefixes.contains(where: { $0.prefix.standardizedFileURL.path == custom.standardizedFileURL.path }) {
            prefixes.append(NodePrefix(prefix: custom, context: nil))
        }
        return prefixes
    }

    /// The `prefix=` line in `~/.npmrc`, when it names an absolute or `~` path.
    static func npmrcPrefix(home: URL) -> URL? {
        guard let text = try? String(contentsOf: home.appendingPathComponent(".npmrc"), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "prefix" else { continue }
            if parts[1].hasPrefix("/") { return URL(fileURLWithPath: parts[1], isDirectory: true) }
            if parts[1].hasPrefix("~/") { return home.appendingPathComponent(String(parts[1].dropFirst(2)), isDirectory: true) }
        }
        return nil
    }

    static func npmGlobals(roots: Roots) -> [PackageManagerTool] {
        let prefixes = nodePrefixes(roots: roots)
        // A prefix with no npm of its own (a custom ~/.npmrc one) uses the
        // first Node that has both node and npm.
        let fallback = prefixes.first { hasNodeAndNpm($0.prefix) }
        var tools: [PackageManagerTool] = []
        for node in prefixes {
            let modules = node.prefix.appendingPathComponent("lib/node_modules", isDirectory: true)
            let runner = hasNodeAndNpm(node.prefix) ? node.prefix : fallback?.prefix
            for name in npmPackageNames(in: modules) {
                tools.append(tool(
                    .npm, name: name,
                    locations: [modules.appendingPathComponent(name, isDirectory: true)],
                    context: node.context,
                    executable: runner.map { $0.appendingPathComponent("bin/npm") },
                    environment: environment(
                        roots: roots,
                        path: runner.map { [$0.appendingPathComponent("bin").path] } ?? [],
                        extra: ["npm_config_prefix": node.prefix.path, "npm_config_update_notifier": "false"]
                    )
                ))
            }
        }
        return tools
    }

    /// Package folders in a global `node_modules`, scoped ones as `@scope/name`.
    /// Links made by `npm link` point at the user's own projects and are left out.
    static func npmPackageNames(in modules: URL) -> [String] {
        var names: [String] = []
        for entry in directoryNames(in: modules) {
            if entry.hasPrefix("@") {
                let scope = modules.appendingPathComponent(entry, isDirectory: true)
                names += directoryNames(in: scope).map { "\(entry)/\($0)" }
            } else if !npmBundledPackages.contains(entry) {
                names.append(entry)
            }
        }
        return names.filter { PackageManager.npm.isValidPackageName($0) }
    }

    private static func hasNodeAndNpm(_ prefix: URL) -> Bool {
        executableIfPresent(prefix.appendingPathComponent("bin/node")) != nil
            && executableIfPresent(prefix.appendingPathComponent("bin/npm")) != nil
    }

    // MARK: pipx, uv, Cargo

    static func pipxVenvs(roots: Roots) -> [PackageManagerTool] {
        let home = roots.home
        let pipxHomes = [
            home.appendingPathComponent(".local/pipx", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/pipx", isDirectory: true)
        ]
        let pipx = firstExecutable([home.appendingPathComponent(".local/bin/pipx")]
            + roots.homebrewPrefixes.map { $0.appendingPathComponent("bin/pipx") })
        return pipxHomes.flatMap { pipxHome in
            let venvs = pipxHome.appendingPathComponent("venvs", isDirectory: true)
            return directoryNames(in: venvs)
                .filter { PackageManager.pipx.isValidPackageName($0) }
                .map { name in
                    tool(.pipx, name: name, locations: [venvs.appendingPathComponent(name, isDirectory: true)],
                         context: nil, executable: pipx,
                         environment: environment(roots: roots, path: pipx.map { [$0.deletingLastPathComponent().path] } ?? [],
                                                  extra: ["PIPX_HOME": pipxHome.path]))
                }
        }
    }

    static func uvTools(roots: Roots) -> [PackageManagerTool] {
        let home = roots.home
        let toolsRoot = home.appendingPathComponent(".local/share/uv/tools", isDirectory: true)
        let uv = firstExecutable([
            home.appendingPathComponent(".local/bin/uv"),
            home.appendingPathComponent(".cargo/bin/uv")
        ] + roots.homebrewPrefixes.map { $0.appendingPathComponent("bin/uv") })
        return directoryNames(in: toolsRoot)
            .filter { PackageManager.uv.isValidPackageName($0) }
            .map { name in
                tool(.uv, name: name, locations: [toolsRoot.appendingPathComponent(name, isDirectory: true)],
                     context: nil, executable: uv,
                     environment: environment(roots: roots, path: uv.map { [$0.deletingLastPathComponent().path] } ?? [],
                                              extra: ["UV_TOOL_DIR": toolsRoot.path, "UV_NO_PROGRESS": "1"]))
            }
    }

    /// Cargo records each `cargo install` in `~/.cargo/.crates2.json`, keyed
    /// `name version (source)`, with the programs it put in `~/.cargo/bin`.
    static func cargoInstalls(roots: Roots) -> [PackageManagerTool] {
        let cargoHome = roots.home.appendingPathComponent(".cargo", isDirectory: true)
        let bin = cargoHome.appendingPathComponent("bin", isDirectory: true)
        guard let data = try? Data(contentsOf: cargoHome.appendingPathComponent(".crates2.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installs = json["installs"] as? [String: Any] else { return [] }
        let cargo = executableIfPresent(bin.appendingPathComponent("cargo"))
        return installs.keys.sorted().compactMap { key in
            guard let name = key.split(separator: " ").first.map(String.init),
                  PackageManager.cargo.isValidPackageName(name),
                  let entry = installs[key] as? [String: Any],
                  let bins = entry["bins"] as? [String] else { return nil }
            let locations = bins
                .filter { !$0.isEmpty && !$0.contains("/") }
                .map { bin.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !locations.isEmpty else { return nil }
            return tool(.cargo, name: name, locations: locations, context: nil, executable: cargo,
                        environment: environment(roots: roots, path: [bin.path], extra: ["CARGO_HOME": cargoHome.path]))
        }
    }

    // MARK: Helpers

    private static func tool(
        _ manager: PackageManager,
        name: String,
        locations: [URL],
        context: String?,
        executable: URL?,
        environment: [String: String]
    ) -> PackageManagerTool {
        PackageManagerTool(
            manager: manager,
            name: name,
            locations: locations.map(\.standardizedFileURL),
            context: context,
            executable: executable,
            arguments: Array(manager.commandPrefix.dropFirst()) + [name],
            environment: environment
        )
    }

    /// A fixed environment: the manager's own folder first on `PATH`, the
    /// user's home and name, and the manager's settings. Nothing else from
    /// the app's environment reaches the command.
    static func environment(roots: Roots, path: [String], extra: [String: String]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var result: [String: String] = [
            "HOME": roots.home.path,
            "PATH": (path + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"),
            "LANG": "en_US.UTF-8"
        ]
        for key in ["USER", "LOGNAME", "TMPDIR"] {
            if let value = inherited[key] { result[key] = value }
        }
        result.merge(extra) { _, new in new }
        return result
    }

    /// Visible folder names, not following links, sorted.
    static func directoryNames(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { name in
                guard !name.hasPrefix(".") else { return false }
                let path = folder.appendingPathComponent(name).path
                return (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
                    == .typeDirectory
            }
            .sorted()
    }

    private static func executableIfPresent(_ url: URL) -> URL? {
        FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static func firstExecutable(_ candidates: [URL]) -> URL? {
        candidates.lazy.compactMap(executableIfPresent).first
    }
}
