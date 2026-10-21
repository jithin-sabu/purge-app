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
    /// version managers and toolchains, settings other tools read, and folders
    /// apps keep. A shim pointing into one pairs with nothing, and the catalog
    /// may not name one.
    static let sharedFolders: Set<String> = [
        ".local", ".local/share", ".local/bin", ".local/state", ".local/lib",
        ".config", ".cache", ".Trash", ".ssh", ".gnupg", ".git",
        ".gemini", ".cursor", ".vscode", ".claude", ".docker", ".orbstack",
        ".nvm", ".rbenv", ".pyenv", ".rustup", ".cargo", ".volta", ".mise", ".asdf",
        ".sdkman", ".nodenv", ".goenv", ".jenv", ".bun", ".deno", ".npm",
        ".gradle", ".m2"
    ]

    /// Folders a launcher script may name besides the tool's own: the system
    /// interpreters it runs with.
    static let systemPathPrefixes = ["/bin/", "/usr/bin/", "/sbin/", "/usr/sbin/", "/dev/null"]

    static let maxLinkHops = 8
    static let maxScriptBytes = 4096

    /// What a shim leads to.
    nonisolated struct ShimLead: Equatable, Sendable {
        /// Each target along a symlink chain, or every absolute path a launcher
        /// script names. Standardized.
        let paths: [String]
        let isScript: Bool
    }

    // MARK: Scan

    /// Every standalone install in `home`, sorted by name.
    static func pairedInstalls(
        home: URL,
        catalog: CommandLineToolCatalog = .shared,
        appCatalog: AppDotFolderCatalog = .shared
    ) -> [CommandLineToolInstall] {
        let homePath = home.standardizedFileURL.path
        let leads = shimLeads(home: home)
        let denied = deniedTopLevelNames(appCatalog: appCatalog)

        var folders: [String: (name: String, source: CommandLineToolInstall.Source, shims: [URL], kept: [URL])] = [:]

        for entry in catalog.entries {
            guard let folder = catalog.url(for: entry.folder, home: home),
                  isRealFolder(folder, home: home) else { continue }
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
            guard let name = pairedTopLevelName(lead, homePath: homePath, denied: denied) else { continue }
            let folder = home.appendingPathComponent(name, isDirectory: true)
            let folderPath = folder.standardizedFileURL.path
            if var existing = folders[folderPath] {
                if !existing.shims.contains(shim) { existing.shims.append(shim) }
                folders[folderPath] = existing
                continue
            }
            guard isRealFolder(folder, home: home) else { continue }
            folders[folderPath] = (String(name.dropFirst()), .shim, [shim], [])
        }

        return folders
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

    /// Where one shim leads: the targets of its symlink chain, or the absolute
    /// paths its launcher script names. Nil for anything else, such as a
    /// compiled binary.
    static func shimLead(at shim: URL, home: URL) -> ShimLead? {
        let fm = FileManager.default
        var current = shim.standardizedFileURL.path
        var hops: [String] = []
        for _ in 0..<maxLinkHops {
            guard let type = (try? fm.attributesOfItem(atPath: current))?[.type] as? FileAttributeType else {
                // A link to something gone still names where it pointed.
                return hops.isEmpty ? nil : ShimLead(paths: hops, isScript: false)
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
            if hops.isEmpty {
                guard type == .typeRegular else { return nil }
                return scriptPaths(at: current, home: home).map { ShimLead(paths: $0, isScript: true) }
            }
            return ShimLead(paths: hops, isScript: false)
        }
        return nil
    }

    /// Every absolute path a short launcher script names after its `#!` line,
    /// with `$HOME`, `${HOME}` and `~` expanded. Nil when the file is not a
    /// small UTF-8 script.
    static func scriptPaths(at path: String, home: URL) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxScriptBytes + 1),
              data.count <= maxScriptBytes,
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#!") else { return nil }
        let homePath = home.standardizedFileURL.path
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`;=():|&<>"))
        var paths: [String] = []
        for token in body.components(separatedBy: separators) where !token.isEmpty {
            let path: String
            if token.hasPrefix("$HOME/") {
                path = homePath + token.dropFirst("$HOME".count)
            } else if token.hasPrefix("${HOME}/") {
                path = homePath + token.dropFirst("${HOME}".count)
            } else if token.hasPrefix("~/") {
                path = homePath + token.dropFirst(1)
            } else if token.hasPrefix("/") {
                path = token
            } else {
                continue
            }
            paths.append(URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        return paths
    }

    /// The one top-level `~/.<tool>` folder a shim leads into, or nil. Every
    /// path must sit in that same folder; a script may also name the system
    /// interpreters. A folder that is shared or an app's never pairs, and
    /// neither does a target inside an app bundle.
    static func pairedTopLevelName(_ lead: ShimLead, homePath: String, denied: Set<String>) -> String? {
        var names = Set<String>()
        for path in lead.paths {
            if lead.isScript, systemPathPrefixes.contains(where: { path.hasPrefix($0) || path + "/" == $0 }) { continue }
            guard path.hasPrefix(homePath + "/."), !path.contains(".app/"), !path.hasSuffix(".app") else { return nil }
            guard let first = path.dropFirst(homePath.count + 1).split(separator: "/").first else { return nil }
            names.insert(String(first))
        }
        guard names.count == 1, let name = names.first, name.count > 1, !denied.contains(name) else { return nil }
        return name
    }

    /// Whether every path a shim leads to sits inside `folder`. A script may
    /// also name the system interpreters.
    static func leadsOnlyInto(_ lead: ShimLead, folder: String) -> Bool {
        var sawFolder = false
        for path in lead.paths {
            if lead.isScript, systemPathPrefixes.contains(where: { path.hasPrefix($0) || path + "/" == $0 }) { continue }
            guard path == folder || path.hasPrefix(folder + "/"), !path.contains(".app/") else { return false }
            sawFolder = true
        }
        return sawFolder
    }

    /// Top-level names that never pair: the shared list, and the first part of
    /// every folder the app catalog names, so `~/.gemini` and `~/.antigravity`
    /// are never a tool's.
    static func deniedTopLevelNames(appCatalog: AppDotFolderCatalog) -> Set<String> {
        var names = Set(sharedFolders.compactMap { $0.split(separator: "/").first.map(String.init) })
        for folder in appCatalog.entries.flatMap(\.folders) {
            if let first = folder.dropFirst(2).split(separator: "/").first { names.insert(String(first)) }
        }
        return names
    }

    /// Jobs in `~/Library/LaunchAgents` whose program, or any argument naming
    /// a path, sits inside `folder`.
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
                var programs: [String] = []
                if let program = contents["Program"] as? String { programs.append(program) }
                if let arguments = contents["ProgramArguments"] as? [String] { programs.append(contentsOf: arguments) }
                let starts = programs.contains { argument in
                    argument.hasPrefix("/")
                        && URL(fileURLWithPath: argument).standardizedFileURL.path.hasPrefix(folderPath + "/")
                }
                return starts ? LaunchAgentJob(label: label, plist: plist) : nil
            }
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
