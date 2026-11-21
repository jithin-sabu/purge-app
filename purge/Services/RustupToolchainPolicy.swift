import Darwin
import Foundation

/// Old Rust toolchains rustup keeps in `~/.rustup/toolchains` (#406).
///
/// rustup keeps every toolchain until you remove it by hand. A move to the
/// Trash can be undone, and rustup drops the `update-hashes` file a missing
/// toolchain leaves behind by itself on the next install (probed with rustup
/// 1.29.3: "removing stray hash file in order to continue").
///
/// Only a toolchain rustup can install again by its name is ever a candidate:
/// a version (`1.84.0-aarch64-apple-darwin`) or a dated channel
/// (`nightly-2024-05-01-aarch64-apple-darwin`). The moving channels (`stable`,
/// `beta`, `nightly` with no date), which `rustup update` tracks, and custom
/// names (`stage1`, `esp`, a linked toolchain) are never one.
///
/// A candidate is offered only when nothing Purge can see still uses it:
///
/// - rustup finished installing it over a day ago,
/// - `~/.rustup/settings.toml` names it neither as the default nor in a
///   directory override,
/// - `RUSTUP_TOOLCHAIN` doesn't name it,
/// - no `rust-toolchain` or `rust-toolchain.toml` names it: the ones in home,
///   beside each project a Dev Projects scan found, or in a folder above one,
///   which rustup also reads,
/// - no linked toolchain leads into it,
/// - no LaunchAgent, editor, MCP or cargo config, or shell startup file names
///   a path inside it, `+<toolchain>` or `RUSTUP_TOOLCHAIN`, no link in a `bin`
///   folder or in Kani's folder points into it, and dylint has no driver for it,
/// - and, right before the move, rustup isn't running and no process has a
///   file open inside it.
///
/// The checks run in the same three places as nvm's (`NvmNodeVersionPolicy`).
/// Anything that can't be read or understood keeps every toolchain. Only
/// `~/.rustup` counts: an app started from Finder never sees `RUSTUP_HOME`.
nonisolated enum RustupToolchainPolicy {

    static let toolchainsRoot = ".rustup/toolchains"
    static let settingsFile = ".rustup/settings.toml"
    /// The only `settings.toml` layout Purge reads. rustup refuses a file
    /// without a version, and an empty one may be a write in progress.
    static let settingsVersion = "12"

    /// One row per toolchain, labelled `rustup toolchain <folder name>`. The
    /// whole folder name, so two builds of one version stay two rows.
    static let labelPrefix = "rustup toolchain "
    static let explanationKey = "rustup-toolchain"

    static let movingChannels = ["stable", "beta", "nightly"]
    /// The hosts a Mac runs: Apple silicon, and Intel or Rosetta.
    static let hosts = ["aarch64-apple-darwin", "x86_64-apple-darwin"]

    /// What rustup writes last when it installs or changes a toolchain, inside it.
    static let installRecords = [
        "lib/rustlib/multirust-channel-manifest.toml",
        "lib/rustlib/multirust-config.toml",
        "lib/rustlib/components",
    ]
    /// The record only a toolchain installed from a release manifest has. With
    /// it, `rustup toolchain install` can bring the toolchain back.
    static let releaseManifest = "lib/rustlib/multirust-channel-manifest.toml"

    /// The files rustup reads for a project's toolchain, in each folder from
    /// the project up to `/`.
    static let pinFileNames = ["rust-toolchain", "rust-toolchain.toml"]
    static let environmentName = "RUSTUP_TOOLCHAIN"

    /// Files that may name a toolchain, relative to home: the ones nvm's rule
    /// reads, cargo's config (`[build] rustc`), and two more editors.
    static let referenceFiles = NvmNodeVersionPolicy.referenceFiles + [
        ".cargo/config.toml", ".cargo/config",
        ".config/zed/settings.json", ".config/helix/languages.toml",
    ]
    /// `bin` folders where a link may point into a toolchain. cargo's own holds
    /// rustup's proxies, which are not links.
    static let linkFolders = NvmNodeVersionPolicy.linkFolders + [".cargo/bin"]
    /// Kani links the nightly it needs as `~/.kani/kani-<version>/toolchain`.
    static let kaniFolder = ".kani"
    /// dylint keeps one driver per toolchain, in a folder named after it.
    static let dylintDrivers = ".dylint_drivers"

    // MARK: Names

    /// A toolchain name as rustup reads one: `<channel>[-<date>][-<host>]`.
    nonisolated struct Name: Equatable, Sendable {
        /// `stable`, `beta`, `nightly`, or a version such as `1.84.0`.
        var channel: String
        var date: String?
        var host: String?

        /// The name without its host: `1.84.0`, `nightly-2024-05-01`.
        var release: String { date.map { "\(channel)-\($0)" } ?? channel }
        var isVersion: Bool { !RustupToolchainPolicy.movingChannels.contains(channel) }
    }

    /// Reads `text` as a toolchain name, without case. Nil for a custom name.
    static func parse(_ text: String) -> Name? {
        let value = text.lowercased()
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(isNameScalar) else { return nil }
        var rest = Substring(value)
        let channel: String
        if let moving = movingChannels.first(where: { rest == $0 || rest.hasPrefix("\($0)-") }) {
            channel = moving
        } else if let version = versionPrefix(of: rest) {
            channel = version
        } else {
            return nil
        }
        rest = rest.dropFirst(channel.count)
        var date: String?
        if rest.hasPrefix("-"), let found = datePrefix(of: rest.dropFirst()) {
            date = found
            rest = rest.dropFirst(found.count + 1)
        }
        var host: String?
        if !rest.isEmpty {
            guard rest.hasPrefix("-"), rest.count > 1 else { return nil }
            host = String(rest.dropFirst())
        }
        return Name(channel: channel, date: date, host: host)
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "0"..."9", ".", "-", "_": return true
        default: return false
        }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// The version `text` starts with, in rustup's own pattern:
    /// `[0-9].(0|[1-9][0-9]{0,2})(.(0|[1-9][0-9]?))?(-beta(.[0-9]{1,2})?)?`,
    /// followed by `-` or the end. Any other number is a custom name to rustup.
    private static func versionPrefix(of text: Substring) -> String? {
        var rest = text
        guard let major = rest.first, isDigit(major) else { return nil }
        rest = rest.dropFirst()
        guard rest.hasPrefix(".") else { return nil }
        rest = rest.dropFirst()
        let minor = rest.prefix(while: isDigit)
        guard isBoundedNumber(minor, maxDigits: 3) else { return nil }
        rest = rest.dropFirst(minor.count)
        if rest.hasPrefix(".") {
            let patch = rest.dropFirst().prefix(while: isDigit)
            guard isBoundedNumber(patch, maxDigits: 2) else { return nil }
            rest = rest.dropFirst(patch.count + 1)
        }
        if rest.hasPrefix("-beta") {
            let after = rest.dropFirst("-beta".count)
            if after.isEmpty || after.hasPrefix("-") {
                rest = after
            } else if after.hasPrefix(".") {
                let number = after.dropFirst().prefix(while: isDigit)
                let end = after.dropFirst(number.count + 1)
                if (1...2).contains(number.count), end.isEmpty || end.hasPrefix("-") {
                    rest = end
                }
            }
        }
        guard rest.isEmpty || rest.hasPrefix("-") else { return nil }
        return String(text.dropLast(rest.count))
    }

    /// `0`, or up to `maxDigits` digits that don't start with `0`.
    private static func isBoundedNumber(_ digits: Substring, maxDigits: Int) -> Bool {
        guard (1...maxDigits).contains(digits.count) else { return false }
        return digits == "0" || !digits.hasPrefix("0")
    }

    /// `YYYY-MM-DD` at the start of `text`, followed by `-` or the end.
    private static func datePrefix(of text: Substring) -> String? {
        let date = text.prefix(10)
        guard date.count == 10 else { return nil }
        for (offset, character) in date.enumerated() {
            let wantsDash = offset == 4 || offset == 7
            guard wantsDash ? character == "-" : isDigit(character) else { return nil }
        }
        let rest = text.dropFirst(10)
        guard rest.isEmpty || rest.hasPrefix("-") else { return nil }
        return String(date)
    }

    /// The name of a folder that may be offered: a version, or a dated channel,
    /// for a Mac host, spelled as rustup spells it. Nil for a moving channel, a
    /// custom name, and anything else.
    static func offerableName(ofFolderName folder: String) -> Name? {
        guard folder == folder.lowercased(), let name = parse(folder),
              let host = name.host, hosts.contains(host) else { return nil }
        // A dated version (`1.84.0-2025-01-09`) is valid to rustup and rare. It stays.
        guard name.isVersion ? name.date == nil : name.date != nil else { return nil }
        return name
    }

    /// Whether `value`, from a setting, a pin file or the environment, names the
    /// toolchain in `folder`. rustup adds the host to a name without one, so
    /// `1.84` names `1.84-aarch64-apple-darwin` and never `1.84.0-…`. A part of
    /// a name keeps what starts with it (`nightly` keeps every nightly), which
    /// errs on keeping.
    static func names(_ value: String, folder: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let folder = folder.lowercased()
        guard !value.isEmpty else { return false }
        if folder == value || folder.hasPrefix("\(value)-") { return true }
        // A host without its CPU (`1.84.0-apple-darwin`) is a name rustup takes.
        if let named = parse(value), let installed = parse(folder) { return named.release == installed.release }
        return false
    }

    // MARK: Labels and shape

    /// The folder name in a row's label, or nil for any other label.
    static func toolchain(inLabel label: String) -> String? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        let folder = String(label.dropFirst(labelPrefix.count))
        return offerableName(ofFolderName: folder) == nil ? nil : folder
    }

    /// Whether `path` is a toolchain folder that may be offered, by its place
    /// and name alone.
    static func isToolchainPath(_ path: String, home: String) -> Bool {
        guard let folder = OldToolVersionScanPolicy.onlyChild(path, of: "\(home)/\(toolchainsRoot)") else { return false }
        return offerableName(ofFolderName: folder) != nil
    }

    /// The command that brings the toolchain back. `rustup toolchain install`
    /// installs only the host's parts, so the targets added to the toolchain at
    /// `path`, when it is given, are named too.
    static func reinstallCommand(forFolderName folder: String, at path: String? = nil) -> String {
        var command = "rustup toolchain install \(folder)"
        let targets = path.map { addedTargets(in: $0, folderName: folder) } ?? []
        if !targets.isEmpty { command += " --target \(targets.joined(separator: ","))" }
        return command
    }

    /// The targets in `lib/rustlib` besides the host's: each folder there that
    /// holds a `lib` folder.
    static func addedTargets(in toolchainPath: String, folderName: String) -> [String] {
        let rustlib = "\(toolchainPath)/lib/rustlib"
        let host = offerableName(ofFolderName: folderName)?.host
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rustlib)) ?? []
        return names.filter { name in
            name != host && !name.hasPrefix(".") && name.contains("-")
                && name.unicodeScalars.allSatisfy(isNameScalar)
                && OldToolVersionScanPolicy.isRealFolder("\(rustlib)/\(name)/lib")
        }
        .sorted()
    }

    // MARK: Context

    nonisolated struct Context: Sendable {
        /// The pin files rustup would read for the projects Dev Projects scans
        /// found, there or not, or nil before a full scan recorded them.
        var pinFiles: @Sendable () -> [String]?
        /// Whether a file may be read without a macOS prompt. Tests allow everything.
        var mayRead: @Sendable (_ path: String) -> Bool
        /// The `lsof` listing, read only right before a move.
        var openFiles: OpenFileCheck.Lister
        /// Every `RUSTUP_TOOLCHAIN` value Purge can see.
        var environment: @Sendable () -> [String]
        /// Whether rustup is at work, which may be inside a toolchain. Asked
        /// only right before a move.
        var rustupIsRunning: @Sendable () -> Bool
        /// The `bin` folders searched for links into a toolchain. Tests use their own.
        var linkFolders: [String] = RustupToolchainPolicy.linkFolders

        /// `access` is worked out once here, not for each file: it probes Full
        /// Disk Access by opening folders.
        static func current(home: String, access: ScanAccess = ScanAccess.current()) -> Context {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            return Context(
                pinFiles: { RustupToolchainPolicy.ledger.files() },
                mayRead: { path in
                    ProtectedLocations.isReadable(URL(fileURLWithPath: path), access: access, home: homeURL)
                },
                openFiles: OpenFileCheck.liveListing,
                // Both the value Purge was started with and launchd's: either
                // may be the one a build runs with.
                environment: {
                    [
                        ProcessInfo.processInfo.environment[RustupToolchainPolicy.environmentName],
                        LaunchdEnvironment.values[RustupToolchainPolicy.environmentName],
                    ].compactMap { $0 }
                },
                rustupIsRunning: { RustupToolchainPolicy.isRustupRunning() }
            )
        }
    }

    /// The pin files recorded by Dev Projects walks, two names in each folder.
    static let ledger = NvmrcLedger(
        fileURL: AppSupportFolder.url().appendingPathComponent("rust-toolchain-files.json"),
        limit: 10_000
    )

    /// Whether a process named `rustup` or `rustup-init` runs: an install, an
    /// update, or a component being added. True when the process list can't be
    /// read. A proxy such as `cargo` becomes the toolchain's own program, which
    /// `lsof` sees.
    static func isRustupRunning() -> Bool {
        guard let pids = ProcessWorkingDirectories.allProcessIDs() else { return true }
        return pids.contains { pid in
            guard let path = ProcessWorkingDirectories.executablePath(of: pid) else { return false }
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name == "rustup" || name == "rustup-init"
        }
    }

    // MARK: Gate

    /// Whether the toolchain folder at `path` is offered now, judged as far as `check` goes.
    static func isOffered(
        _ path: String,
        home: String,
        now: Date,
        context: Context,
        check: NvmNodeVersionPolicy.Check
    ) -> Bool {
        let url = URL(fileURLWithPath: path)
        let folder = url.lastPathComponent
        guard isToolchainPath(path, home: home),
              !PathContainment.containsSymlinkComponent(url, home: home),
              OldToolVersionScanPolicy.isRealFolder(path),
              isFinishedInstall(path, before: now.addingTimeInterval(-OldToolVersionScanPolicy.minimumLeftoverAge)),
              let kept = check == .quick
                ? recentKeptToolchains(home: home, context: context, now: now)
                : keptToolchains(home: home, context: context),
              !kept.contains(folder) else { return false }
        switch check {
        case .quick:
            return true
        case .scan, .move:
            guard let used = isUsedFromOutside(path, home: home, context: context), !used else { return false }
        }
        switch check {
        case .quick, .scan:
            return true
        case .move:
            // The process list first: it is the cheaper read.
            return !context.rustupIsRunning()
                && OpenFileCheck.check(folders: [url], lister: context.openFiles) == .free
        }
    }

    /// `FileDeleter`'s last check before it moves a toolchain: every rule
    /// again, the process list and `lsof` included. True for every other path,
    /// which other rules judge.
    static func passesImmediateTrashBoundary(
        _ url: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        now: Date = Date(),
        context: Context? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard isToolchainPath(path, home: home) else { return true }
        return isOffered(path, home: home, now: now, context: context ?? .current(home: home), check: .move)
    }

    /// Whether rustup installed the toolchain from a release manifest and last
    /// changed it before `cutoff`. rustup writes these records last, so a
    /// toolchain still being installed has none, and one that just gained a
    /// component or a target has a fresh one.
    static func isFinishedInstall(_ path: String, before cutoff: Date) -> Bool {
        guard OldToolVersionScanPolicy.isRegularFile("\(path)/\(releaseManifest)") else { return false }
        for record in installRecords {
            var info = stat()
            guard lstat("\(path)/\(record)", &info) == 0 else {
                if errno == ENOENT { continue }
                return false
            }
            guard Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < cutoff else { return false }
        }
        return true
    }

    private static let recentLock = NSLock()
    private nonisolated(unsafe) static var recent: [String: (at: Date, kept: Set<String>?)] = [:]

    /// `keptToolchains`, from a read in the last `NvmNodeVersionPolicy.recentReadLifetime`
    /// seconds when there is one. Only the main-thread gate uses it.
    static func recentKeptToolchains(home: String, context: Context, now: Date = Date()) -> Set<String>? {
        recentLock.lock()
        let cached = recent[home]
        recentLock.unlock()
        if let cached, now.timeIntervalSince(cached.at) < NvmNodeVersionPolicy.recentReadLifetime, now >= cached.at {
            return cached.kept
        }
        let kept = keptToolchains(home: home, context: context)
        recentLock.lock()
        recent[home] = (now, kept)
        recentLock.unlock()
        return kept
    }

    // MARK: What keeps a toolchain

    /// One place a toolchain may be named: the strings in it, its whole text,
    /// and the folder a relative path in it starts from.
    private struct Source {
        var strings: [String]
        var text: String = ""
        var folder: String?
    }

    /// The candidate folders in `~/.rustup/toolchains` nothing may remove now.
    /// Nil, which keeps every toolchain, when a source can't be read or understood.
    static func keptToolchains(home: String, context: Context) -> Set<String>? {
        let root = "\(home)/\(toolchainsRoot)"
        guard let candidates = candidateFolders(in: root) else { return nil }
        guard !candidates.isEmpty else { return [] }
        guard let sources = sources(home: home, context: context) else { return nil }
        var kept = Set<String>()
        for source in sources {
            for folder in candidates where !kept.contains(folder) {
                if source.strings.contains(where: { names($0, folder: folder) })
                    || NvmNodeVersionPolicy.names(source.text, versionFolder: folder, in: toolchainsRoot) {
                    kept.insert(folder)
                }
            }
            // A `path = ` in a pin file, and a path in `RUSTUP_TOOLCHAIN`.
            for string in source.strings where string.contains("/") {
                guard let pointed = folders(
                    reachedBy: string, from: source.folder, candidates: candidates, root: root, mayRead: context.mayRead
                ) else { return nil }
                kept.formUnion(pointed)
            }
        }
        // `rustup toolchain link` makes a link here. One may lead into a toolchain.
        for folder in candidates where !kept.contains(folder) {
            guard let linked = NvmNodeVersionPolicy.isLinkedFromBinFolder(
                "\(root)/\(folder)", home: home, linkFolders: [toolchainsRoot], mayRead: context.mayRead
            ) else { return nil }
            if linked { kept.insert(folder) }
        }
        return kept
    }

    /// The names in `root` that have the shape of a toolchain Purge may offer.
    /// Empty when rustup has none. Nil when the folder can't be listed.
    static func candidateFolders(in root: String) -> [String]? {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: root)
                .filter { offerableName(ofFolderName: $0) != nil }
        } catch {
            return NvmNodeVersionPolicy.isMissing(root) ? [] : nil
        }
    }

    /// rustup's settings, `RUSTUP_TOOLCHAIN`, and every pin file. Nil when one
    /// can't be read or understood.
    private static func sources(home: String, context: Context) -> [Source]? {
        // No settings file, another layout, or no default: Purge can't tell
        // what rustup runs, so every toolchain stays. With no default, every
        // use goes through the routes Purge sees least.
        let settings = "\(home)/\(settingsFile)"
        guard case .text(let text) = NvmNodeVersionPolicy.readPinFile(settings, home: home, mayRead: context.mayRead),
              let read = RustupTOML.read(text, tables: ["overrides"], allowsArrays: false),
              read.topLevel["version"] == [settingsVersion],
              let defaults = read.topLevel["default_toolchain"], defaults.count == 1,
              !defaults[0].trimmingCharacters(in: .whitespaces).isEmpty,
              read.otherTopLevelKeys.isDisjoint(with: ["version", "default_toolchain"]) else { return nil }
        var sources = [
            Source(strings: read.strings, text: text),
            Source(strings: context.environment()),
        ]

        guard let recorded = context.pinFiles() else { return nil }
        var checked = Set<String>()
        // rustup walks up from the folder it runs in, which may be home itself.
        let inHome = pinFileNames.map { "\(home)/\($0)" }
        for file in inHome + recorded where checked.insert(file).inserted {
            switch NvmNodeVersionPolicy.readPinFile(file, home: home, mayRead: context.mayRead) {
            case .absent:
                continue
            case .unknown:
                return nil
            case .text(let text):
                let isLegacy = URL(fileURLWithPath: file).lastPathComponent == "rust-toolchain"
                guard let strings = pinStrings(text, legacyNameAllowed: isLegacy) else { return nil }
                sources.append(Source(
                    strings: strings, text: text, folder: (file as NSString).deletingLastPathComponent
                ))
            }
        }
        return sources
    }

    /// Every string a pin file holds, the channel and any `path` among them.
    /// rustup reads `rust-toolchain` as a bare name when it is one line, and as
    /// TOML otherwise (`rust-toolchain.toml` always is). Both readings count.
    /// Nil when the text is neither.
    static func pinStrings(_ text: String, legacyNameAllowed: Bool) -> [String]? {
        let toml = RustupTOML.read(text, tables: ["toolchain"], allowsArrays: true)
        guard legacyNameAllowed else { return toml?.strings }
        guard !RustupTOML.hasUnreadableScalars(text) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if lines.isEmpty { return [] }
        if lines.count == 1 {
            return (toml?.strings ?? []) + [lines[0].trimmingCharacters(in: .whitespaces)]
        }
        return toml?.strings
    }

    /// The candidates the path in `value` is or leads into. Nil when macOS
    /// would ask about following it.
    private static func folders(
        reachedBy value: String, from folder: String?, candidates: [String], root: String,
        mayRead: (String) -> Bool
    ) -> Set<String>? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(fileURLWithPath: folder ?? "/", isDirectory: true)
        let path = URL(fileURLWithPath: trimmed, relativeTo: base).standardizedFileURL.path
        func reached(_ spellings: Set<String>) -> Set<String> {
            Set(candidates.filter { candidate in
                let targets = OldToolVersionScanPolicy.comparableSpellings(of: "\(root)/\(candidate)")
                return spellings.contains { spelling in targets.contains { PathContainment.isSameOrInside(spelling, $0) } }
            })
        }
        let asWritten = reached([path.lowercased()])
        // Following the path's own links reads it, which macOS may ask about.
        guard mayRead(path) else { return asWritten.isEmpty ? nil : asWritten }
        return asWritten.union(reached(OldToolVersionScanPolicy.comparableSpellings(of: path)))
    }

    /// Whether something outside rustup's own records uses the toolchain: a
    /// reference file, a link, or a dylint driver. Nil when one can't be read.
    static func isUsedFromOutside(_ path: String, home: String, context: Context) -> Bool? {
        let folder = URL(fileURLWithPath: path).lastPathComponent
        guard let name = offerableName(ofFolderName: folder) else { return nil }

        var files = referenceFiles.map { "\(home)/\($0)" }
        let agents = "\(home)/\(NvmNodeVersionPolicy.launchAgents)"
        guard context.mayRead(agents) else { return nil }
        do {
            files += try FileManager.default.contentsOfDirectory(atPath: agents)
                .filter { $0.hasSuffix(".plist") }
                .map { "\(agents)/\($0)" }
        } catch {
            guard NvmNodeVersionPolicy.isMissing(agents) else { return nil }
        }
        for file in files {
            guard context.mayRead(file) else { return nil }
            guard let data = FileManager.default.contents(atPath: file) else {
                if NvmNodeVersionPolicy.isMissing(file) { continue }
                return nil
            }
            guard let text = NvmNodeVersionPolicy.searchableText(data) else { return nil }
            if namesToolchain(text, folder: folder, release: name.release) { return true }
        }

        var folders = context.linkFolders
        let kani = "\(home)/\(kaniFolder)"
        guard context.mayRead(kani) else { return nil }
        do {
            let versions = try FileManager.default.contentsOfDirectory(atPath: kani)
            folders.append(kaniFolder)
            folders += versions
                .filter { OldToolVersionScanPolicy.isRealFolder("\(kani)/\($0)") }
                .map { "\(kaniFolder)/\($0)" }
        } catch {
            guard NvmNodeVersionPolicy.isMissing(kani) else { return nil }
        }
        guard let linked = NvmNodeVersionPolicy.isLinkedFromBinFolder(
            path, home: home, linkFolders: folders, mayRead: context.mayRead
        ) else { return nil }
        if linked { return true }

        var info = stat()
        if lstat("\(home)/\(dylintDrivers)/\(folder)", &info) == 0 { return true }
        return errno == ENOENT || errno == ENOTDIR ? false : nil
    }

    /// Whether a reference file's `text` names the toolchain: a path inside its
    /// folder, `+<release>` as cargo and rustc take it, or `RUSTUP_TOOLCHAIN`,
    /// whose value Purge doesn't try to read from a script.
    static func namesToolchain(_ text: String, folder: String, release: String) -> Bool {
        if NvmNodeVersionPolicy.names(text, versionFolder: folder, in: toolchainsRoot) { return true }
        let haystack = text.lowercased()
        if haystack.contains(environmentName.lowercased()) { return true }
        let needle = "+\(release.lowercased())"
        var searchFrom = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
            guard found.upperBound < haystack.endIndex else { return true }
            let next = haystack[found.upperBound]
            // `+1.84` is not `+1.84.0`. A `-` may start the host, so it counts.
            if !(next.isLetter || next.isNumber || next == "." || next == "_") { return true }
            searchFrom = found.upperBound
        }
        return false
    }

    // MARK: Scan

    /// The pin-file paths rustup reads for `roots`, for the ledger: each name in
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

/// The little TOML rustup's `settings.toml` and a `rust-toolchain` file use
/// (#406). The app has no TOML parser, and this is not one: it reads the plain
/// forms and calls everything else not understood, which keeps every toolchain.
///
/// It returns every string value in the file, whatever key or table holds it.
/// A string such as `"minimal"` or `"rustfmt"` can't name a toolchain folder,
/// so a value filed under the wrong table can't hide a pin.
nonisolated enum RustupTOML {

    nonisolated struct Read: Equatable, Sendable {
        /// Every string value, array members included.
        var strings: [String] = []
        /// The string values of bare keys above the first table.
        var topLevel: [String: [String]] = [:]
        /// Bare keys above the first table whose value is not a string.
        var otherTopLevelKeys: Set<String> = []
    }

    /// Reads `text`. Nil when it holds anything but comments, the named
    /// `tables`, and `key = value` lines whose value is a one-line string, a
    /// number, a boolean or, when allowed, an array of strings.
    static func read(_ text: String, tables: Set<String>, allowsArrays: Bool) -> Read? {
        // A multi-line string can hold a line that looks like a header or a key.
        guard !text.contains("\"\"\""), !text.contains("'''"), !hasUnreadableScalars(text) else { return nil }
        var cursor = Cursor(scalars: Array(text.unicodeScalars))
        var result = Read()
        var inTable = false

        while let scalar = cursor.current {
            if scalar == " " || scalar == "\t" {
                cursor.index += 1
            } else if scalar == "\n" || scalar == "\r" || scalar == "#" {
                guard cursor.endLine() else { return nil }
            } else if scalar == "[" {
                cursor.index += 1
                cursor.skipSpaces()
                let name = cursor.bareKey()
                cursor.skipSpaces()
                // `[[x]]`, a quoted or dotted name, and any other table are not read.
                guard cursor.current == "]", tables.contains(name) else { return nil }
                cursor.index += 1
                guard cursor.endLine() else { return nil }
                inTable = true
            } else {
                var key: String?
                if scalar == "\"" || scalar == "'" {
                    guard cursor.quoted() != nil else { return nil }
                } else {
                    let bare = cursor.bareKey()
                    guard !bare.isEmpty else { return nil }
                    key = bare
                }
                cursor.skipSpaces()
                // A dotted key (`toolchain.channel`) stops here.
                guard cursor.current == "=" else { return nil }
                cursor.index += 1
                cursor.skipSpaces()
                guard let value = cursor.value(allowsArrays: allowsArrays), cursor.endLine() else { return nil }
                result.strings += value
                if !inTable, let key {
                    if value.isEmpty {
                        result.otherTopLevelKeys.insert(key)
                    } else {
                        result.topLevel[key, default: []] += value
                    }
                }
            }
        }
        return result
    }

    /// A byte-order mark, a control character, or a line break TOML doesn't
    /// have but Swift splits on.
    static func hasUnreadableScalars(_ text: String) -> Bool {
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            // A carriage return counts only as part of a line break.
            if previous == "\r", scalar != "\n" { return true }
            previous = scalar
            switch scalar {
            case "\n", "\t", "\r":
                continue
            case "\u{FEFF}", "\u{85}", "\u{2028}", "\u{2029}", "\u{7F}":
                return true
            default:
                if scalar.value < 0x20 { return true }
            }
        }
        return previous == "\r"
    }

    private struct Cursor {
        let scalars: [Unicode.Scalar]
        var index = 0

        var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

        mutating func skipSpaces() {
            while let scalar = current, scalar == " " || scalar == "\t" { index += 1 }
        }

        /// Spaces, a comment if there is one, then the line's end or the text's.
        mutating func endLine() -> Bool {
            skipSpaces()
            if current == "#" {
                while let scalar = current, scalar != "\n" { index += 1 }
            }
            if current == "\r" { index += 1 }
            guard let scalar = current else { return true }
            guard scalar == "\n" else { return false }
            index += 1
            return true
        }

        mutating func bareKey() -> String {
            var key = String.UnicodeScalarView()
            while let scalar = current {
                switch scalar {
                case "a"..."z", "A"..."Z", "0"..."9", "_", "-":
                    key.append(scalar)
                    index += 1
                default:
                    return String(key)
                }
            }
            return String(key)
        }

        /// The one-line string at `index`, and whether it holds an escape. Nil
        /// when it never closes on its line.
        mutating func quoted() -> (text: String, escaped: Bool)? {
            guard let quote = current, quote == "\"" || quote == "'" else { return nil }
            index += 1
            var text = String.UnicodeScalarView()
            var escaped = false
            while let scalar = current {
                if scalar == quote {
                    index += 1
                    return (String(text), escaped)
                }
                if scalar == "\n" || scalar == "\r" { return nil }
                if scalar == "\\", quote == "\"" {
                    // The next character belongs to the escape, a `"` included.
                    escaped = true
                    index += 1
                    guard let next = current, next != "\n", next != "\r" else { return nil }
                    text.append(next)
                } else {
                    text.append(scalar)
                }
                index += 1
            }
            return nil
        }

        /// The strings in the value at `index`: one for a string, each member
        /// for an array, none for a number or a boolean. Nil for anything else,
        /// and for a string with an escape, which Purge doesn't decode.
        mutating func value(allowsArrays: Bool) -> [String]? {
            guard let scalar = current else { return nil }
            if scalar == "\"" || scalar == "'" {
                guard let string = quoted(), !string.escaped else { return nil }
                return [string.text]
            }
            if scalar == "[" {
                guard allowsArrays else { return nil }
                index += 1
                var members: [String] = []
                while true {
                    guard skipArrayGaps() else { return nil }
                    if current == "]" { break }
                    guard let string = quoted(), !string.escaped else { return nil }
                    members.append(string.text)
                    guard skipArrayGaps() else { return nil }
                    if current == "," {
                        index += 1
                    } else if current != "]" {
                        return nil
                    }
                }
                index += 1
                return members
            }
            // A number, a boolean or a date. An inline table (`{`) is not read.
            var count = 0
            while let scalar = current {
                switch scalar {
                case "a"..."z", "A"..."Z", "0"..."9", "+", "-", "_", ".", ":":
                    count += 1
                    index += 1
                default:
                    return count == 0 ? nil : []
                }
            }
            return count == 0 ? nil : []
        }

        /// Spaces, line breaks and comments between an array's members. False
        /// when the text ends inside the array.
        private mutating func skipArrayGaps() -> Bool {
            while let scalar = current {
                if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                    index += 1
                } else if scalar == "#" {
                    while let inComment = current, inComment != "\n" { index += 1 }
                } else {
                    return true
                }
            }
            return false
        }
    }
}
