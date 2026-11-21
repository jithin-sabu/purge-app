import Darwin
import Foundation

/// Old Python versions pyenv keeps in `~/.pyenv/versions` (#404).
///
/// pyenv keeps every Python it built until you remove it by hand, and its own
/// `uninstall` only deletes the version's folder. A move to the Trash does the
/// same and can be undone. `pyenv install <version>` builds it again.
///
/// Only a plain CPython release (`3.11.9`) is ever a candidate. `system`, a
/// development build (`3.14-dev`), a prerelease, a free-threaded build
/// (`3.13.0t`), PyPy, conda, GraalPy and a pyenv-virtualenv link never are.
///
/// A candidate is offered only when nothing Purge can see still uses it:
///
/// - pyenv finished building it, and it hasn't changed for a day,
/// - it is not the newest installed release of its minor (`3.11`),
/// - `~/.pyenv/version`, `PYENV_VERSION` (Purge's environment or launchd's,
///   read again right before the move), `~/.python-version` and every
///   `.python-version` beside a project a Dev Projects scan found, or in a
///   folder above one, don't name it the way pyenv resolves a name,
/// - it holds no pyenv-virtualenv environment (`envs`), and no link in
///   `~/.pyenv/versions` leads into it,
/// - no virtual environment Purge can find runs from it: those beside each
///   project, and those of uv's tools, pipx, Poetry, Hatch, pipenv, pdm and
///   virtualenvwrapper. A `pyvenv.cfg` names the Python it runs from,
/// - it holds no package or command besides what pyenv's build ships,
/// - no LaunchAgent, editor, MCP, Jupyter kernel or PyCharm config, or shell
///   startup file names a path inside it or its version as a word, or holds
///   `PYENV_VERSION`, and no link in a `bin` folder points into it,
/// - its Python hasn't run for 90 days. Starting it maps its program and its
///   extension modules, which moves their access times, so a virtual
///   environment anywhere on the Mac that still runs it keeps it,
/// - and, right before the move, no process has a file open inside it.
///
/// The checks run in the same three places as nvm's (`NvmNodeVersionPolicy`).
/// Anything that can't be read or understood keeps every version. Only
/// `~/.pyenv` counts: an app started from Finder never sees `PYENV_ROOT`.
nonisolated enum PyenvPythonVersionPolicy {

    static let versionsRoot = ".pyenv/versions"
    /// The global version file pyenv reads when no `.python-version` applies.
    /// pyenv 2 reads only `version`. Older releases also read `global` and
    /// `default`, which may still be there, so those count too.
    static let globalVersionFiles = [".pyenv/version", ".pyenv/global", ".pyenv/default"]
    static let pinFileName = ".python-version"
    static let environmentName = "PYENV_VERSION"

    /// One row per version, labelled `pyenv Python <version>`.
    static let labelPrefix = "pyenv Python "
    static let explanationKey = "pyenv-python-version"

    /// A version whose Python ran more recently than this stays.
    static let unusedAge: TimeInterval = 90 * 24 * 60 * 60

    static let venvConfigName = "pyvenv.cfg"
    /// The environments a project keeps, which `python -m venv`, uv and
    /// Poetry's in-project setting make. Recorded whether they are there or not.
    static let projectVenvNames = [".venv", "venv"]
    /// Folders in a project that hold one environment per folder: tox's and nox's.
    static let projectVenvGroups = [".tox", ".nox"]
    /// Folders in home where each folder is an environment: uv's tools, pipx's
    /// (all three places it has used), virtualenvwrapper's, Poetry's,
    /// pipenv's and pdm's.
    static let venvFolders = [
        ".local/share/uv/tools",
        ".local/pipx/venvs",
        ".local/share/pipx/venvs",
        "Library/Application Support/pipx/venvs",
        ".virtualenvs",
        "Library/Caches/pypoetry/virtualenvs",
        ".local/share/virtualenvs",
        "Library/Application Support/pdm/venvs",
    ]
    /// Single environments in home: one made there, and pipx's shared one.
    static let homeVenvs = [
        ".venv",
        ".local/pipx/shared",
        ".local/share/pipx/shared",
        "Library/Application Support/pipx/shared",
    ]
    /// Hatch keeps `<project>/<id>/<environment>` here.
    static let hatchVenvRoot = "Library/Application Support/hatch/env/virtual"
    static let hatchVenvDepth = 3

    /// Files that may name a Python path or version, relative to home: the
    /// ones nvm's rule reads and Zed's.
    static let referenceFiles = NvmNodeVersionPolicy.referenceFiles + [".config/zed/settings.json"]
    /// Jupyter keeps `<kernel>/kernel.json` here, whose `argv` names a Python.
    static let jupyterKernels = "Library/Jupyter/kernels"
    /// PyCharm and the other JetBrains IDEs keep `<product>/options/jdk.table.xml`
    /// here, which lists the interpreters a project may use.
    static let jetBrainsRoot = "Library/Application Support/JetBrains"
    static let jetBrainsInterpreters = "options/jdk.table.xml"
    /// `bin` folders where a link may point into a version.
    static let linkFolders = NvmNodeVersionPolicy.linkFolders

    /// What pyenv's build puts in `bin`: the interpreter, pip, IDLE, pydoc,
    /// 2to3 and `python-config`, each with and without its version.
    static let shippedCommandPrefixes = ["python", "pip", "idle", "pydoc", "2to3"]
    /// What `ensurepip` puts in `site-packages`. Older releases also bring
    /// setuptools, with `_distutils_hack`, `pkg_resources` and a `.pth`.
    static let shippedPackages: Set<String> = ["pip", "setuptools", "wheel"]
    static let shippedSitePackagesEntries: Set<String> = [
        "pip", "setuptools", "wheel", "_distutils_hack", "pkg_resources",
        "distutils-precedence.pth", "README.txt", "__pycache__",
    ]

    // MARK: Names and labels

    /// `3.11.9` → `3.11.9`. Nil for any other folder name.
    static func version(ofFolderName name: String) -> String? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, OldToolVersionScanPolicy.isDottedVersion(name) else { return nil }
        return name
    }

    /// `3.11.9` → `3.11`.
    static func minor(of version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// The version in a row's label, or nil for any other label.
    static func version(inLabel label: String) -> String? {
        guard label.hasPrefix(labelPrefix) else { return nil }
        return version(ofFolderName: String(label.dropFirst(labelPrefix.count)))
    }

    static func reinstallCommand(forVersion version: String) -> String {
        "pyenv install \(version)"
    }

    /// Whether `path` is a version folder Purge may offer, by its place and name.
    static func isVersionPath(_ path: String, home: String) -> Bool {
        guard let name = OldToolVersionScanPolicy.onlyChild(path, of: "\(home)/\(versionsRoot)") else { return false }
        return version(ofFolderName: name) != nil
    }

    // MARK: Context

    nonisolated struct Context: Sendable {
        /// The `.python-version` and project `pyvenv.cfg` paths recorded by Dev
        /// Projects scans, there or not, or nil before a full scan recorded them.
        var recordedFiles: @Sendable () -> [String]?
        /// Whether a file may be read without a macOS prompt. Tests allow everything.
        var mayRead: @Sendable (_ path: String) -> Bool
        /// The `lsof` listing, read only right before a move.
        var openFiles: OpenFileCheck.Lister
        /// Every `PYENV_VERSION` value Purge can see, or nil when one couldn't
        /// be read. `fresh` asks launchd again, which only a move does.
        var environment: @Sendable (_ fresh: Bool) -> [String]?
        /// The `bin` folders searched for links into a version. Tests use their own.
        var linkFolders: [String] = PyenvPythonVersionPolicy.linkFolders

        /// `access` is worked out once here, not for each file: it probes Full
        /// Disk Access by opening folders.
        static func current(home: String, access: ScanAccess = ScanAccess.current()) -> Context {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            return Context(
                recordedFiles: { PyenvPythonVersionPolicy.ledger.files() },
                mayRead: { path in
                    ProtectedLocations.isReadable(URL(fileURLWithPath: path), access: access, home: homeURL)
                },
                openFiles: OpenFileCheck.liveListing,
                // Both the value Purge was started with and launchd's. A launchd
                // read that failed is not an unset variable.
                environment: { fresh in
                    let name = PyenvPythonVersionPolicy.environmentName
                    var values = [ProcessInfo.processInfo.environment[name]].compactMap { $0 }
                    switch fresh ? LaunchdEnvironment.readNow(name) : LaunchdEnvironment.lastRead(name) {
                    case .value(let value): values.append(value)
                    case .unset: break
                    case .failed: return nil
                    }
                    return values
                }
            )
        }
    }

    /// The `.python-version` and project `pyvenv.cfg` paths recorded by Dev
    /// Projects walks.
    static let ledger = NvmrcLedger(
        fileURL: AppSupportFolder.url().appendingPathComponent("pyenv-files.json"),
        limit: 10_000
    )

    // MARK: Gate

    /// Whether the version folder at `path` is offered now, judged as far as `check` goes.
    ///
    /// `knownKept` is `keptVersions` when the caller has just read it, so a
    /// scan reads the version files and environments once for all versions.
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
              !PathContainment.containsSymlinkComponent(url, home: home),
              OldToolVersionScanPolicy.isRealFolder(path),
              isFinishedInstall(path, before: now.addingTimeInterval(-OldToolVersionScanPolicy.minimumLeftoverAge)),
              !hasEnvironments(path),
              !hasAddedPackages(path),
              !ranRecently(path, now: now)
        else { return false }
        let kept: Set<String>?
        switch check {
        case .quick: kept = recentKeptVersions(home: home, context: context, now: now)
        case .scan: kept = knownKept ?? keptVersions(home: home, context: context)
        // A move trusts no earlier read, launchd's included.
        case .move: kept = keptVersions(home: home, context: context, fresh: true)
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
            return OpenFileCheck.check(folders: [url], lister: context.openFiles) == .free
        }
    }

    /// The version folders a scan offers, as paths. The keep set is read once.
    static func offeredFolders(home: String, now: Date, context: Context) -> [String] {
        let root = "\(home)/\(versionsRoot)"
        guard let installed = installedNames(in: root) else { return [] }
        let candidates = candidateFolders(installed, root: root)
        guard !candidates.isEmpty, let kept = keptVersions(home: home, context: context) else { return [] }
        return candidates
            .filter { !kept.contains($0) }
            .map { "\(root)/\($0)" }
            .filter { isOffered($0, home: home, now: now, context: context, check: .scan, knownKept: kept) }
            .sorted { OldToolVersionScanPolicy.isLower($0, than: $1) }
    }

    /// `FileDeleter`'s last check before it moves a pyenv version: every rule
    /// again, `lsof` included. True for every other path, which other rules judge.
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

    /// Whether pyenv finished building the version and nothing in it changed
    /// since `cutoff`. pyenv builds elsewhere and installs into the folder at
    /// the end, and deletes the folder when a build fails. A `bin/python3` is
    /// the last thing a finished install has, and a `pip install` into the
    /// version changes `bin` or `lib`.
    static func isFinishedInstall(_ path: String, before cutoff: Date) -> Bool {
        var info = stat()
        guard lstat("\(path)/bin/python3", &info) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFLNK else { return false }
        return OldToolVersionScanPolicy.isUnchanged(path, before: cutoff)
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

    /// The candidate folders nothing may remove now: the newest of each minor,
    /// every version a version file or `PYENV_VERSION` names, any a link in
    /// `~/.pyenv/versions` leads into, and any an environment runs from. Nil,
    /// which keeps every version, when a source can't be read or understood.
    /// `fresh` reads launchd's `PYENV_VERSION` again, which only a move does.
    static func keptVersions(home: String, context: Context, fresh: Bool = false) -> Set<String>? {
        let root = "\(home)/\(versionsRoot)"
        guard let installed = installedNames(in: root) else { return nil }
        let candidates = candidateFolders(installed, root: root)
        guard !candidates.isEmpty else { return [] }

        var kept = Set<String>()
        var newestOfMinor: [String: String] = [:]
        for version in candidates {
            let minor = minor(of: version)
            if let current = newestOfMinor[minor], !OldToolVersionScanPolicy.isLower(current, than: version) { continue }
            newestOfMinor[minor] = version
        }
        kept.formUnion(newestOfMinor.values)

        guard let recorded = context.recordedFiles() else { return nil }
        // pyenv walks up from the folder it runs in, which may be home itself,
        // and falls back to its global file.
        let pins = globalVersionFiles.map { "\(home)/\($0)" } + ["\(home)/\(pinFileName)"]
            + recorded.filter { URL(fileURLWithPath: $0).lastPathComponent == pinFileName }
        var checked = Set<String>()
        for file in pins where checked.insert(file).inserted {
            switch NvmNodeVersionPolicy.readPinFile(file, home: home, mayRead: context.mayRead) {
            case .absent:
                continue
            case .unknown:
                return nil
            case .text(let text):
                for word in versionFileWords(text) {
                    guard let named = resolve(word, installed: installed) else { return nil }
                    kept.formUnion(named)
                }
            }
        }

        guard let environment = context.environment(fresh) else { return nil }
        for value in environment {
            for word in value.split(separator: ":").map(String.init) {
                guard let named = resolve(word, installed: installed) else { return nil }
                kept.formUnion(named)
            }
        }

        // A pyenv-virtualenv name is a link here into `<version>/envs/<name>`.
        for folder in candidates where !kept.contains(folder) {
            guard let linked = NvmNodeVersionPolicy.isLinkedFromBinFolder(
                "\(root)/\(folder)", home: home, linkFolders: [versionsRoot], mayRead: context.mayRead
            ) else { return nil }
            if linked { kept.insert(folder) }
        }

        guard let environments = environmentFolders(home: home, recorded: recorded, mayRead: context.mayRead)
        else { return nil }
        var seen = Set<String>()
        for venv in environments where seen.insert(venv).inserted {
            guard let used = versionsUsed(
                byEnvironment: venv, candidates: candidates, root: root, home: home, mayRead: context.mayRead
            ) else { return nil }
            kept.formUnion(used)
        }
        return kept
    }

    /// Every name in `~/.pyenv/versions`, hidden ones left out, whatever it is.
    /// Empty when pyenv has no versions. Nil when the folder can't be listed.
    static func installedNames(in root: String) -> [String]? {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: root).filter { !$0.hasPrefix(".") }
        } catch {
            return NvmNodeVersionPolicy.isMissing(root) ? [] : nil
        }
    }

    /// The installed names with a candidate's shape that are real folders.
    static func candidateFolders(_ installed: [String], root: String) -> [String] {
        installed.filter { version(ofFolderName: $0) != nil && OldToolVersionScanPolicy.isRealFolder("\(root)/\($0)") }
    }

    /// The names a version file holds, as pyenv reads one: the first word of
    /// each line, empty lines and `#` comments left out. A carriage return is
    /// space to pyenv.
    static func versionFileWords(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let words = String(String.UnicodeScalarView(line))
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\r\n" })
            guard let first = words.first, !first.hasPrefix("#") else { return nil }
            return String(first)
        }
    }

    /// The installed names `word` selects the way pyenv resolves it: `system`
    /// selects none, an installed name itself, `3.12.4/envs/name` the version
    /// it is in, and anything else the newest release it is a prefix of
    /// (`3.11` → `3.11.9`), as `pyenv latest` picks one. A `python-` prefix is
    /// tried with and without. Nil for a name that climbs out of the folder,
    /// which Purge doesn't follow.
    static func resolve(_ word: String, installed: [String]) -> Set<String>? {
        let value = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "system" else { return [] }
        var spellings = [value]
        if value.hasPrefix("python-") { spellings.append(String(value.dropFirst("python-".count))) }
        var selected = Set<String>()
        for spelling in spellings {
            if spelling.contains("/") || spelling == ".." || spelling == "." {
                let parts = spelling.split(separator: "/", omittingEmptySubsequences: false)
                guard let first = parts.first, !first.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." })
                else { return nil }
                selected.insert(String(first))
            } else if installed.contains(spelling) {
                selected.insert(spelling)
            } else if let newest = newest(matchingPrefix: spelling, in: installed) {
                selected.insert(newest)
            }
        }
        return selected
    }

    /// The newest installed name that starts with `prefix` and a `.` or `-`,
    /// leaving out development builds, prereleases and free-threaded builds,
    /// as `pyenv latest` does. A prefix ending in `t` after a digit picks among
    /// the free-threaded builds instead.
    static func newest(matchingPrefix prefix: String, in installed: [String]) -> String? {
        var stem = prefix
        var wantsFreeThreaded = false
        if prefix.count > 1, prefix.hasSuffix("t"),
           let beforeT = prefix.dropLast().last, beforeT.isASCII, beforeT.isNumber {
            stem = String(prefix.dropLast())
            wantsFreeThreaded = true
        }
        let matching = installed.filter { name in
            guard name.hasPrefix(stem + ".") || name.hasPrefix(stem + "-") else { return false }
            if name.hasSuffix("-dev") || name.hasSuffix("-src") || name.hasSuffix("-latest") { return false }
            if isPrerelease(name) { return false }
            return isFreeThreaded(name) == wantsFreeThreaded
        }
        return matching.max { OldToolVersionScanPolicy.isLower($0, than: $1) }
    }

    /// `3.14.0rc1`, `3.14.0a3t`: letters `a`, `b` or `rc` and digits at the end.
    static func isPrerelease(_ name: String) -> Bool {
        var rest = Substring(name)
        if rest.hasSuffix("t") { rest = rest.dropLast() }
        let digits = rest.reversed().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return false }
        rest = rest.dropLast(digits.count)
        return rest.hasSuffix("rc") || rest.hasSuffix("a") || rest.hasSuffix("b")
    }

    /// `3.13.0t`: a digit, then `t`, at the end.
    static func isFreeThreaded(_ name: String) -> Bool {
        guard name.hasSuffix("t"), let beforeT = name.dropLast().last else { return false }
        return beforeT.isASCII && beforeT.isNumber
    }

    /// Whether the version holds a pyenv-virtualenv environment. Its
    /// `~/.pyenv/versions/<name>` link points into it, so the link would break.
    /// True when `envs` can't be read.
    static func hasEnvironments(_ versionPath: String) -> Bool {
        let envs = "\(versionPath)/envs"
        do {
            return try FileManager.default.contentsOfDirectory(atPath: envs).contains { !$0.hasPrefix(".") }
        } catch {
            return !NvmNodeVersionPolicy.isMissing(envs)
        }
    }

    /// Whether the version holds a command or package besides what pyenv's
    /// build and `ensurepip` put there: something `pip install` added outside
    /// a virtual environment, which `pyenv install` doesn't bring back. True
    /// when `bin` or `site-packages` can't be read.
    static func hasAddedPackages(_ versionPath: String) -> Bool {
        guard let version = version(ofFolderName: URL(fileURLWithPath: versionPath).lastPathComponent) else {
            return true
        }
        let bin = "\(versionPath)/bin"
        guard let commands = try? FileManager.default.contentsOfDirectory(atPath: bin) else { return true }
        let addedCommand = commands.contains { name in
            !name.hasPrefix(".") && !shippedCommandPrefixes.contains(where: { name.hasPrefix($0) })
        }
        if addedCommand { return true }
        let sitePackages = "\(versionPath)/lib/python\(minor(of: version))/site-packages"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: sitePackages) else { return true }
        return entries.contains { name in
            if name.hasPrefix(".") || shippedSitePackagesEntries.contains(name) { return false }
            // `pip-24.0.dist-info`: the record of a shipped package.
            if name.hasSuffix(".dist-info"),
               let dash = name.firstIndex(of: "-"),
               shippedPackages.contains(String(name[..<dash])) {
                return false
            }
            return true
        }
    }

    /// Whether the version's Python ran since `now - unusedAge`: the latest
    /// access or change of its programs in `bin`, its `libpython`, and its
    /// extension modules in `lib-dynload`. Starting Python maps its program,
    /// and an environment's `python` is a link to it, so either moves the
    /// access time. True when any of them can't be read, or none is there.
    static func ranRecently(_ versionPath: String, now: Date) -> Bool {
        guard let version = version(ofFolderName: URL(fileURLWithPath: versionPath).lastPathComponent) else {
            return true
        }
        let cutoff = now.addingTimeInterval(-unusedAge)
        var newest: Date?
        func note(_ folder: String, where include: (String) -> Bool) -> Bool {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder)
            } catch {
                return NvmNodeVersionPolicy.isMissing(folder)
            }
            for name in names where include(name) {
                var info = stat()
                guard lstat("\(folder)/\(name)", &info) == 0 else { return false }
                // A link's own times say nothing about its target's use.
                guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
                let accessed = TimeInterval(info.st_atimespec.tv_sec)
                let changed = TimeInterval(info.st_mtimespec.tv_sec)
                let latest = Date(timeIntervalSince1970: max(accessed, changed))
                newest = max(newest ?? latest, latest)
            }
            return true
        }
        guard note("\(versionPath)/bin", where: { $0.hasPrefix("python") }),
              note("\(versionPath)/lib", where: { $0.hasPrefix("libpython") }),
              note("\(versionPath)/lib/python\(minor(of: version))/lib-dynload", where: { $0.hasSuffix(".so") }),
              let newest else { return true }
        return newest >= cutoff
    }

    // MARK: Virtual environments

    /// Every environment folder Purge reads: the projects' from the ledger,
    /// those in home, each folder in `venvFolders`, and Hatch's. Nil when one
    /// of those folders is there but can't be listed.
    static func environmentFolders(home: String, recorded: [String], mayRead: (String) -> Bool) -> [String]? {
        var folders = recorded
            .filter { URL(fileURLWithPath: $0).lastPathComponent == venvConfigName }
            .map { ($0 as NSString).deletingLastPathComponent }
        folders += homeVenvs.map { "\(home)/\($0)" }
        func children(of folder: String) -> [String]? {
            guard mayRead(folder) else { return nil }
            do {
                return try FileManager.default.contentsOfDirectory(atPath: folder)
                    .filter { !$0.hasPrefix(".") }
                    .map { "\(folder)/\($0)" }
            } catch {
                return NvmNodeVersionPolicy.isMissing(folder) ? [] : nil
            }
        }
        for relative in venvFolders {
            guard let found = children(of: "\(home)/\(relative)") else { return nil }
            folders += found
        }
        var level = ["\(home)/\(hatchVenvRoot)"]
        for depth in 0..<hatchVenvDepth {
            var next: [String] = []
            for folder in level {
                // Only folders hold environments. A file below the root is skipped.
                if depth > 0, !isFolder(folder) { continue }
                guard let found = children(of: folder) else { return nil }
                next += found
            }
            level = next
        }
        folders += level
        return folders
    }

    /// Whether `path` is a folder, following a link the way Python would.
    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// The candidates the environment at `venv` runs from: a path in its
    /// `pyvenv.cfg` (`home`, `executable`, `base-executable`, `command`) or
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
            for folder in candidates where NvmNodeVersionPolicy.names(text, versionFolder: folder, in: versionsRoot) {
                used.insert(folder)
            }
            for line in text.unicodeScalars.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let entry = String(String.UnicodeScalarView(line))
                guard let equals = entry.firstIndex(of: "=") else { continue }
                let value = entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                // `command = /path/python -m venv /path/env`: every word that is a path.
                for word in value.split(separator: " ") where word.hasPrefix("/") {
                    guard let reached = folders(
                        reachedBy: String(word), from: venv, candidates: candidates, root: root, mayRead: mayRead
                    ) else { return nil }
                    used.formUnion(reached)
                }
            }
        }
        // `bin/python` leads to the interpreter the environment runs.
        let bin = "\(venv)/bin"
        var info = stat()
        guard lstat(bin, &info) == 0 else {
            return NvmNodeVersionPolicy.isMissing(bin) ? used : nil
        }
        guard mayRead(bin) else { return nil }
        for name in ["python", "python3"] {
            let python = "\(bin)/\(name)"
            guard lstat(python, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { continue }
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

    // MARK: Other uses

    /// Whether something outside pyenv's own files uses the version: a
    /// reference file, a Jupyter kernel, a PyCharm interpreter, or a `bin`
    /// link. Nil when one can't be read.
    static func isUsedFromOutside(_ path: String, home: String, context: Context) -> Bool? {
        let folder = URL(fileURLWithPath: path).lastPathComponent
        var files = referenceFiles.map { "\(home)/\($0)" }

        /// The files `name` in each folder in `parent`, or in `parent` itself
        /// when `name` is nil. Nil when `parent` is there but can't be listed.
        func listed(_ parent: String, suffix: String?, inEach name: String?) -> [String]? {
            guard context.mayRead(parent) else { return nil }
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: parent).filter { !$0.hasPrefix(".") }
                if let name { return names.map { "\(parent)/\($0)/\(name)" } }
                return names.filter { suffix.map($0.hasSuffix) ?? true }.map { "\(parent)/\($0)" }
            } catch {
                return NvmNodeVersionPolicy.isMissing(parent) ? [] : nil
            }
        }
        guard let agents = listed("\(home)/\(NvmNodeVersionPolicy.launchAgents)", suffix: ".plist", inEach: nil),
              let kernels = listed("\(home)/\(jupyterKernels)", suffix: nil, inEach: "kernel.json"),
              let interpreters = listed("\(home)/\(jetBrainsRoot)", suffix: nil, inEach: jetBrainsInterpreters)
        else { return nil }
        files += agents + kernels + interpreters

        for file in files {
            guard context.mayRead(file) else { return nil }
            guard let data = FileManager.default.contents(atPath: file) else {
                // A missing file, or a kernel or product folder without one.
                var info = stat()
                if lstat(file, &info) != 0, errno == ENOENT || errno == ENOTDIR { continue }
                return nil
            }
            guard let text = NvmNodeVersionPolicy.searchableText(data) else { return nil }
            if namesVersion(text, folder: folder) { return true }
        }

        return NvmNodeVersionPolicy.isLinkedFromBinFolder(
            path, home: home, linkFolders: context.linkFolders, mayRead: context.mayRead
        )
    }

    /// Whether a reference file's `text` names the version: a path inside its
    /// folder, its version as a word (`pyenv shell 3.11.9`,
    /// `PYENV_VERSION=3.11.9`), or `PYENV_VERSION`, whose value Purge doesn't
    /// try to read from a script. A version some unrelated setting happens to
    /// hold keeps it too, which errs on keeping.
    static func namesVersion(_ text: String, folder: String) -> Bool {
        if NvmNodeVersionPolicy.names(text, versionFolder: folder, in: versionsRoot) { return true }
        let haystack = text.lowercased()
        if haystack.contains(environmentName.lowercased()) { return true }
        return RustupToolchainPolicy.containsWord(folder.lowercased(), in: haystack)
    }

    // MARK: Scan

    /// The paths pyenv and Python read for `roots`, for the ledger:
    /// `.python-version` in each project and every folder above it, up to `/`,
    /// and the `pyvenv.cfg` of each project's `.venv` and `venv`, each listed
    /// whether a file is there now or not, so one added after the scan still
    /// counts at the move. Also the `pyvenv.cfg` of every environment the walk
    /// sees in a project now: a folder of any name, or one in `.tox` or `.nox`.
    static func recordedFiles(inProjectRoots roots: [URL], mayRead: (String) -> Bool) -> [String] {
        let pins = NvmNodeVersionPolicy.nvmrcFiles(inProjectRoots: roots).map { nvmrc -> String in
            let folder = (nvmrc as NSString).deletingLastPathComponent
            return folder == "/" ? "/\(pinFileName)" : "\(folder)/\(pinFileName)"
        }
        var venvs: [String] = []
        for root in roots {
            let project = root.standardizedFileURL.path
            venvs += projectVenvNames.map { "\(project)/\($0)/\(venvConfigName)" }
            venvs += existingConfigs(in: project, mayRead: mayRead)
            for group in projectVenvGroups {
                venvs += existingConfigs(in: "\(project)/\(group)", mayRead: mayRead)
            }
        }
        var seen = Set<String>()
        return (pins + venvs).filter { seen.insert($0).inserted }
    }

    /// The `pyvenv.cfg` in each folder directly in `folder` that has one now.
    private static func existingConfigs(in folder: String, mayRead: (String) -> Bool) -> [String] {
        guard mayRead(folder), let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.compactMap { name in
            let config = "\(folder)/\(name)/\(venvConfigName)"
            return OldToolVersionScanPolicy.isRegularFile(config) ? config : nil
        }
    }
}
