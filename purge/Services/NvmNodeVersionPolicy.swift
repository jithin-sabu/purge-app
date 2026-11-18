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
    /// Node 25 stopped shipping Corepack. From then on a Corepack in the version
    /// is one the user installed, and `nvm install` doesn't bring it back.
    static let lastMajorWithCorepack = 24

    /// What Node of `major` ships, by the rules above.
    static func bundled(major: Int) -> (packages: Set<String>, commands: Set<String>) {
        guard major > lastMajorWithCorepack else { return (bundledPackages, bundledCommands) }
        return (bundledPackages.subtracting(["corepack"]), bundledCommands.subtracting(["corepack"]))
    }

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
        /// The `.nvmrc` paths nvm would read for the projects Dev Projects scans
        /// found, there or not, or nil before a full scan recorded them.
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
        var checked = Set<String>()
        for file in [homeNvmrc] + recorded where checked.insert(file).inserted {
            guard let pinned = nvmrcPin(file, home: home, installed: installed, aliasRoot: aliases, context: context)
            else { return nil }
            kept.formUnion(pinned)
        }
        return kept
    }

    /// The versions the `.nvmrc` at `file` pins: none when there is no file
    /// there, which is most of the recorded paths. Nil when Purge can't tell:
    /// macOS would ask about reading it, it may be on a drive that is only
    /// unplugged, or its text isn't a version nvm and Purge both read.
    static func nvmrcPin(
        _ file: String, home: String, installed: [String], aliasRoot: String, context: Context
    ) -> Set<String>? {
        guard context.mayRead(file) else { return nil }
        var info = stat()
        guard lstat(file, &info) == 0 else {
            guard errno == ENOENT || errno == ENOTDIR else { return nil }
            return isGone(file, home: home) == true ? [] : nil
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            break
        case S_IFDIR:
            // nvm reads only a file.
            return []
        case S_IFLNK:
            // nvm follows a link. Its target must be readable without a prompt.
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: file) else { return nil }
            let folder = URL(fileURLWithPath: file).deletingLastPathComponent()
            let resolved = URL(fileURLWithPath: target, relativeTo: folder).standardizedFileURL.path
            guard context.mayRead(resolved),
                  context.mayRead(URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path) else { return nil }
        default:
            return nil
        }
        guard let text = readText(file),
              let line = nvmrcVersionLine(text) else { return nil }
        return resolve(line, installed: installed, aliasRoot: aliasRoot)
    }

    /// The `v<version>` folders in `root`, hidden names left out. Empty when nvm
    /// has no Node versions. Nil when the folder can't be listed, or a version
    /// name there is a link: nvm uses a linked version, and a pin on it would
    /// keep the folder it leads to, which Purge doesn't follow.
    static func installedVersions(in root: String) -> [String]? {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            return isMissing(root) ? [] : nil
        }
        var found: [String] = []
        for name in names where versionNumber(ofFolderName: name) != nil {
            var info = stat()
            guard lstat("\(root)/\(name)", &info) == 0 else { return nil }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: found.append(name)
            case S_IFLNK: return nil
            default: continue
            }
        }
        return found
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

    /// Whether the version holds a global package or a command its Node didn't
    /// ship. True when either folder can't be read.
    static func hasGlobalPackages(_ versionPath: String) -> Bool {
        guard let number = versionNumber(ofFolderName: URL(fileURLWithPath: versionPath).lastPathComponent),
              let major = Int(major(of: number)) else { return true }
        let shipped = bundled(major: major)
        func extras(in folder: String, bundled: Set<String>) -> Bool {
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: folder)
                return names.contains { !$0.hasPrefix(".") && !bundled.contains($0) }
            } catch {
                return !isMissing(folder)
            }
        }
        return extras(in: "\(versionPath)/lib/node_modules", bundled: shipped.packages)
            || extras(in: "\(versionPath)/bin", bundled: shipped.commands)
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
        // A file right in `/Volumes` is on the startup disk.
        if parts.first == "Volumes", parts.count > 2 {
            return OldToolVersionScanPolicy.isRealFolder("/Volumes/\(parts[1])") ? true : nil
        }
        return true
    }

    /// Whether a link in one of `linkFolders` points into the version. Nil when
    /// a folder is there but can't be listed, or a link leads somewhere macOS
    /// would ask about reading.
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
                func pointsIn(_ path: String) -> Bool {
                    spellings.contains { PathContainment.isSameOrInside(path, $0) }
                }
                if pointsIn(resolved.lowercased()) { return true }
                // Following the target's own links reads it, which macOS may ask
                // about. Such a target isn't followed, and keeps every version.
                guard context.mayRead(resolved) else { return nil }
                if OldToolVersionScanPolicy.comparableSpellings(of: resolved).contains(where: pointsIn) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether a LaunchAgent or an MCP config names a path inside the version. Nil
    /// when one is there but can't be read.
    static func isNamedByReferenceFile(_ versionPath: String, home: String, context: Context) -> Bool? {
        let name = URL(fileURLWithPath: versionPath).lastPathComponent
        var files = referenceFiles.map { "\(home)/\($0)" }
        let agents = "\(home)/\(launchAgents)"
        guard context.mayRead(agents) else { return nil }
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
            if names(text, versionFolder: name) { return true }
        }
        return false
    }

    /// Whether `text` names a path in the version folder `name`. JSON may write
    /// `/` as `\/`, and the Mac's disk ignores case, so both count. A longer
    /// version (`v20.1.10` for `v20.1.1`) doesn't.
    static func names(_ text: String, versionFolder name: String) -> Bool {
        let haystack = text.lowercased()
        let escapedRoot = versionsRoot.replacingOccurrences(of: "/", with: "\\/")
        for needle in ["\(versionsRoot)/\(name)", "\(escapedRoot)\\/\(name)"].map({ $0.lowercased() }) {
            var searchFrom = haystack.startIndex
            while let found = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
                guard found.upperBound < haystack.endIndex else { return true }
                let next = haystack[found.upperBound]
                if !(next.isLetter || next.isNumber || next == "." || next == "-" || next == "_") { return true }
                searchFrom = found.upperBound
            }
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

    /// The `.nvmrc` paths nvm reads for `roots`, for the ledger: one in each
    /// project and in every folder above it, up to `/`, since nvm walks up until
    /// it finds one. Each is listed whether a file is there now or not, so one
    /// added after the scan still counts at the move.
    static func nvmrcFiles(inProjectRoots roots: [URL]) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for root in roots {
            var folder = root.standardizedFileURL.path
            while !folder.isEmpty, seen.insert(folder).inserted {
                paths.append(folder == "/" ? "/.nvmrc" : "\(folder)/.nvmrc")
                if folder == "/" { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return paths
    }
}

/// The `.nvmrc` paths nvm reads for the projects Dev Projects scans found
/// (#400), kept in `nvmrc-files.json` beside Purge's other files. The Dev Tools
/// scan runs before the project walk, so the list from earlier walks is what it
/// reads. Each walk adds its paths and keeps the rest, so a narrower walk, such
/// as one without Full Disk Access, never drops a pin. A path leaves the list
/// only once the folder it is in is confirmed gone (`NvmNodeVersionPolicy.isGone`).
///
/// nvm offers no version until a walk with Full Disk Access has saved the list,
/// since a walk without it can't see projects in Documents and other protected
/// folders. Nor while the list holds more than `limit` paths, can't be read, or
/// a walk's paths couldn't be saved.
nonisolated final class NvmrcLedger: @unchecked Sendable {
    static let fileName = "nvmrc-files.json"
    /// Where the paths go when the list can't be saved. While this file is
    /// there the list doesn't count, even after a restart, and the next walk
    /// adds its paths back in.
    static let unsavedFileName = "nvmrc-files.unsaved.json"
    static let shared = NvmrcLedger(fileURL: AppSupportFolder.url().appendingPathComponent(fileName))

    private let fileURL: URL
    private let unsavedURL: URL
    private let limit: Int
    private let write: @Sendable (Data, URL) throws -> Void
    private let lock = NSLock()
    /// The list as last read or written, or `.some(nil)` when it can't be
    /// trusted. Only Purge writes the file.
    private var cached: Contents??
    /// Paths a walk found that are on no list on disk yet.
    private var unsaved: [String] = []

    init(
        fileURL: URL,
        limit: Int = 5_000,
        write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        self.fileURL = fileURL
        unsavedURL = fileURL.deletingLastPathComponent().appendingPathComponent(Self.unsavedFileName)
        self.limit = limit
        self.write = write
    }

    private struct Contents: Codable {
        var files: [String]
        /// Whether a walk with Full Disk Access has added its paths.
        var fullAccess: Bool
    }

    private enum Stored {
        case missing
        case unreadable
        case saved(Contents)
    }

    /// The recorded paths. Nil, which keeps every version, until a walk with
    /// Full Disk Access saved them, and when the list can't be read or trusted
    /// or is longer than `limit`.
    func files() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        let contents: Contents?
        if let cached {
            contents = cached
        } else {
            if case .saved(let saved) = load() { contents = saved } else { contents = nil }
            cached = .some(contents)
        }
        guard let contents, contents.fullAccess, contents.files.count <= limit else { return nil }
        return contents.files
    }

    /// Adds the paths a finished walk found. A recorded path is dropped only
    /// when the folder it is in is confirmed gone, and never one macOS would ask
    /// about reading. A list that can't be read starts again from this walk, and
    /// stays untrusted until a walk with Full Disk Access adds to it.
    func record(
        _ found: [String],
        home: String,
        fullAccess: Bool,
        mayRead: (String) -> Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        var previous: Contents
        switch load() {
        case .saved(let saved): previous = saved
        case .missing, .unreadable: previous = Contents(files: [], fullAccess: false)
        }
        previous.files += unsaved
        let foundSet = Set(found)
        let kept = previous.files.filter { file in
            if foundSet.contains(file) { return true }
            guard mayRead(file) else { return true }
            let folder = (file as NSString).deletingLastPathComponent
            var info = stat()
            if lstat(folder, &info) == 0 { return true }
            guard errno == ENOENT || errno == ENOTDIR else { return true }
            return NvmNodeVersionPolicy.isGone(file, home: home) != true
        }
        var seen = Set<String>()
        let merged = Contents(
            files: (found + kept).filter { seen.insert($0).inserted },
            fullAccess: previous.fullAccess || fullAccess
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try write(JSONEncoder().encode(merged), fileURL)
            cached = .some(merged)
            unsaved = []
            if !NvmNodeVersionPolicy.isMissing(unsavedURL.path) {
                // When this fails the list stays untrusted after a restart,
                // until a walk removes it.
                try? FileManager.default.removeItem(at: unsavedURL)
            }
        } catch {
            // The saved list lacks this walk's paths, so it can't be trusted, now
            // or after a restart. Until a walk saves again, nothing is offered.
            unsaved = merged.files
            cached = .some(nil)
            setAside(merged.files)
        }
    }

    /// Keeps the paths where a restart can't trust them but the next walk
    /// adds them back: all of them when they can be written, else the old list
    /// moved aside, which needs no free space. An unsaved file already there
    /// stays, since its being there is what keeps the list untrusted. Only when
    /// none of that works is the old list removed.
    private func setAside(_ files: [String]) {
        if let data = try? JSONEncoder().encode(Contents(files: files, fullAccess: false)),
           (try? write(data, unsavedURL)) != nil {
            return
        }
        guard NvmNodeVersionPolicy.isMissing(unsavedURL.path) else { return }
        if NvmNodeVersionPolicy.isMissing(fileURL.path) { return }
        if rename(fileURL.path, unsavedURL.path) == 0 { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The saved list, with any paths set aside after a failed save added in.
    /// Set-aside paths make the list untrusted until a walk saves again.
    private func load() -> Stored {
        let saved = Self.read(fileURL)
        let aside = Self.read(unsavedURL)
        var files: [String]
        switch saved {
        case .saved(let contents):
            if case .missing = aside { return saved }
            files = contents.files
        case .missing, .unreadable:
            if case .missing = aside { return saved }
            files = []
        }
        if case .saved(let contents) = aside { files += contents.files }
        var seen = Set<String>()
        return .saved(Contents(files: files.filter { seen.insert($0).inserted }, fullAccess: false))
    }

    private static func read(_ url: URL) -> Stored {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return NvmNodeVersionPolicy.isMissing(url.path) ? .missing : .unreadable
        }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return .unreadable }
        return .saved(contents)
    }
}
