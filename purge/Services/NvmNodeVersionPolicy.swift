import Darwin
import Foundation

/// Old Node.js versions nvm keeps in `~/.nvm/versions/node` (#400).
///
/// nvm keeps every version until you remove it by hand, and its own `uninstall`
/// only deletes the version's folder. A move to the Trash does the same and can be
/// undone. A version is offered only when nothing Purge can see still uses it:
///
/// - it is not the newest installed version of its major,
/// - no file in `~/.nvm/alias` resolves to it, nor `~/.nvm/current`,
/// - no `.nvmrc` resolves to it: `~/.nvmrc`, and the ones beside each project a
///   Dev Projects scan found or in a folder above it, which nvm also reads,
/// - it holds no global npm package or command besides the ones Node ships, and
///   no global npm config (`etc/npmrc`, which can hold a token), since nvm
///   keeps those inside the version,
/// - no LaunchAgent, MCP or Claude Code config, or shell startup file names a
///   path inside it, and no link in a `bin` folder on the `PATH` points into it,
/// - and, right before the move, no process has a file open inside it.
///
/// The checks run in three places, each as much as it can afford. The gate
/// `isOfferedForCleanup` runs on every Dev Tools list update, on the main
/// thread, so it reads only small files (`Check.quick`). The scan also reads
/// the configs and `bin` folders (`Check.scan`). `FileDeleter` runs every
/// check again right before the move, `lsof` included, off the main thread
/// (`passesImmediateTrashBoundary`).
///
/// Anything that can't be read or understood keeps every version. Only `~/.nvm`
/// counts: an app started from Finder never sees `NVM_DIR`.
nonisolated enum NvmNodeVersionPolicy {

    static let versionsRoot = ".nvm/versions/node"
    static let aliasRoot = ".nvm/alias"
    /// The link nvm keeps when `NVM_SYMLINK_CURRENT` is set.
    static let currentLink = ".nvm/current"

    /// One row per version, labelled `nvm Node.js <version>`.
    static let labelPrefix = "nvm Node.js "
    static let explanationKey = "nvm-node-version"

    /// What Node itself installs in `lib/node_modules` and `bin`. Anything else
    /// there is a global package the user installed into this version.
    static let bundledPackages: Set<String> = ["npm", "corepack"]
    static let bundledCommands: Set<String> = ["node", "npm", "npx", "corepack"]

    /// Files that may name a Node path directly, relative to home. An MCP server,
    /// a Claude Code hook or a `PATH` line set up this way breaks when its Node goes.
    static let referenceFiles = [
        "Library/Application Support/Claude/claude_desktop_config.json",
        ".claude.json",
        ".claude/settings.json",
        ".claude/settings.local.json",
        ".cursor/mcp.json",
        "Library/Application Support/Code/User/settings.json",
        "Library/Application Support/Code/User/mcp.json",
        "Library/Application Support/Cursor/User/settings.json",
        ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile",
        ".config/fish/config.fish",
    ]
    static let launchAgents = "Library/LaunchAgents"
    /// `bin` folders where people link one Node version so apps and build
    /// scripts find it, such as `/usr/local/bin/node`. Relative ones are in home.
    static let linkFolders = [".local/bin", "bin", "/usr/local/bin", "/opt/homebrew/bin"]
    /// Where a version keeps its global npm config, which `npm config set -g` writes.
    static let globalNpmConfig = "etc/npmrc"

    /// How long the main-thread gate may answer from an earlier read of what
    /// keeps a version. A move always reads again.
    static let recentReadLifetime: TimeInterval = 10

    // MARK: Labels and names

    /// The version in a row's label, or nil for any other label.
    static func version(inLabel label: String) -> String? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        let version = String(label.dropFirst(labelPrefix.count))
        return OldToolVersionScanPolicy.isDottedVersion(version) ? version : nil
    }

    /// `v22.14.0` → `22.14.0`. Nil for any other name.
    static func versionNumber(ofFolderName name: String) -> String? {
        guard name.hasPrefix("v") else { return nil }
        let number = String(name.dropFirst())
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, OldToolVersionScanPolicy.isDottedVersion(number) else { return nil }
        return number
    }

    static func major(of number: String) -> String {
        String(number.split(separator: ".").first ?? "")
    }

    // MARK: Context

    nonisolated struct Context: Sendable {
        /// The `.nvmrc` files Dev Projects scans found, or nil before any was recorded.
        var nvmrcFiles: @Sendable () -> [String]?
        /// Whether a file may be read without a macOS prompt. Tests allow everything.
        var mayRead: @Sendable (_ path: String) -> Bool
        /// The `lsof` listing, read only right before a move.
        var openFiles: OpenFileCheck.Lister
        /// The `bin` folders searched for links into a version. Tests use their own.
        var linkFolders: [String] = NvmNodeVersionPolicy.linkFolders

        /// `access` is worked out once here, not for each file: it probes Full
        /// Disk Access by opening folders.
        static func current(home: String, access: ScanAccess = ScanAccess.current()) -> Context {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            return Context(
                nvmrcFiles: { NvmrcLedger.shared.files() },
                mayRead: { path in
                    ProtectedLocations.isReadable(URL(fileURLWithPath: path), access: access, home: homeURL)
                },
                openFiles: OpenFileCheck.liveListing
            )
        }
    }

    // MARK: Gate

    nonisolated enum Check: Sendable {
        /// Shape, aliases, `.nvmrc` files and global packages: small reads only,
        /// safe on the main thread, where `isOfferedForCleanup` may run.
        case quick
        /// Also the LaunchAgents and MCP configs, which can be megabytes.
        case scan
        /// Also `lsof`, right before the move. Never on the main thread.
        case move
    }

    /// Whether the version folder at `path` is offered now, judged as far as `check` goes.
    static func isOffered(_ path: String, home: String, context: Context, check: Check) -> Bool {
        let url = URL(fileURLWithPath: path)
        let root = "\(home)/\(versionsRoot)"
        guard let name = OldToolVersionScanPolicy.onlyChild(path, of: root),
              versionNumber(ofFolderName: name) != nil,
              !PathContainment.containsSymlinkComponent(url, home: home),
              OldToolVersionScanPolicy.isRealFolder(path),
              let kept = check == .quick
                ? recentKeptVersions(home: home, context: context)
                : keptVersions(home: home, context: context),
              !kept.contains(name),
              !hasGlobalPackages(path),
              !hasGlobalNpmConfig(path) else { return false }
        switch check {
        case .quick:
            return true
        case .scan, .move:
            guard let named = isNamedByReferenceFile(path, home: home, context: context), !named,
                  let linked = isLinkedFromBinFolder(path, home: home, context: context), !linked else { return false }
        }
        switch check {
        case .quick, .scan:
            return true
        case .move:
            return OpenFileCheck.check(folders: [url], lister: context.openFiles) == .free
        }
    }

    /// `FileDeleter`'s last check before it moves an nvm version: every rule
    /// again, `lsof` included. True for every other path, which other rules judge.
    static func passesImmediateTrashBoundary(
        _ url: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        context: Context? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard OldToolVersionScanPolicy.kind(of: path, home: home) == .nvmNodeVersion else { return true }
        return isOffered(path, home: home, context: context ?? .current(home: home), check: .move)
    }

    private static let recentLock = NSLock()
    private nonisolated(unsafe) static var recent: [String: (at: Date, kept: Set<String>?)] = [:]

    /// `keptVersions`, from a read in the last `recentReadLifetime` seconds when
    /// there is one. Only the main-thread gate uses it: it runs for every nvm
    /// row on every Dev Tools list update.
    static func recentKeptVersions(home: String, context: Context, now: Date = Date()) -> Set<String>? {
        recentLock.lock()
        let cached = recent[home]
        recentLock.unlock()
        if let cached, now.timeIntervalSince(cached.at) < recentReadLifetime, now >= cached.at {
            return cached.kept
        }
        let kept = keptVersions(home: home, context: context)
        recentLock.lock()
        recent[home] = (now, kept)
        recentLock.unlock()
        return kept
    }

    /// The version folders nothing may remove now: the newest of each major, every
    /// alias, `~/.nvm/current`, and each recorded `.nvmrc`. Nil, which keeps every
    /// version, when any of them can't be read or understood.
    static func keptVersions(home: String, context: Context) -> Set<String>? {
        guard let installed = installedVersions(in: "\(home)/\(versionsRoot)") else { return nil }
        var kept = Set<String>()
        var newestOfMajor: [String: String] = [:]
        for name in installed {
            guard let number = versionNumber(ofFolderName: name) else { continue }
            let major = major(of: number)
            if let current = newestOfMajor[major], let currentNumber = versionNumber(ofFolderName: current),
               !OldToolVersionScanPolicy.isLower(currentNumber, than: number) {
                continue
            }
            newestOfMajor[major] = name
        }
        kept.formUnion(newestOfMajor.values)

        let aliases = "\(home)/\(aliasRoot)"
        guard let aliasFiles = aliasFiles(in: aliases) else { return nil }
        for file in aliasFiles {
            guard let text = readText(file) else { return nil }
            guard let resolved = resolve(text, installed: installed, aliasRoot: aliases) else { return nil }
            kept.formUnion(resolved)
        }

        let current = "\(home)/\(currentLink)"
        var info = stat()
        if lstat(current, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFLNK,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { return nil }
            let resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: "\(home)/.nvm", isDirectory: true))
                .standardizedFileURL.path
            if let name = resolved.split(separator: "/").last.map(String.init) { kept.insert(name) }
        } else if errno != ENOENT {
            return nil
        }

        guard let recorded = context.nvmrcFiles() else { return nil }
        // nvm falls back to `~/.nvmrc` when no folder above has one.
        let homeNvmrc = "\(home)/.nvmrc"
        for file in [homeNvmrc] + recorded.filter({ $0 != homeNvmrc }) {
            guard context.mayRead(file) else { return nil }
            var fileInfo = stat()
            if lstat(file, &fileInfo) != 0 {
                guard errno == ENOENT || errno == ENOTDIR else { return nil }
                // Gone pins nothing. Missing from a drive that may only be
                // unplugged keeps every version.
                guard file == homeNvmrc || isGone(file, home: home) == true else { return nil }
                continue
            }
            guard let text = readText(file),
                  let line = nvmrcVersionLine(text),
                  let resolved = resolve(line, installed: installed, aliasRoot: aliases) else { return nil }
            kept.formUnion(resolved)
        }
        return kept
    }

    /// The `v<version>` folders in `root`, links and hidden names left out. Empty
    /// when nvm has no Node versions. Nil when the folder can't be listed.
    static func installedVersions(in root: String) -> [String]? {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: root)
            return names.filter { versionNumber(ofFolderName: $0) != nil && OldToolVersionScanPolicy.isRealFolder("\(root)/\($0)") }
        } catch {
            return isMissing(root) ? [] : nil
        }
    }

    /// Every alias file, `lts/*` ones too. Hidden names such as `.DS_Store` are
    /// not aliases. Nil when a folder can't be listed or holds a link or anything
    /// deeper than `lts/`.
    static func aliasFiles(in root: String) -> [String]? {
        func list(_ folder: String, depth: Int) -> [String]? {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder)
            } catch {
                return depth == 0 && isMissing(folder) ? [] : nil
            }
            var files: [String] = []
            for name in names where !name.hasPrefix(".") {
                let entry = "\(folder)/\(name)"
                var info = stat()
                guard lstat(entry, &info) == 0 else { return nil }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    files.append(entry)
                case S_IFDIR:
                    guard depth == 0, let nested = list(entry, depth: 1) else { return nil }
                    files += nested
                default:
                    return nil
                }
            }
            return files
        }
        return list(root, depth: 0)
    }

    /// The first line of an `.nvmrc` that names something, comments left out. Nil
    /// for an empty file or the newer `key=value` form Purge doesn't read.
    static func nvmrcVersionLine(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return trimmed.contains("=") ? nil : trimmed
        }
        return nil
    }

    /// The installed version folders `text` names the way nvm resolves it: an
    /// exact version, a partial one (`20`, `v20.1`) as the newest that matches,
    /// `node` or `stable` as the newest of all, and another alias by its file. An
    /// exact version that isn't installed, or an `lts/` alias with no file, names
    /// nothing. Nil when Purge can't tell, which keeps every version.
    static func resolve(_ text: String, installed: [String], aliasRoot: String, depth: Int = 0) -> Set<String>? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, depth < 10 else { return nil }
        switch value {
        case "node", "stable":
            return newest(of: installed).map { [$0] } ?? []
        case "system", "iojs", "io.js", "unstable":
            return []
        default:
            break
        }
        let number = value.hasPrefix("v") ? String(value.dropFirst()) : value
        if !number.isEmpty, number.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }) {
            let parts = number.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            if parts.count == 3 {
                return installed.contains("v\(number)") ? ["v\(number)"] : []
            }
            let matching = installed.filter { name in
                guard let installedNumber = versionNumber(ofFolderName: name) else { return false }
                return installedNumber.hasPrefix(number + ".")
            }
            return newest(of: matching).map { [$0] } ?? []
        }
        // Another alias: a name nvm wrote into `alias`, such as `default` or `lts/jod`.
        guard !value.hasPrefix("/"), !value.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              value.allSatisfy({ !$0.isWhitespace }) else { return nil }
        let file = "\(aliasRoot)/\(value)"
        if OldToolVersionScanPolicy.isRegularFile(file) {
            guard let next = readText(file) else { return nil }
            return resolve(next, installed: installed, aliasRoot: aliasRoot, depth: depth + 1)
        }
        // nvm answers N/A for an LTS line with no alias file, so it names nothing.
        if value.hasPrefix("lts/"), isMissing(file) { return [] }
        return nil
    }

    static func newest(of names: [String]) -> String? {
        names.max { a, b in
            guard let left = versionNumber(ofFolderName: a), let right = versionNumber(ofFolderName: b) else { return false }
            return OldToolVersionScanPolicy.isLower(left, than: right)
        }
    }

    /// Whether the version holds a global package or a command Node didn't ship.
    /// True when either folder can't be read.
    static func hasGlobalPackages(_ versionPath: String) -> Bool {
        func extras(in folder: String, bundled: Set<String>) -> Bool {
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: folder)
                return names.contains { !$0.hasPrefix(".") && !bundled.contains($0) }
            } catch {
                return !isMissing(folder)
            }
        }
        return extras(in: "\(versionPath)/lib/node_modules", bundled: bundledPackages)
            || extras(in: "\(versionPath)/bin", bundled: bundledCommands)
    }

    /// Whether the version holds a global npm config: `etc/npmrc` that is not an
    /// empty regular file. It can hold a registry, a proxy or a token. True when
    /// it can't be checked.
    static func hasGlobalNpmConfig(_ versionPath: String) -> Bool {
        var info = stat()
        let file = "\(versionPath)/\(globalNpmConfig)"
        guard lstat(file, &info) == 0 else { return !isMissing(file) }
        return (info.st_mode & S_IFMT) != S_IFREG || info.st_size > 0
    }

    /// Whether a recorded `.nvmrc` that is missing is really gone. True in home
    /// when no folder on the way down is a link, on a mounted `/Volumes` drive,
    /// and anywhere else on the startup disk. Nil when it may sit on a drive
    /// that is only unplugged: under a `/Volumes` name that isn't mounted, or
    /// behind a link in home that may lead to one.
    static func isGone(_ path: String, home: String) -> Bool? {
        if PathContainment.isInside(path, home) {
            var current = home
            for part in path.dropFirst(home.count + 1).split(separator: "/").dropLast() {
                current += "/\(part)"
                var info = stat()
                guard lstat(current, &info) == 0 else {
                    return errno == ENOENT || errno == ENOTDIR ? true : nil
                }
                if (info.st_mode & S_IFMT) == S_IFLNK { return nil }
            }
            return true
        }
        let parts = path.split(separator: "/")
        if parts.first == "Volumes" {
            guard parts.count > 2 else { return nil }
            return OldToolVersionScanPolicy.isRealFolder("/Volumes/\(parts[1])") ? true : nil
        }
        return true
    }

    /// Whether a link in one of `linkFolders` points into the version. Nil when
    /// a folder is there but can't be listed.
    static func isLinkedFromBinFolder(_ versionPath: String, home: String, context: Context) -> Bool? {
        let spellings = OldToolVersionScanPolicy.comparableSpellings(of: versionPath)
        for relative in context.linkFolders {
            let folder = relative.hasPrefix("/") ? relative : "\(home)/\(relative)"
            guard context.mayRead(folder) else { return nil }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder)
            } catch {
                if isMissing(folder) { continue }
                return nil
            }
            for name in names {
                let entry = "\(folder)/\(name)"
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: entry) else { continue }
                let resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: folder, isDirectory: true))
                    .standardizedFileURL.path
                let targets = OldToolVersionScanPolicy.comparableSpellings(of: resolved)
                if targets.contains(where: { t in spellings.contains { PathContainment.isSameOrInside(t, $0) } }) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether a LaunchAgent or an MCP config names a path inside the version. Nil
    /// when one is there but can't be read.
    static func isNamedByReferenceFile(_ versionPath: String, home: String, context: Context) -> Bool? {
        let needles = ["\(versionsRoot)/\(URL(fileURLWithPath: versionPath).lastPathComponent)"]
        var files = referenceFiles.map { "\(home)/\($0)" }
        let agents = "\(home)/\(launchAgents)"
        do {
            files += try FileManager.default.contentsOfDirectory(atPath: agents)
                .filter { $0.hasSuffix(".plist") }
                .map { "\(agents)/\($0)" }
        } catch {
            guard isMissing(agents) else { return nil }
        }
        for file in files {
            guard context.mayRead(file) else { return nil }
            guard let data = FileManager.default.contents(atPath: file) else {
                if isMissing(file) { continue }
                return nil
            }
            guard let text = searchableText(data) else { return nil }
            if needles.contains(where: { text.contains($0) }) { return true }
        }
        return false
    }

    /// A file's text, with a binary property list turned into XML first.
    static func searchableText(_ data: Data) -> String? {
        if data.starts(with: Array("bplist".utf8)) {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            else { return nil }
            return String(data: xml, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    static func readText(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    static func isMissing(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }

    // MARK: Scan

    /// The `.nvmrc` files in `roots` and in every folder above them, for the
    /// ledger: nvm walks up from where it runs until it finds one. In home the
    /// walk up stops at home; elsewhere it stops below `/` and `/Volumes`.
    static func nvmrcFiles(inProjectRoots roots: [URL], home: String) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        for root in roots {
            var folder = root.standardizedFileURL.path
            while !folder.isEmpty, folder != "/", folder != "/Volumes", seen.insert(folder).inserted {
                let file = "\(folder)/.nvmrc"
                if OldToolVersionScanPolicy.isRegularFile(file) { found.append(file) }
                if folder == home { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return found
    }
}

/// The `.nvmrc` files Dev Projects scans found (#400), kept in
/// `nvmrc-files.json` beside Purge's other files. The Dev Tools scan runs
/// before the project walk, so the list from earlier walks is what it reads.
/// Each walk adds what it found and keeps the rest, so a narrower walk, such as
/// one without Full Disk Access, never drops a pin. Only a file confirmed gone
/// (`NvmNodeVersionPolicy.isGone`) leaves the list. Until a walk has saved the
/// list, and while it holds more than `limit` files, nvm offers no version.
nonisolated final class NvmrcLedger: @unchecked Sendable {
    static let fileName = "nvmrc-files.json"
    static let shared = NvmrcLedger(fileURL: AppSupportFolder.url().appendingPathComponent(fileName))

    private let fileURL: URL
    private let limit: Int
    private let lock = NSLock()
    /// The list as last read or written. Only Purge writes the file.
    private var cached: [String]??

    init(fileURL: URL, limit: Int = 5_000) {
        self.fileURL = fileURL
        self.limit = limit
    }

    private struct Contents: Codable {
        var files: [String]
    }

    /// The recorded files. Nil when no walk has saved them, the list can't be
    /// read, or it is longer than `limit`, which keeps every version.
    func files() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        let files: [String]?
        if let cached {
            files = cached
        } else {
            files = read()
            cached = .some(files)
        }
        guard let files, files.count <= limit else { return nil }
        return files
    }

    /// Adds the files a finished walk found. A recorded file is dropped only
    /// when `isGone` confirms it, and never one macOS would ask about reading.
    func record(
        _ found: [String],
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        mayRead: (String) -> Bool = { _ in true }
    ) {
        lock.lock()
        defer { lock.unlock() }
        let foundSet = Set(found)
        let kept = (read() ?? []).filter { file in
            if foundSet.contains(file) { return true }
            guard mayRead(file) else { return true }
            var info = stat()
            if lstat(file, &info) == 0 { return true }
            guard errno == ENOENT || errno == ENOTDIR else { return true }
            return NvmNodeVersionPolicy.isGone(file, home: home) != true
        }
        var seen = Set<String>()
        let merged = (found + kept).filter { seen.insert($0).inserted }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(Contents(files: merged)).write(to: fileURL, options: .atomic)
            cached = .some(merged)
        } catch {
            // Unsaved, the next walk tries again. Until one saves, nothing is offered.
            cached = nil
        }
    }

    private func read() -> [String]? {
        guard let data = try? Data(contentsOf: fileURL),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return nil }
        return contents.files
    }
}
