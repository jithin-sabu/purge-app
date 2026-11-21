import Darwin
import Foundation

/// Old Python versions uv keeps in `~/.local/share/uv/python` (#405).
///
/// uv links each minor version to its newest patch
/// (`cpython-3.12-macos-aarch64-none` → `cpython-3.12.8-macos-aarch64-none`),
/// and `uv python upgrade` keeps the older patches next to it, since a virtual
/// environment may still use one. Only a CPython patch folder no such link
/// points at is ever a candidate. PyPy, GraalPy and Pyodide get no link.
///
/// A move to the Trash leaves uv nothing to set right. uv keeps no record of an
/// install outside its folder on macOS. Besides deleting the folder,
/// `uv python uninstall` removes the `bin` links that lead into it and points
/// the minor link at the newest patch left, and a candidate has neither: the
/// link already points at a newer patch, and a `bin` link into it keeps it.
/// `uv python install <version>` brings it back.
///
/// A candidate is offered only when nothing Purge can see still uses it:
///
/// - its minor link points at a newer patch of the same build (variant,
///   architecture), and no other link in the folder leads into it,
/// - uv finished installing it over a day ago,
/// - no `.python-version` names its version: the one in home, uv's global one,
///   or one beside a project a Dev Projects scan found or in a folder above it,
/// - no virtual environment uses it: those of uv's tools, pipx, Poetry,
///   `~/.virtualenvs`, `~/.venv`, and `.venv` or `venv` in each project. Their
///   `pyvenv.cfg` and `bin/python` name the folder they run from, and older uv
///   releases made them point at the patch folder, not the minor link,
/// - no LaunchAgent, editor, MCP or uv config, or shell startup file names a
///   path inside it or its folder name,
/// - no link in a `bin` folder points into it, and no program in `~/.cargo/bin`,
///   `~/.local/bin` or `~/bin` loads its `libpython`, which uv names by its
///   full path,
/// - and, right before the move, uv isn't running and no process has a file
///   open inside it.
///
/// The checks run in the same three places as nvm's (`NvmNodeVersionPolicy`).
/// Anything that can't be read or understood keeps every version. Only
/// `~/.local/share/uv/python` counts: an app started from Finder never sees
/// `UV_PYTHON_INSTALL_DIR` or `XDG_DATA_HOME`.
nonisolated enum UvPythonVersionPolicy {

    static let pythonRoot = ".local/share/uv/python"

    /// One row per version, labelled `uv Python <folder name>`. The whole
    /// folder name, so two builds of one version stay two rows.
    static let labelPrefix = "uv Python "
    static let explanationKey = "uv-python-version"

    static let variants: Set<String> = ["freethreaded", "debug", "freethreaded+debug", "gil", "gil+debug"]
    static let architectures: Set<String> = ["aarch64", "x86_64"]

    /// The file uv reads for a project's Python, in each folder from the project
    /// up to `/`, and the two it reads outside any project.
    static let pinFileName = ".python-version"
    static let homePinFiles = [".python-version", ".config/uv/.python-version"]

    static let venvConfigName = "pyvenv.cfg"
    /// The environments a project keeps, which uv and `python -m venv` make.
    static let projectVenvNames = [".venv", "venv"]
    /// Folders in home where each folder is an environment: uv's tools, pipx's
    /// (old and new place), virtualenvwrapper's, pipenv's, Poetry's and PDM's.
    static let venvFolders = [
        ".local/share/uv/tools",
        ".local/pipx/venvs",
        ".local/share/pipx/venvs",
        ".virtualenvs",
        ".local/share/virtualenvs",
        "Library/Caches/pypoetry/virtualenvs",
        "Library/Application Support/pdm/venvs",
    ]
    static let homeVenvs = [".venv"]

    /// Files that may name a Python path directly, relative to home: the ones
    /// nvm's rule reads, uv's own config, and Zed's.
    static let referenceFiles = NvmNodeVersionPolicy.referenceFiles + [
        ".config/uv/uv.toml", ".config/zed/settings.json",
    ]
    /// Files one level down that may name an interpreter: the SDK table of each
    /// JetBrains IDE, where PyCharm keeps the interpreters it knows, and each
    /// Jupyter kernel spec, whose `argv` starts with an interpreter path. As
    /// (folder in home, path inside each of its folders).
    static let referenceFilesInEachFolder = [
        ("Library/Application Support/JetBrains", "options/jdk.table.xml"),
        ("Library/Jupyter/kernels", "kernel.json"),
    ]
    /// `bin` folders where a link may point into a version, uv's own
    /// `~/.local/bin/python3.12` among them.
    static let linkFolders = NvmNodeVersionPolicy.linkFolders
    /// Where programs built against a Python live: `cargo install` for PyO3,
    /// and the two home `bin` folders.
    static let programFolders = [".cargo/bin", ".local/bin", "bin"]
    static let processNames: Set<String> = ["uv", "uvx"]

    // MARK: Names

    /// A patch folder's name as uv writes one:
    /// `cpython-<X.Y.Z>[<pre>][+<variant>]-macos-<arch>-none`.
    nonisolated struct Name: Equatable, Sendable {
        var major: Int
        var minor: Int
        var patch: Int
        /// `a1`, `b2`, `rc1`, or empty for a release.
        var prerelease: String
        /// `freethreaded`, `debug` and the like, or empty.
        var variant: String
        var arch: String

        /// `3.12.4`, `3.15.0a1`.
        var version: String { "\(major).\(minor).\(patch)\(prerelease)" }
        /// `3.12.4`, `3.13.1+freethreaded`.
        var request: String { variant.isEmpty ? version : "\(version)+\(variant)" }
        var folderName: String { "cpython-\(request)-macos-\(arch)-none" }
        /// The link uv keeps for this minor and build: `cpython-3.12-macos-aarch64-none`.
        var minorLinkName: String {
            "cpython-\(major).\(minor)\(variant.isEmpty ? "" : "+\(variant)")-macos-\(arch)-none"
        }

        /// Whether this is an earlier version than `other`. A release comes
        /// after its own pre-releases.
        func isOlder(than other: Name) -> Bool {
            if (major, minor, patch) != (other.major, other.minor, other.patch) {
                return (major, minor, patch) < (other.major, other.minor, other.patch)
            }
            func rank(_ pre: String) -> (Int, Int) {
                guard !pre.isEmpty else { return (3, 0) }
                let phase = pre.prefix { $0.isLetter }
                let number = Int(pre.dropFirst(phase.count)) ?? 0
                switch phase {
                case "a": return (0, number)
                case "b": return (1, number)
                default: return (2, number)
                }
            }
            return rank(prerelease) < rank(other.prerelease)
        }
    }

    /// The name of a CPython patch folder uv made for macOS. Nil for anything
    /// else: a minor link, another implementation, `.temp`, `.lock`.
    static func parse(folderName: String) -> Name? {
        let prefix = "cpython-"
        guard folderName.hasPrefix(prefix) else { return nil }
        let parts = folderName.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[1] == "macos", architectures.contains(String(parts[2])), parts[3] == "none"
        else { return nil }
        let versionAndVariant = parts[0]
        let version: Substring
        var variant = ""
        if let plus = versionAndVariant.firstIndex(of: "+") {
            version = versionAndVariant[..<plus]
            variant = String(versionAndVariant[versionAndVariant.index(after: plus)...])
            guard variants.contains(variant) else { return nil }
        } else {
            version = versionAndVariant
        }
        let numbers = version.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        func number(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.count <= 4, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(text)
        }
        let last = numbers[2]
        let patchDigits = last.prefix { $0.isASCII && $0.isNumber }
        let prerelease = String(last.dropFirst(patchDigits.count))
        if !prerelease.isEmpty {
            let phase = prerelease.prefix { $0.isLetter }
            guard ["a", "b", "rc"].contains(String(phase)), number(prerelease.dropFirst(phase.count)[...]) != nil
            else { return nil }
        }
        guard let major = number(numbers[0]), let minor = number(numbers[1]), let patch = number(patchDigits[...])
        else { return nil }
        let name = Name(
            major: major, minor: minor, patch: patch, prerelease: prerelease, variant: variant,
            arch: String(parts[2])
        )
        // `3.012.4` would read as `3.12.4`, which is another folder.
        return name.folderName == folderName ? name : nil
    }

    // MARK: Labels and shape

    /// The folder name in a row's label, or nil for any other label.
    static func folder(inLabel label: String) -> String? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        let folder = String(label.dropFirst(labelPrefix.count))
        return parse(folderName: folder) == nil ? nil : folder
    }

    /// Whether `path` is a patch folder that may be offered, by its place and
    /// name alone.
    static func isVersionPath(_ path: String, home: String) -> Bool {
        guard let folder = OldToolVersionScanPolicy.onlyChild(path, of: "\(home)/\(pythonRoot)") else { return false }
        return parse(folderName: folder) != nil
    }

    /// The architecture uv installs for by default on this Mac.
    static var hostArchitecture: String {
        #if arch(arm64)
        "aarch64"
        #else
        "x86_64"
        #endif
    }

    /// `3.12.4`, `3.13.1+freethreaded`, and `3.12.4 x86_64` for a build that
    /// isn't this Mac's own.
    static func displayVersion(ofFolderName folder: String) -> String {
        guard let name = parse(folderName: folder) else { return folder }
        return name.arch == hostArchitecture ? name.request : "\(name.request) \(name.arch)"
    }

    /// The command that brings the version back. The short request installs
    /// this Mac's own build; another one needs the whole key.
    static func reinstallCommand(forFolderName folder: String) -> String {
        guard let name = parse(folderName: folder), name.arch == hostArchitecture else {
            return "uv python install \(folder)"
        }
        return "uv python install \(name.request)"
    }

    // MARK: Context

    nonisolated struct Context: Sendable {
        /// The `.python-version` and `pyvenv.cfg` paths for the projects Dev
        /// Projects scans found, there or not, or nil before a full scan
        /// recorded them.
        var recordedFiles: @Sendable () -> [String]?
        /// Whether a file may be read without a macOS prompt. Tests allow everything.
        var mayRead: @Sendable (_ path: String) -> Bool
        /// The `lsof` listing, read only right before a move.
        var openFiles: OpenFileCheck.Lister
        /// Whether uv is at work, which may be inside a version. Asked only
        /// right before a move.
        var uvIsRunning: @Sendable () -> Bool
        /// The `bin` folders searched for links into a version. Tests use their own.
        var linkFolders: [String] = UvPythonVersionPolicy.linkFolders
        /// The folders whose programs may load a version's `libpython`.
        var programFolders: [String] = UvPythonVersionPolicy.programFolders

        /// `access` is worked out once here, not for each file: it probes Full
        /// Disk Access by opening folders.
        static func current(home: String, access: ScanAccess = ScanAccess.current()) -> Context {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            return Context(
                recordedFiles: { UvPythonVersionPolicy.ledger.files() },
                mayRead: { path in
                    ProtectedLocations.isReadable(URL(fileURLWithPath: path), access: access, home: homeURL)
                },
                openFiles: OpenFileCheck.liveListing,
                uvIsRunning: { OldToolVersionScanPolicy.isProcessRunning(named: UvPythonVersionPolicy.processNames) }
            )
        }
    }

    /// The `.python-version` and project `pyvenv.cfg` paths recorded by Dev
    /// Projects walks.
    static let ledger = NvmrcLedger(
        fileURL: AppSupportFolder.url().appendingPathComponent("uv-python-files.json"),
        limit: 10_000
    )

    // MARK: Gate

    /// Whether the version folder at `path` is offered now, judged as far as `check` goes.
    ///
    /// `knownKept` is `keptVersions` when the caller has just read it, so a scan
    /// reads the pins and environments once for all its versions.
    static func isOffered(
        _ path: String,
        home: String,
        now: Date,
        context: Context,
        check: NvmNodeVersionPolicy.Check,
        knownKept: Set<String>? = nil
    ) -> Bool {
        let url = URL(fileURLWithPath: path)
        let folder = url.lastPathComponent
        guard isVersionPath(path, home: home),
              let name = parse(folderName: folder),
              !PathContainment.containsSymlinkComponent(url, home: home),
              OldToolVersionScanPolicy.isRealFolder(path),
              isFinishedInstall(path, before: now.addingTimeInterval(-OldToolVersionScanPolicy.minimumLeftoverAge)),
              isBehindMinorLink(name, root: url.deletingLastPathComponent().path)
        else { return false }
        let kept: Set<String>?
        switch check {
        case .quick: kept = recentKeptVersions(home: home, context: context, now: now)
        case .scan: kept = knownKept ?? keptVersions(home: home, context: context)
        // A move trusts no earlier read.
        case .move: kept = keptVersions(home: home, context: context)
        }
        guard let kept, !kept.contains(folder) else { return false }
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
            // The process list first: it is the cheaper read. The link last, so
            // one uv moved onto this version meanwhile stops the move.
            return !context.uvIsRunning()
                && OpenFileCheck.check(folders: [url], lister: context.openFiles) == .free
                && isBehindMinorLink(name, root: url.deletingLastPathComponent().path)
        }
    }

    /// The version folders a scan offers, as paths. The keep set is read once.
    static func offeredFolders(home: String, now: Date, context: Context) -> [String] {
        let root = "\(home)/\(pythonRoot)"
        guard let candidates = candidateFolders(in: root), !candidates.isEmpty,
              let kept = keptVersions(home: home, context: context) else { return [] }
        return candidates
            .filter { !kept.contains($0) }
            .map { "\(root)/\($0)" }
            .filter { isOffered($0, home: home, now: now, context: context, check: .scan, knownKept: kept) }
            .sorted { OldToolVersionScanPolicy.isLower($0, than: $1) }
    }

    /// `FileDeleter`'s last check before it moves a version: every rule again,
    /// the process list and `lsof` included. True for every other path, which
    /// other rules judge.
    static func passesImmediateTrashBoundary(
        _ url: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        now: Date = Date(),
        context: Context? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard isVersionPath(path, home: home) else { return true }
        return isOffered(path, home: home, now: now, context: context ?? .current(home: home), check: .move)
    }

    /// Whether uv finished installing the version before `cutoff`. uv unpacks
    /// into `.temp` and renames the whole folder into place, so a finished
    /// install has its `bin/python3` and `lib`. Neither the folder nor anything
    /// directly in it may have changed since `cutoff`. Very old installs keep
    /// everything in an `install` folder.
    static func isFinishedInstall(_ path: String, before cutoff: Date) -> Bool {
        let base = OldToolVersionScanPolicy.isRealFolder("\(path)/install") ? "\(path)/install" : path
        var info = stat()
        guard lstat("\(base)/bin/python3", &info) == 0,
              OldToolVersionScanPolicy.isRealFolder("\(base)/lib") else { return false }
        return OldToolVersionScanPolicy.isUnchanged(path, before: cutoff)
    }

    /// Whether the minor link of `name`'s build points at a newer patch of that
    /// build, which is a real folder in `root`. False when there is no link, it
    /// points anywhere else, or it can't be read: then uv may still use this one.
    static func isBehindMinorLink(_ name: Name, root: String) -> Bool {
        let link = "\(root)/\(name.minorLinkName)"
        var info = stat()
        guard lstat(link, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return false }
        let resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: root, isDirectory: true))
            .standardizedFileURL
        // uv writes the patch folder's whole path. It must sit right in this folder.
        let parent = resolved.deletingLastPathComponent().path
        guard !OldToolVersionScanPolicy.comparableSpellings(of: parent)
                .isDisjoint(with: OldToolVersionScanPolicy.comparableSpellings(of: root)) else { return false }
        let targetFolder = resolved.lastPathComponent
        guard let linked = parse(folderName: targetFolder),
              linked.minorLinkName == name.minorLinkName,
              name.isOlder(than: linked),
              OldToolVersionScanPolicy.isRealFolder("\(root)/\(targetFolder)") else { return false }
        return true
    }

    private static let recentLock = NSLock()
    private nonisolated(unsafe) static var recent: [String: (at: Date, kept: Set<String>?)] = [:]

    /// `keptVersions`, from a read in the last `NvmNodeVersionPolicy.recentReadLifetime`
    /// seconds when there is one. Only the main-thread gate uses it.
    static func recentKeptVersions(home: String, context: Context, now: Date = Date()) -> Set<String>? {
        recentLock.lock()
        let cached = recent[home]
        recentLock.unlock()
        if let cached, now.timeIntervalSince(cached.at) < NvmNodeVersionPolicy.recentReadLifetime, now >= cached.at {
            return cached.kept
        }
        let kept = keptVersions(home: home, context: context)
        recentLock.lock()
        recent[home] = (now, kept)
        recentLock.unlock()
        return kept
    }

    // MARK: What keeps a version

    /// The candidate folders nothing may remove now: the ones a pin names, an
    /// environment runs from, or another link in uv's folder leads into. Nil,
    /// which keeps every version, when one of those can't be read.
    static func keptVersions(home: String, context: Context) -> Set<String>? {
        let root = "\(home)/\(pythonRoot)"
        guard let candidates = candidateFolders(in: root) else { return nil }
        guard !candidates.isEmpty else { return [] }
        guard let recorded = context.recordedFiles() else { return nil }
        var kept = Set<String>()

        // `.python-version` files. uv walks up from the folder it runs in,
        // which may be home itself.
        var checked = Set<String>()
        let pins = homePinFiles.map { "\(home)/\($0)" }
            + recorded.filter { URL(fileURLWithPath: $0).lastPathComponent == pinFileName }
        for file in pins where checked.insert(file).inserted {
            switch NvmNodeVersionPolicy.readPinFile(file, home: home, mayRead: context.mayRead) {
            case .absent:
                continue
            case .unknown:
                return nil
            case .text(let text):
                for folder in candidates where !kept.contains(folder) {
                    if pinNames(text, folder: folder) { kept.insert(folder) }
                }
                // uv also takes a path to an interpreter, which may be a link
                // into a version from anywhere.
                let pinFolder = (file as NSString).deletingLastPathComponent
                for request in requests(in: text) where request.contains("/") {
                    guard let reached = folders(reachedBy: request, from: pinFolder, candidates: candidates,
                                                root: root, mayRead: context.mayRead) else { return nil }
                    kept.formUnion(reached)
                }
            }
        }

        // Virtual environments.
        guard let venvs = environmentFolders(home: home, recorded: recorded, mayRead: context.mayRead) else {
            return nil
        }
        for venv in venvs where checked.insert(venv).inserted {
            guard let used = versionsUsed(byEnvironment: venv, candidates: candidates, root: root, home: home,
                                          mayRead: context.mayRead) else { return nil }
            kept.formUnion(used)
        }

        // A link in uv's folder other than the minor link of the version's own
        // build, which `isBehindMinorLink` already judged.
        for folder in candidates where !kept.contains(folder) {
            guard let linked = NvmNodeVersionPolicy.isLinkedFromBinFolder(
                "\(root)/\(folder)", home: home, linkFolders: [pythonRoot], mayRead: context.mayRead
            ) else { return nil }
            if linked { kept.insert(folder) }
        }
        return kept
    }

    /// The patch folders in `root`. Empty when uv has none. Nil when the folder
    /// can't be listed, or a patch name there is a link, which uv never makes.
    static func candidateFolders(in root: String) -> [String]? {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            return NvmNodeVersionPolicy.isMissing(root) ? [] : nil
        }
        var found: [String] = []
        for name in names where parse(folderName: name) != nil {
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

    /// Whether a `.python-version`'s `text` names the version: its version
    /// number with no digit or `.` on either side (`3.12.4`, `cpython-3.12.4`,
    /// `3.12.4+freethreaded`), or a path inside its folder. The number alone
    /// keeps every build of it, which errs on keeping. A version range
    /// (`>=3.12.3,<3.12.5`) may be met by this version alone, and Purge doesn't
    /// work ranges out, so one keeps every version.
    static func pinNames(_ text: String, folder: String) -> Bool {
        guard let name = parse(folderName: folder) else { return true }
        if NvmNodeVersionPolicy.names(text, versionFolder: folder, in: pythonRoot) { return true }
        if requests(in: text).contains(where: { $0.contains(where: rangeCharacters.contains) }) { return true }
        return containsVersion(name.version.lowercased(), in: text.lowercased())
    }

    /// What marks a version range or a wildcard in a request.
    static let rangeCharacters: Set<Character> = ["<", ">", "=", "~", "!", "*", ","]

    /// The requests in a `.python-version`: one per line, without comments,
    /// blank lines and surrounding spaces.
    static func requests(in text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Whether `version` stands in `text` with no digit or `.` before or after
    /// it. So `3.12` is not `3.12.4`, and `3.12.4` is not `3.12.40` or `13.12.4`.
    static func containsVersion(_ version: String, in text: String) -> Bool {
        guard !version.isEmpty else { return false }
        func isVersionPart(_ character: Character) -> Bool {
            (character.isASCII && character.isNumber) || character == "."
        }
        var searchFrom = text.startIndex
        while let found = text.range(of: version, range: searchFrom..<text.endIndex) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !(before.map(isVersionPart) ?? false), !(after.map(isVersionPart) ?? false) { return true }
            searchFrom = text.index(after: found.lowerBound)
        }
        return false
    }

    /// Every environment folder Purge reads: the projects' from the ledger,
    /// `~/.venv`, and each folder in `venvFolders`. Nil when one of those
    /// folders is there but can't be listed.
    static func environmentFolders(home: String, recorded: [String], mayRead: (String) -> Bool) -> [String]? {
        var folders = recorded
            .filter { URL(fileURLWithPath: $0).lastPathComponent == venvConfigName }
            .map { ($0 as NSString).deletingLastPathComponent }
        folders += homeVenvs.map { "\(home)/\($0)" }
        for relative in venvFolders {
            let folder = "\(home)/\(relative)"
            guard mayRead(folder) else { return nil }
            do {
                folders += try FileManager.default.contentsOfDirectory(atPath: folder)
                    .filter { !$0.hasPrefix(".") }
                    .map { "\(folder)/\($0)" }
            } catch {
                guard NvmNodeVersionPolicy.isMissing(folder) else { return nil }
            }
        }
        return folders
    }

    /// The candidates the environment at `venv` runs from: a path in its
    /// `pyvenv.cfg` (`home`, `executable`, `base-executable` and the like) or
    /// its `bin/python` link that is or leads into one. Empty when there is no
    /// environment there. Nil when one is there but can't be read.
    static func versionsUsed(
        byEnvironment venv: String, candidates: [String], root: String, home: String, mayRead: (String) -> Bool
    ) -> Set<String>? {
        var used = Set<String>()
        let config = "\(venv)/\(venvConfigName)"
        switch NvmNodeVersionPolicy.readPinFile(config, home: home, mayRead: mayRead) {
        case .absent:
            break
        case .unknown:
            return nil
        case .text(let text):
            for folder in candidates where NvmNodeVersionPolicy.names(text, versionFolder: folder, in: pythonRoot) {
                used.insert(folder)
            }
            for line in text.unicodeScalars.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let entry = String(String.UnicodeScalarView(line))
                guard let equals = entry.firstIndex(of: "=") else { continue }
                let value = entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                guard value.contains("/") else { continue }
                guard let reached = folders(reachedBy: value, from: venv, candidates: candidates, root: root,
                                            mayRead: mayRead) else { return nil }
                used.formUnion(reached)
            }
        }
        // `bin/python` leads to the interpreter the environment runs.
        let bin = "\(venv)/bin"
        guard mayRead(bin) else { return nil }
        let python = "\(bin)/python"
        var info = stat()
        if lstat(python, &info) != 0 {
            // Only a missing link is no link.
            guard errno == ENOENT || errno == ENOTDIR else { return nil }
        } else if (info.st_mode & S_IFMT) == S_IFLNK {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: python),
                  let reached = folders(reachedBy: target, from: bin, candidates: candidates, root: root,
                                        mayRead: mayRead) else { return nil }
            used.formUnion(reached)
        }
        return used
    }

    /// The candidates the path in `value` is or leads into, read from `folder`
    /// when it is relative. Nil when macOS would ask about following it.
    private static func folders(
        reachedBy value: String, from folder: String, candidates: [String], root: String,
        mayRead: (String) -> Bool
    ) -> Set<String>? {
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        let path = URL(fileURLWithPath: value, relativeTo: base).standardizedFileURL.path
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

    /// Whether something outside uv's own folder uses the version: a reference
    /// file, a `bin` link, or a program that loads its `libpython`. Nil when
    /// one can't be read.
    static func isUsedFromOutside(_ path: String, home: String, context: Context) -> Bool? {
        let folder = URL(fileURLWithPath: path).lastPathComponent
        var files = referenceFiles.map { "\(home)/\($0)" }
        for (parent, inside) in referenceFilesInEachFolder {
            let parentPath = "\(home)/\(parent)"
            guard context.mayRead(parentPath) else { return nil }
            do {
                files += try FileManager.default.contentsOfDirectory(atPath: parentPath)
                    .filter { !$0.hasPrefix(".") }
                    .map { "\(parentPath)/\($0)/\(inside)" }
            } catch {
                guard NvmNodeVersionPolicy.isMissing(parentPath) else { return nil }
            }
        }
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
            if NvmNodeVersionPolicy.names(text, versionFolder: folder, in: pythonRoot)
                || text.lowercased().contains(folder.lowercased()) { return true }
        }

        guard let linked = NvmNodeVersionPolicy.isLinkedFromBinFolder(
            path, home: home, linkFolders: context.linkFolders, mayRead: context.mayRead
        ) else { return nil }
        if linked { return true }

        // uv sets `libpython`'s install name to its full path in the patch
        // folder, so a program linked against it names the folder.
        return OldToolVersionScanPolicy.programHeaders(
            in: context.programFolders, home: home, mayRead: context.mayRead,
            contain: [Data("\(folder)/".utf8)]
        )
    }

    // MARK: Scan

    /// The paths uv reads for `roots`, for the ledger: `.python-version` in each
    /// project and every folder above it, up to `/`, and the `pyvenv.cfg` of each
    /// project's `.venv` and `venv`, and of any other folder in the project that
    /// holds one now (`UV_PROJECT_ENVIRONMENT` may name another). Each default
    /// is listed whether a file is there now or not, so one added after the
    /// scan still counts at the move.
    static func recordedFiles(inProjectRoots roots: [URL]) -> [String] {
        let pins = NvmNodeVersionPolicy.nvmrcFiles(inProjectRoots: roots).map { nvmrc -> String in
            let folder = (nvmrc as NSString).deletingLastPathComponent
            return folder == "/" ? "/\(pinFileName)" : "\(folder)/\(pinFileName)"
        }
        var seen = Set<String>()
        let venvs = roots.flatMap { root -> [String] in
            let path = root.standardizedFileURL.path
            let others = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
                .map { "\(path)/\($0)/\(venvConfigName)" }
                .filter { OldToolVersionScanPolicy.isRegularFile($0) }
                .sorted()
            return projectVenvNames.map { "\(path)/\($0)/\(venvConfigName)" } + others
        }
        return (pins + venvs).filter { seen.insert($0).inserted }
    }
}
