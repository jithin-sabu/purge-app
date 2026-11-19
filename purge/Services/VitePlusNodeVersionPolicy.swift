import Darwin
import Foundation

/// Node.js versions Vite+ installs for itself, and the folders an install it
/// never finished leaves behind (#398).
///
/// Vite+ keeps every Node version it downloads in `<data>/js_runtime/node/<version>`
/// and never removes one. `<data>` is `~/.vite-plus` for an install from before
/// August 2026, or one with a `~/.vite-plus/current` link, and
/// `~/.local/share/vite-plus` for a newer one. An app started from Finder never
/// sees `VP_HOME` or `XDG_DATA_HOME`, so only these two count, and the rules
/// below read both.
///
/// A version is offered only when nothing Purge can see still uses it:
///
/// - it is not the newest installed version of its major,
/// - no Vite+ default (`defaultNodeVersion` in `config.json`) or session pin
///   (`.session-node-version`, which `vp env use` writes) names it,
/// - no global tool Vite+ installed records it (`bins/*.json`,
///   `packages/*.json`), and it holds no global npm package or npm config,
/// - no `.node-version`, `package.json` (`devEngines.runtime`, `engines.node`)
///   or `.nvmrc` beside a project Dev Projects found, or in a folder above
///   one, resolves to it. Vite+ reads all four. For a range, the newest
///   installed version that matches is kept, which is what `vp` picks,
/// - no LaunchAgent, MCP or Claude Code config, or shell startup file names a
///   path inside it, and no link in a `bin` folder points into it,
/// - and, right before the move, no process has a file open inside it.
///
/// The `<version>.lock` file beside each version stays. Vite+ keeps it on
/// purpose, so every installer locks the same file, and `vp env uninstall`
/// leaves it too. It is empty.
///
/// `js_runtime/.tmp*` folders are where an install downloads and unpacks Node
/// before it renames the result into place. One is left only when the install
/// was stopped, and nothing reads it again. One is offered once nothing in it
/// has changed for a day, judged by each entry's change time too, since the
/// unpacked files carry Node's release dates.
///
/// The checks run in the same three places as nvm's (`NvmNodeVersionPolicy`).
/// Anything that can't be read or understood keeps every version.
nonisolated enum VitePlusNodeVersionPolicy {

    /// Where Vite+ keeps its data, relative to home: the older single folder,
    /// and the newer XDG one.
    static let dataRoots = [".vite-plus", ".local/share/vite-plus"]
    /// Where Vite+ keeps `config.json`, for each layout.
    static let configFiles = [".vite-plus/config.json", ".config/vite-plus/config.json"]
    /// The pin `vp env use` writes, for each layout.
    static let sessionFiles = [".vite-plus/.session-node-version", ".local/state/vite-plus/.session-node-version"]
    static let runtimeFolder = "js_runtime"
    static let versionsFolder = "js_runtime/node"

    /// One row per version, labelled `Vite+ Node.js <version>`.
    static let labelPrefix = "Vite+ Node.js "
    static let explanationKey = "vite-plus-node-version"
    static let leftoversLabel = "Unfinished Vite+ Node Downloads"
    static let leftoversExplanationKey = "vite-plus-node-install-leftovers"
    /// The name the `tempfile` crate gives the folder an install works in.
    static let leftoverPrefix = ".tmp"

    /// The files Vite+ reads for a project's Node version, in each folder from
    /// the project up to `/`.
    static let pinFileNames = [".node-version", "package.json", ".nvmrc"]
    /// nvm's `bin` folders, and the ones where Vite+ links its global tools.
    static let linkFolders = NvmNodeVersionPolicy.linkFolders + dataRoots.map { "\($0)/bin" }

    /// Values Vite+ reads as the newest release of a line, which is the newest
    /// installed version of its major when it is installed at all, and values it
    /// doesn't read. Neither keeps anything the newest-of-each-major rule doesn't.
    static let aliasesKeepingNothingMore: Set<String> = [
        "lts", "lts/*", "latest", "node", "stable", "current", "system", "default", "iojs"
    ]

    // MARK: Labels and names

    /// The version in a row's label, or nil for any other label.
    static func version(inLabel label: String) -> String? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        let version = String(label.dropFirst(labelPrefix.count))
        return versionNumber(ofFolderName: version)
    }

    /// `22.14.0`, with no `v`, as Vite+ names a version folder. Nil for any
    /// other name, a pre-release included.
    static func versionNumber(ofFolderName name: String) -> String? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, OldToolVersionScanPolicy.isDottedVersion(name) else { return nil }
        return name
    }

    static func isLeftoverName(_ name: String) -> Bool {
        name.hasPrefix(leftoverPrefix) && name.count > leftoverPrefix.count
    }

    nonisolated enum Kind: Equatable, Sendable {
        case version
        case installLeftover
    }

    /// What `path` is by its place and name alone. The `.lock` beside a
    /// version is nothing.
    static func kind(of path: String, home: String) -> Kind? {
        for root in dataRoots {
            if let name = OldToolVersionScanPolicy.onlyChild(path, of: "\(home)/\(root)/\(versionsFolder)"),
               versionNumber(ofFolderName: name) != nil {
                return .version
            }
            if let name = OldToolVersionScanPolicy.onlyChild(path, of: "\(home)/\(root)/\(runtimeFolder)"),
               isLeftoverName(name) {
                return .installLeftover
            }
        }
        return nil
    }

    /// The versions folder holding `path`, relative to home, when it is a version.
    static func versionsRoot(of path: String, home: String) -> String? {
        dataRoots.map { "\($0)/\(versionsFolder)" }.first { root in
            OldToolVersionScanPolicy.onlyChild(path, of: "\(home)/\(root)") != nil
        }
    }

    // MARK: Context

    nonisolated struct Context: Sendable {
        /// The pin files Vite+ would read for the projects Dev Projects scans
        /// found, there or not, or nil before a full scan recorded them.
        var pinFiles: @Sendable () -> [String]?
        /// Whether a file may be read without a macOS prompt. Tests allow everything.
        var mayRead: @Sendable (_ path: String) -> Bool
        /// The `lsof` listing, read only right before a move.
        var openFiles: OpenFileCheck.Lister
        /// The `bin` folders searched for links into a version. Tests use their own.
        var linkFolders: [String] = VitePlusNodeVersionPolicy.linkFolders

        /// `access` is worked out once here, not for each file: it probes Full
        /// Disk Access by opening folders.
        static func current(home: String, access: ScanAccess = ScanAccess.current()) -> Context {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            return Context(
                pinFiles: { VitePlusNodeVersionPolicy.ledger.files() },
                mayRead: { path in
                    ProtectedLocations.isReadable(URL(fileURLWithPath: path), access: access, home: homeURL)
                },
                openFiles: OpenFileCheck.liveListing
            )
        }
    }

    /// The pin files recorded by Dev Projects walks. Three names in each
    /// folder, so it holds three times what nvm's list does.
    static let ledger = NvmrcLedger(
        fileURL: AppSupportFolder.url().appendingPathComponent("node-pin-files.json"),
        limit: 15_000
    )

    // MARK: Gate

    /// Whether the entry at `path` is offered now, judged as far as `check` goes.
    static func isOffered(
        _ path: String,
        home: String,
        now: Date,
        context: Context,
        check: NvmNodeVersionPolicy.Check
    ) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let kind = kind(of: path, home: home),
              !PathContainment.containsSymlinkComponent(url, home: home),
              OldToolVersionScanPolicy.isRealFolder(path) else { return false }
        switch kind {
        case .installLeftover:
            guard isQuiet(path, before: now.addingTimeInterval(-OldToolVersionScanPolicy.minimumLeftoverAge))
            else { return false }
        case .version:
            let name = url.lastPathComponent
            guard let root = versionsRoot(of: path, home: home),
                  let kept = check == .quick
                    ? recentKeptVersions(in: "\(home)/\(root)", home: home, context: context, now: now)
                    : keptVersions(in: "\(home)/\(root)", home: home, context: context),
                  !kept.contains(name),
                  !NvmNodeVersionPolicy.hasGlobalPackages(path, major: Int(NvmNodeVersionPolicy.major(of: name))),
                  !NvmNodeVersionPolicy.hasGlobalNpmConfig(path) else { return false }
            switch check {
            case .quick:
                break
            case .scan, .move:
                guard let named = isNamedByReferenceFile(path, home: home, context: context), !named,
                      let linked = NvmNodeVersionPolicy.isLinkedFromBinFolder(
                        path, home: home, linkFolders: context.linkFolders, mayRead: context.mayRead
                      ), !linked else { return false }
            }
        }
        switch check {
        case .quick, .scan:
            return true
        case .move:
            return OpenFileCheck.check(folders: [url], lister: context.openFiles) == .free
        }
    }

    /// Whether a config file names the version through either data folder.
    /// One data folder may be a link to the other, so a path written through
    /// `~/.vite-plus` can lead to the folder judged under `~/.local/share`.
    /// Nil when a file can't be read, or when a data folder is itself a link:
    /// then a config may name the version by a spelling Purge doesn't search.
    static func isNamedByReferenceFile(_ path: String, home: String, context: Context) -> Bool? {
        for root in dataRoots {
            var info = stat()
            if lstat("\(home)/\(root)", &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return nil }
        }
        for root in dataRoots {
            guard let named = NvmNodeVersionPolicy.isNamedByReferenceFile(
                path, home: home, versionsRoot: "\(root)/\(versionsFolder)", mayRead: context.mayRead
            ) else { return nil }
            if named { return true }
        }
        return false
    }

    /// `FileDeleter`'s last check before it moves a Vite+ version or leftover:
    /// every rule again, `lsof` included. True for every other path, which
    /// other rules judge.
    static func passesImmediateTrashBoundary(
        _ url: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        now: Date = Date(),
        context: Context? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard kind(of: path, home: home) != nil else { return true }
        return isOffered(path, home: home, now: now, context: context ?? .current(home: home), check: .move)
    }

    private static let recentLock = NSLock()
    private nonisolated(unsafe) static var recent: [String: (at: Date, kept: Set<String>?)] = [:]
    private nonisolated(unsafe) static var recentPins: [String: (at: Date, values: [String]?)] = [:]

    /// `keptVersions`, from a read in the last `NvmNodeVersionPolicy.recentReadLifetime`
    /// seconds when there is one. Only the main-thread gate uses it.
    static func recentKeptVersions(in root: String, home: String, context: Context, now: Date = Date()) -> Set<String>? {
        recentLock.lock()
        let cached = recent[root]
        recentLock.unlock()
        if let cached, isRecent(cached.at, now: now) {
            return cached.kept
        }
        let kept = keptVersions(in: root, home: home, context: context, values: recentPinValues(home: home, context: context, now: now))
        recentLock.lock()
        recent[root] = (now, kept)
        recentLock.unlock()
        return kept
    }

    /// `pinValues`, shared by both data folders' reads, so the pin files are
    /// read once for both.
    static func recentPinValues(home: String, context: Context, now: Date = Date()) -> [String]? {
        recentLock.lock()
        let cached = recentPins[home]
        recentLock.unlock()
        if let cached, isRecent(cached.at, now: now) {
            return cached.values
        }
        let values = pinValues(home: home, context: context)
        recentLock.lock()
        recentPins[home] = (now, values)
        recentLock.unlock()
        return values
    }

    private static func isRecent(_ at: Date, now: Date) -> Bool {
        now.timeIntervalSince(at) < NvmNodeVersionPolicy.recentReadLifetime && now >= at
    }

    /// The version folders in `root` nothing may remove now. Nil, which keeps
    /// every version, when a source can't be read or understood. `values` are
    /// the pin values when the caller has read them already.
    static func keptVersions(
        in root: String, home: String, context: Context, values given: [String]?? = .none
    ) -> Set<String>? {
        let values: [String]?
        switch given {
        case .some(let read): values = read
        case .none: values = pinValues(home: home, context: context)
        }
        guard let installed = installedVersions(in: root), let values else { return nil }
        // Vite+ counts a folder as installed only once it holds `bin/node`, so
        // the newest by that count is kept too.
        let withNode = installed.filter { OldToolVersionScanPolicy.isRegularFile("\(root)/\($0)/bin/node") }
        var kept = newestOfEachMajor(installed).union(newestOfEachMajor(withNode))
        for value in values {
            guard let pinned = pinnedVersions(value, installed: installed) else { return nil }
            kept.formUnion(pinned)
        }
        return kept
    }

    static func newestOfEachMajor(_ names: [String]) -> Set<String> {
        var newest: [String: String] = [:]
        for name in names {
            let major = NvmNodeVersionPolicy.major(of: name)
            if let current = newest[major], !OldToolVersionScanPolicy.isLower(current, than: name) { continue }
            newest[major] = name
        }
        return Set(newest.values)
    }

    /// The installed versions a pin keeps: an exact version, or the newest
    /// installed version a range takes. A partial version such as `20.5` is
    /// read both as npm reads it and as Vite+ does (`^20.5.0`). Nil for a value
    /// Purge can't read.
    static func pinnedVersions(_ value: String, installed: [String]) -> Set<String>? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        if aliasesKeepingNothingMore.contains(lowered) || lowered.hasPrefix("lts/") { return [] }
        if let exact = NodeVersionRange.Version(trimmed) {
            return ["\(exact.major).\(exact.minor).\(exact.patch)"]
        }
        guard let range = NodeVersionRange(trimmed) else { return nil }
        var pinned = Set([range.newestMatch(in: installed)].compactMap { $0 })
        let number = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        if number.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
           let caret = NodeVersionRange("^\(number)"),
           let match = caret.newestMatch(in: installed) {
            pinned.insert(match)
        }
        return pinned
    }

    /// The version folders in `root`. Empty when Vite+ has none. Nil when the
    /// folder can't be listed, or a version name there is a link.
    static func installedVersions(in root: String) -> [String]? {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            return NvmNodeVersionPolicy.isMissing(root) ? [] : nil
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

    // MARK: Pins

    /// Every Node version text Vite+ may read: its defaults, session pins, the
    /// versions its global tools run on, and the project pin files. Nil when
    /// one can't be read or understood.
    static func pinValues(home: String, context: Context) -> [String]? {
        var values: [String] = []
        for file in configFiles {
            guard let config = jsonObject("\(home)/\(file)", home: home, context: context) else { return nil }
            if let value = config?["defaultNodeVersion"] {
                guard let text = value as? String else { return nil }
                values.append(text)
            }
        }
        for file in sessionFiles {
            switch NvmNodeVersionPolicy.readPinFile("\(home)/\(file)", home: home, mayRead: context.mayRead) {
            case .absent: continue
            case .unknown: return nil
            case .text(let text): values.append(firstLine(text))
            }
        }
        for root in dataRoots {
            guard let bins = jsonFiles(in: "\(home)/\(root)/bins", home: home, scoped: false, context: context),
                  let packages = jsonFiles(in: "\(home)/\(root)/packages", home: home, scoped: true, context: context)
            else { return nil }
            // Vite+ requires both fields, so a record without one is not one
            // Purge understands.
            for file in bins {
                guard let object = jsonObject(file, home: home, context: context), let object,
                      let text = object["nodeVersion"] as? String else { return nil }
                values.append(text)
            }
            for file in packages {
                guard let object = jsonObject(file, home: home, context: context), let object,
                      let platform = object["platform"] as? [String: Any],
                      let text = platform["node"] as? String else { return nil }
                values.append(text)
            }
        }
        guard let recorded = context.pinFiles() else { return nil }
        for file in recorded {
            guard let pins = projectPins(file, home: home, context: context) else { return nil }
            values += pins
        }
        return values
    }

    /// The versions one recorded pin file names. Empty when there is no file.
    static func projectPins(_ file: String, home: String, context: Context) -> [String]? {
        let text: String
        switch NvmNodeVersionPolicy.readPinFile(file, home: home, mayRead: context.mayRead) {
        case .absent: return []
        case .unknown: return nil
        case .text(let read): text = read
        }
        switch URL(fileURLWithPath: file).lastPathComponent {
        case ".node-version":
            // Vite+ reads only the first line, and a blank one pins nothing
            // (`parse_node_version_content` in `crates/vp_js_runtime/src/dev_engines.rs`).
            // Other readers take the first line with text, so that one counts too.
            let firstWithText = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return [firstLine(text)] + (firstWithText.map { [$0] } ?? [])
        case ".nvmrc":
            let lines = text.split(whereSeparator: \.isNewline)
            guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return [] }
            return NvmNodeVersionPolicy.nvmrcVersionLine(text).map { [$0] }
        case "package.json":
            return packageJSONPins(text)
        default:
            return nil
        }
    }

    /// `devEngines.runtime` (an object or a list; the entry named `node`) and
    /// `engines.node`. Nil when the file isn't JSON Purge can read.
    static func packageJSONPins(_ text: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var pins: [String] = []
        if let engines = object["engines"] as? [String: Any], let node = engines["node"] {
            guard let text = node as? String else { return nil }
            pins.append(text)
        }
        if let devEngines = object["devEngines"] as? [String: Any], let runtime = devEngines["runtime"] {
            let entries: [Any]
            if let list = runtime as? [Any] { entries = list } else { entries = [runtime] }
            for entry in entries {
                guard let entry = entry as? [String: Any] else { return nil }
                guard (entry["name"] as? String)?.lowercased() == "node" else { continue }
                if let version = entry["version"] {
                    guard let text = version as? String else { return nil }
                    pins.append(text)
                }
            }
        }
        return pins
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The JSON object in `file`: `.some(nil)` when there is no file, nil when
    /// it can't be read or isn't an object.
    static func jsonObject(_ file: String, home: String, context: Context) -> [String: Any]?? {
        guard context.mayRead(file) else { return nil }
        guard let data = FileManager.default.contents(atPath: file) else {
            return isAbsent(file, home: home) ? .some(nil) : nil
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return .some(object)
    }

    /// The `.json` files in `folder`, and in its `@scope` folders when `scoped`.
    /// Empty when the folder is missing. Nil when it can't be listed.
    ///
    /// Vite+ keeps one record per global tool: `bins/<command>.json`
    /// (`BinConfig::path` in `crates/vp_global_cli/src/commands/env/bin_config.rs`)
    /// and `packages/<name>.json` or `packages/@scope/<name>.json`
    /// (`PackageMetadata::metadata_path` in `package_metadata.rs`). The other
    /// folders there, `packages/<name>/<id>` and `packages/@scope/<name>/<id>`,
    /// are the installs themselves, which run on the Node version their record
    /// names. An `@scope` entry that isn't a real folder is a layout Purge
    /// doesn't know, and keeps every version.
    static func jsonFiles(in folder: String, home: String, scoped: Bool, context: Context) -> [String]? {
        guard context.mayRead(folder) else { return nil }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch {
            return isAbsent(folder, home: home) ? [] : nil
        }
        var files: [String] = []
        for name in names where !name.hasPrefix(".") {
            let entry = "\(folder)/\(name)"
            if name.hasSuffix(".json") {
                files.append(entry)
            } else if scoped, name.hasPrefix("@") {
                guard OldToolVersionScanPolicy.isRealFolder(entry),
                      let nested = jsonFiles(in: entry, home: home, scoped: false, context: context) else { return nil }
                files += nested
            }
        }
        return files
    }

    /// Whether nothing is at `path` for sure: missing, and not behind a link
    /// that may lead to a drive that is only unplugged (`NvmNodeVersionPolicy.isGone`).
    static func isAbsent(_ path: String, home: String) -> Bool {
        NvmNodeVersionPolicy.isMissing(path) && NvmNodeVersionPolicy.isGone(path, home: home) == true
    }

    // MARK: Leftovers

    /// The folder, each entry in it, and each entry one level further down, all
    /// last changed before `cutoff`, by both modification and status-change
    /// time. Unpacking keeps the archive's file dates but can't set the change
    /// time. False when any of them can't be read.
    static func isQuiet(_ path: String, before cutoff: Date) -> Bool {
        func quiet(_ entry: String) -> Bool {
            var info = stat()
            guard lstat(entry, &info) == 0 else { return false }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            let changed = Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec))
            return modified < cutoff && changed < cutoff
        }
        func walk(_ folder: String, depth: Int) -> Bool {
            guard quiet(folder) else { return false }
            guard depth < 2, OldToolVersionScanPolicy.isRealFolder(folder) else { return true }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return false }
            return names.allSatisfy { walk("\(folder)/\($0)", depth: depth + 1) }
        }
        return walk(path, depth: 0)
    }

    // MARK: Scan

    /// The pin-file paths Vite+ reads for `roots`, for the ledger: each name in
    /// each project and every folder above it, up to `/`. Each is listed
    /// whether a file is there now or not, so one added after the scan still
    /// counts at the move.
    static func pinFiles(inProjectRoots roots: [URL]) -> [String] {
        NvmNodeVersionPolicy.nvmrcFiles(inProjectRoots: roots).flatMap { nvmrc in
            let folder = (nvmrc as NSString).deletingLastPathComponent
            return pinFileNames.map { folder == "/" ? "/\($0)" : "\(folder)/\($0)" }
        }
    }
}
