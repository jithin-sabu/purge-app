import Foundation

/// A background job in `~/Library/LaunchAgents` that starts a program from a
/// command-line tool's folder.
nonisolated struct LaunchAgentJob: Equatable, Sendable {
    let label: String
    let plist: URL
}

/// One standalone command-line tool install (#225): the folder it lives in,
/// the shims in `~/.local/bin` that point into it, and the background jobs
/// that start a program from it. Removing it moves exactly `removalPaths` to
/// the Trash; `kept` is shown and never touched.
nonisolated struct CommandLineToolInstall: Equatable, Sendable, Identifiable {
    nonisolated enum Source: Equatable, Sendable {
        /// A shim in `~/.local/bin` points into a top-level `~/.<tool>` folder.
        case shim
        /// `command-line-tools.json` names the folder.
        case catalog
    }

    let name: String
    let folder: URL
    let shims: [URL]
    let launchAgents: [LaunchAgentJob]
    let kept: [URL]
    let source: Source

    var id: String { folder.standardizedFileURL.path }

    /// The folder first, then its shims and job plists.
    var removalPaths: [URL] { [folder] + shims + launchAgents.map(\.plist) }
}

/// Finds standalone command-line tool installs, the `curl | sh` kind, and is
/// the delete gate for them (#225).
///
/// The shape is checkable: a shim in `~/.local/bin` whose target, or whose
/// short launcher script, points into one `~/.<tool>` folder, as
/// `~/.local/bin/hermes` points into `~/.hermes`. That pair is the install.
/// A shim that points anywhere else, into two folders, or into a folder that
/// is shared, a version manager's, or an app's, pairs with nothing. Tools
/// whose layout the rule cannot see come from `CommandLineToolCatalog`.
///
/// Nothing here reaches `DeletionSafetyPolicy.evaluate`. The gate re-derives
/// the pairs from disk and accepts only an install's folder, its shims and its
/// job plists, never a path inside or above them.
nonisolated enum CommandLineToolScanPolicy {
    /// Home-relative folder the shims live in.
    static let shimFolder = ".local/bin"

    /// Home-relative folders that are never an install folder: shared folders,
    /// version managers and language toolchains, settings other tools read, and
    /// folders apps keep. A shim pointing into one pairs with nothing, and the
    /// catalog may not name one. An app's dot folder can hold its own command
    /// line tool beside downloaded models or VM disks, as `~/.lmstudio` does.
    static let sharedFolders: Set<String> = [
        // Shared by many tools, or the user's own settings and keys.
        ".local", ".local/share", ".local/bin", ".local/state", ".local/lib",
        ".config", ".cache", ".Trash", ".ssh", ".gnupg", ".git", ".aws", ".azure", ".kube",
        // Version managers, language toolchains and package caches.
        ".nvm", ".rbenv", ".pyenv", ".rustup", ".cargo", ".volta", ".mise", ".asdf",
        ".sdkman", ".nodenv", ".goenv", ".jenv", ".bun", ".deno", ".npm", ".npm-global",
        ".yarn", ".pnpm-store", ".gem", ".bundle", ".pub-cache", ".gradle", ".m2", ".ivy2",
        ".sbt", ".ghcup", ".cabal", ".stack", ".opam", ".elan", ".julia", ".juliaup",
        ".dotnet", ".conda", ".nimble", ".wasmtime", ".wasmer",
        // Folders apps keep, some with a command-line tool inside.
        ".gemini", ".cursor", ".cursor-server", ".vscode", ".vscode-server", ".vscode-insiders",
        ".claude", ".codeium", ".windsurf", ".kiro", ".docker", ".orbstack", ".rd", ".colima",
        ".lmstudio", ".ollama", ".android"
    ]

    /// Folders a launcher script may name besides the tool's own: the system
    /// interpreters it runs with.
    static let systemPathPrefixes = ["/bin/", "/usr/bin/", "/sbin/", "/usr/sbin/", "/dev/null"]

    static let maxLinkHops = 8
    static let maxScriptBytes = 4096

    /// What a shim leads to.
    nonisolated struct ShimLead: Equatable, Sendable {
        /// Each target along a symlink chain, or every absolute path a launcher
        /// script names, settings included. Standardized.
        let paths: [String]
        let isScript: Bool
        /// The file that runs: a link's final target, or the program a script
        /// starts. Nil when there is none, or when it is not on disk. A shim
        /// pairs only through this, so a link into a dotfiles repo or a script
        /// that only sets a variable to a folder never offers that folder.
        let program: String?
    }

    // MARK: Scan

    /// Every standalone install in `home`, sorted by name.
    static func pairedInstalls(
        home: URL,
        catalog: CommandLineToolCatalog = .shared,
        appCatalog: AppDotFolderCatalog = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [CommandLineToolInstall] {
        let homePath = home.standardizedFileURL.path
        let leads = shimLeads(home: home)
        let denied = deniedTopLevelNames(appCatalog: appCatalog)
        // The names as stored on disk. The volume ignores case, so `~/.SSH`
        // reaches `~/.ssh`; only a name spelled exactly as listed may pair.
        let homeNames = Set((try? FileManager.default.contentsOfDirectory(atPath: homePath)) ?? [])

        var folders: [String: (name: String, source: CommandLineToolInstall.Source, shims: [URL], kept: [URL])] = [:]

        for entry in catalog.entries {
            guard let folder = catalog.url(for: entry.folder, home: home),
                  isRealFolder(folder, home: home),
                  !holdsRepository(folder) else { continue }
            let folderPath = folder.standardizedFileURL.path
            let listed = Set(entry.shims.compactMap { catalog.url(for: $0, home: home)?.standardizedFileURL.path })
            let shims = leads
                .filter { listed.contains($0.shim.path) && leadsOnlyInto($0.lead, folder: folderPath) }
                .map(\.shim)
            let kept = entry.kept
                .compactMap { catalog.url(for: $0, home: home) }
                .filter { exists($0) }
            folders[folderPath] = (entry.name, .catalog, shims, kept)
        }

        for (shim, lead) in leads {
            guard let name = pairedTopLevelName(lead, shimName: shim.lastPathComponent,
                                                homePath: homePath, denied: denied),
                  homeNames.contains(name) else { continue }
            let folder = home.appendingPathComponent(name, isDirectory: true)
            let folderPath = folder.standardizedFileURL.path
            if var existing = folders[folderPath] {
                if !existing.shims.contains(shim) { existing.shims.append(shim) }
                folders[folderPath] = existing
                continue
            }
            guard isRealFolder(folder, home: home), !holdsRepository(folder) else { continue }
            folders[folderPath] = (String(name.dropFirst()), .shim, [shim], [])
        }

        // A folder that holds a model store is an app's, whatever points into it.
        let modelStores = AIModelScanPolicy.allRoots(home: home, environment: environment)
            .map { $0.standardizedFileURL.path.lowercased() }
        return folders
            .filter { path, _ in
                let lower = path.lowercased()
                return !modelStores.contains { $0 == lower || $0.hasPrefix(lower + "/") }
            }
            .map { path, value in
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                return CommandLineToolInstall(
                    name: value.name,
                    folder: folder,
                    shims: value.shims.sorted { $0.path < $1.path },
                    launchAgents: launchAgents(startingFrom: folder, home: home),
                    kept: value.kept,
                    source: value.source
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether the folder is a git checkout, such as a dotfiles repo. It can
    /// hold work that exists nowhere else, so it is never a tool install.
    static func holdsRepository(_ folder: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(".git").path)) != nil
    }

    /// Each shim directly inside `~/.local/bin` and what it leads to. Empty when
    /// that folder is missing or reached through a link.
    static func shimLeads(home: URL) -> [(shim: URL, lead: ShimLead)] {
        let bin = home.appendingPathComponent(shimFolder, isDirectory: true)
        guard isRealFolder(bin, home: home) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .compactMap { name in
                // Built from the folder path, not the listing's URL, so the
                // spelling matches what the gate compares against.
                let shim = URL(fileURLWithPath: bin.path).appendingPathComponent(name).standardizedFileURL
                return shimLead(at: shim, home: home).map { (shim, $0) }
            }
    }

    /// Where one shim leads: the targets of its symlink chain, or the paths
    /// its launcher script names. Nil for anything else, such as a compiled
    /// binary, and for a link whose target is gone.
    static func shimLead(at shim: URL, home: URL) -> ShimLead? {
        let fm = FileManager.default
        var current = shim.standardizedFileURL.path
        var hops: [String] = []
        for _ in 0..<maxLinkHops {
            guard let type = (try? fm.attributesOfItem(atPath: current))?[.type] as? FileAttributeType else {
                return nil
            }
            if type == .typeSymbolicLink {
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: current) else { return nil }
                let next = destination.hasPrefix("/")
                    ? destination
                    : (current as NSString).deletingLastPathComponent + "/" + destination
                current = URL(fileURLWithPath: next).standardizedFileURL.path
                hops.append(current)
                continue
            }
            guard type == .typeRegular else { return nil }
            if hops.isEmpty {
                return scriptLead(at: current, home: home)
            }
            return ShimLead(paths: hops, isScript: false, program: isExecutableFile(current) ? current : nil)
        }
        return nil
    }

    /// The absolute paths a short launcher script names after its `#!` line,
    /// with `$HOME`, `${HOME}` and `~` expanded, and the program it runs: the
    /// first path that is not a value given to a variable or an option. After
    /// a system interpreter, the script it hands to counts. Nil when the file
    /// is not a small UTF-8 script.
    static func scriptLead(at path: String, home: URL) -> ShimLead? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxScriptBytes + 1),
              data.count <= maxScriptBytes,
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#!") else { return nil }
        let homePath = home.standardizedFileURL.path
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`;():|&<>"))

        func expanded(_ token: Substring) -> String? {
            let raw: String
            if token.hasPrefix("$HOME/") {
                raw = homePath + token.dropFirst("$HOME".count)
            } else if token.hasPrefix("${HOME}/") {
                raw = homePath + token.dropFirst("${HOME}".count)
            } else if token.hasPrefix("~/") {
                raw = homePath + token.dropFirst(1)
            } else if token.hasPrefix("/") {
                raw = String(token)
            } else {
                return nil
            }
            return URL(fileURLWithPath: raw).standardizedFileURL.path
        }

        var paths: [String] = []
        var program: String?
        var afterInterpreter = false
        // A quoted value (`NAME="$HOME/.x"`) splits from its `NAME=`.
        var nextIsValue = false
        for token in body.components(separatedBy: separators) where !token.isEmpty {
            // `NAME=value` and `--option=value` name data, never the program.
            if let equals = token.firstIndex(of: "=") {
                let value = token[token.index(after: equals)...]
                nextIsValue = value.isEmpty
                if let path = expanded(value) { paths.append(path) }
                continue
            }
            if nextIsValue {
                nextIsValue = false
                if let path = expanded(token[...]) { paths.append(path) }
                continue
            }
            guard let path = expanded(token[...]) else { continue }
            paths.append(path)
            guard program == nil else { continue }
            if isSystemPath(path) {
                afterInterpreter = true
                continue
            }
            let runnable = afterInterpreter ? isRegularFile(path) : isExecutableFile(path)
            if runnable { program = path }
        }
        return ShimLead(paths: paths, isScript: true, program: program)
    }

    /// The one top-level `~/.<tool>` folder a shim leads into, or nil.
    ///
    /// It takes positive evidence: the program the shim runs is on disk inside
    /// that folder, the shim is named after the folder (`hermes` and
    /// `hermes-acp` for `~/.hermes`), and every path the shim names sits in that
    /// same folder (a script may also name the system interpreters). A folder
    /// that is shared or an app's never pairs, compared without case, and
    /// neither does a target inside an app bundle.
    static func pairedTopLevelName(
        _ lead: ShimLead,
        shimName: String,
        homePath: String,
        denied: Set<String>
    ) -> String? {
        guard let program = lead.program else { return nil }
        var names = Set<String>()
        for path in lead.paths + [program] {
            if lead.isScript, isSystemPath(path) { continue }
            guard path.hasPrefix(homePath + "/."), !path.contains(".app/"), !path.hasSuffix(".app") else { return nil }
            guard let first = path.dropFirst(homePath.count + 1).split(separator: "/").first else { return nil }
            names.insert(String(first))
        }
        guard names.count == 1, let name = names.first, name.count > 1,
              !denied.contains(name.lowercased()),
              program.hasPrefix(homePath + "/" + name + "/") else { return nil }
        let tool = String(name.dropFirst()).lowercased()
        let shim = shimName.lowercased()
        guard shim == tool || shim.hasPrefix(tool + "-") else { return nil }
        return name
    }

    /// Whether the program a shim runs, and every path it names, sit inside
    /// `folder`. A script may also name the system interpreters.
    static func leadsOnlyInto(_ lead: ShimLead, folder: String) -> Bool {
        guard let program = lead.program, program.hasPrefix(folder + "/") else { return false }
        for path in lead.paths {
            if lead.isScript, isSystemPath(path) { continue }
            guard path == folder || path.hasPrefix(folder + "/"), !path.contains(".app/") else { return false }
        }
        return !program.contains(".app/")
    }

    private static func isSystemPath(_ path: String) -> Bool {
        systemPathPrefixes.contains { path.hasPrefix($0) || path + "/" == $0 }
    }

    private static func isRegularFile(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        isRegularFile(path) && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Top-level names that never pair: the shared list, and the first part of
    /// every folder the app catalog names, so `~/.gemini` and `~/.antigravity`
    /// are never a tool's.
    static func deniedTopLevelNames(appCatalog: AppDotFolderCatalog) -> Set<String> {
        var names = Set(sharedFolders.compactMap { $0.split(separator: "/").first.map { $0.lowercased() } })
        for folder in appCatalog.entries.flatMap(\.folders) {
            if let first = folder.dropFirst(2).split(separator: "/").first { names.insert(first.lowercased()) }
        }
        return names
    }

    /// Jobs in `~/Library/LaunchAgents` that start a program from `folder`:
    /// `Program`, or the first of `ProgramArguments`, or the script a system
    /// interpreter there is handed. A job that only names the folder as data,
    /// such as a backup of `~/.hermes/sessions`, is not the tool's.
    static func launchAgents(startingFrom folder: URL, home: URL) -> [LaunchAgentJob] {
        let root = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let folderPath = folder.standardizedFileURL.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".plist") }
            .sorted()
            .compactMap { name in
                let plist = URL(fileURLWithPath: root.path).appendingPathComponent(name).standardizedFileURL
                guard (try? FileManager.default.attributesOfItem(atPath: plist.path))?[.type] as? FileAttributeType
                        == .typeRegular,
                      let contents = NSDictionary(contentsOf: plist) as? [String: Any],
                      let label = contents["Label"] as? String, !label.isEmpty else { return nil }
                guard let program = startedProgram(contents) else { return nil }
                let starts = program.hasPrefix("/")
                    && URL(fileURLWithPath: program).standardizedFileURL.path.hasPrefix(folderPath + "/")
                return starts ? LaunchAgentJob(label: label, plist: plist) : nil
            }
    }

    /// The program a job plist starts. When that is a system interpreter, the
    /// script it runs instead; an option such as `-c` names no file.
    static func startedProgram(_ plist: [String: Any]) -> String? {
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let first = (plist["Program"] as? String) ?? arguments.first
        guard let first else { return nil }
        guard isSystemPath(first) else { return first }
        // With `Program` set, `ProgramArguments[0]` is only argv[0] either way.
        guard let script = arguments.dropFirst().first, !script.hasPrefix("-") else { return nil }
        return script
    }

    // MARK: Settings

    /// Top-level files in the install folder that look like settings or keys,
    /// by name. Shown in the confirm so nobody loses an `.env` by surprise;
    /// they go with the folder.
    static func settingsFiles(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { name in
                let path = folder.appendingPathComponent(name).path
                guard (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
                        == .typeRegular else { return false }
                return looksLikeSettings(name)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func looksLikeSettings(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix(".env") || lower.hasPrefix("credentials") { return true }
        if lower.hasPrefix("auth"), lower.hasSuffix(".json") { return true }
        if lower.hasPrefix("config.") || lower.hasPrefix("settings.") { return true }
        if [".toml", ".yaml", ".yml"].contains(where: { lower.hasSuffix($0) }) { return true }
        if lower.hasSuffix(".md") {
            return !["readme", "changelog", "license"].contains { lower.hasPrefix($0) }
        }
        return false
    }

    // MARK: Gate

    /// Every path a removal may move to the Trash, re-derived from disk.
    static func eligiblePaths(
        home: URL,
        catalog: CommandLineToolCatalog = .shared,
        appCatalog: AppDotFolderCatalog = .shared
    ) -> Set<String> {
        Set(pairedInstalls(home: home, catalog: catalog, appCatalog: appCatalog)
            .flatMap { $0.removalPaths.map(\.standardizedFileURL.path) })
    }

    /// Whether Purge may trash this path as part of a command-line tool. Only
    /// an install's folder, one of its shims, or one of its job plists.
    static func isEligibleForDeletion(
        _ url: URL,
        home: URL,
        catalog: CommandLineToolCatalog = .shared,
        appCatalog: AppDotFolderCatalog = .shared
    ) -> Bool {
        eligiblePaths(home: home, catalog: catalog, appCatalog: appCatalog)
            .contains(url.standardizedFileURL.path)
    }

    // MARK: Helpers

    /// A real folder, not a link, reached from `home` through no link.
    static func isRealFolder(_ url: URL, home: URL) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path))?[.type]
                as? FileAttributeType == .typeDirectory else { return false }
        return AppUninstallScanPolicy.staysInsideHomeWithoutLinks(url, home: home)
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path)) != nil
    }
}
