import Darwin
import Foundation
import Testing
@testable import Purge

/// Python versions pyenv keeps (#404). Each keep rule has its own test. Every
/// fixture is a throwaway home folder with a fake recorded-file list,
/// environment and `lsof`.
private enum PY {
    typealias Policy = PyenvPythonVersionPolicy
    static let root = ".pyenv/versions"
    static let old = "3.11.9"
    static let newest = "3.11.10"
    static let other = "3.12.4"
    static let day: TimeInterval = 24 * 60 * 60

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-404-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    static func write(_ text: String, _ home: URL, _ relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func link(_ home: URL, _ relative: String, to destination: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    /// Sets a path's access and change times, without following a link.
    static func setTimes(_ path: String, accessed: Date, changed: Date) {
        var times = [
            timeval(tv_sec: Int(accessed.timeIntervalSince1970), tv_usec: 0),
            timeval(tv_sec: Int(changed.timeIntervalSince1970), tv_usec: 0),
        ]
        _ = lutimes(path, &times)
    }

    /// A version as pyenv 2.8 builds it: the interpreter, pip, `libpython`, an
    /// extension module and `ensurepip`'s packages.
    static func install(_ home: URL, in folder: String = root, _ names: String...) throws {
        for name in names {
            let minor = name.split(separator: ".").prefix(2).joined(separator: ".")
            let base = "\(folder)/\(name)"
            for file in ["bin/python\(minor)", "bin/python\(minor)-config", "bin/pip3", "bin/pip\(minor)",
                         "bin/pydoc\(minor)", "bin/idle\(minor)", "bin/2to3-\(minor)",
                         "lib/libpython\(minor).dylib",
                         "lib/python\(minor)/os.py",
                         "lib/python\(minor)/lib-dynload/_json.cpython-311-darwin.so",
                         "lib/python\(minor)/site-packages/README.txt",
                         "lib/python\(minor)/site-packages/pip/__init__.py",
                         "lib/python\(minor)/site-packages/pip-24.0.dist-info/METADATA",
                         "lib/python\(minor)/site-packages/setuptools/__init__.py",
                         "lib/python\(minor)/site-packages/setuptools-65.5.0.dist-info/METADATA",
                         "lib/python\(minor)/site-packages/_distutils_hack/__init__.py",
                         "lib/python\(minor)/site-packages/distutils-precedence.pth",
                         "include/python\(minor)/Python.h"] {
                try write("x", home, "\(base)/\(file)")
            }
            for alias in ["python", "python3"] {
                try link(home, "\(base)/bin/\(alias)", to: "python\(minor)")
            }
            settle(home, name, in: folder)
        }
    }

    /// Ages a version: changed two days ago, and its Python last ran `ran` ago.
    static func settle(_ home: URL, _ name: String, in folder: String = root, ran: TimeInterval = 120 * day) {
        let base = home.appendingPathComponent("\(folder)/\(name)").path
        let changed = Date().addingTimeInterval(-2 * day)
        let accessed = Date().addingTimeInterval(-ran)
        var folders: [String] = [base]
        if let walker = FileManager.default.enumerator(atPath: base) {
            for case let relative as String in walker {
                let path = "\(base)/\(relative)"
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: folders.append(path)
                case S_IFREG: setTimes(path, accessed: accessed, changed: min(changed, accessed))
                default: break
                }
            }
        }
        // Deepest first, so a folder's own time is set after what is in it.
        for path in folders.sorted(by: { $0.count > $1.count }) {
            setTimes(path, accessed: changed, changed: changed)
        }
    }

    /// The usual fixture: two patches of 3.11 and one 3.12, nothing pinned.
    static func makePyenv() throws -> URL {
        let home = try makeHome()
        try install(home, old, newest, other)
        return home
    }

    /// An empty recorded list unless a test gives one, every file readable, no
    /// `PYENV_VERSION`, no open files, and only `~/.local/bin` searched for links.
    static func context(
        recorded: [String]? = [],
        mayRead: @escaping @Sendable (String) -> Bool = { _ in true },
        lsof: String? = "",
        onLsof: @escaping @Sendable () -> Void = {},
        environment: [String]? = [],
        freshEnvironment: [String]?? = .none
    ) -> Policy.Context {
        let fresh: [String]? = freshEnvironment ?? environment
        return Policy.Context(
            recordedFiles: { recorded },
            mayRead: mayRead,
            openFiles: { onLsof(); return lsof },
            environment: { $0 ? fresh : environment },
            linkFolders: [".local/bin"]
        )
    }

    /// The files for a project at `relative`, as a Dev Projects walk records them.
    static func recorded(_ home: URL, project relative: String) -> [String] {
        Policy.recordedFiles(inProjectRoots: [home.appendingPathComponent(relative)], mayRead: { _ in true })
    }

    /// The version folders the Dev Tools scan offers, by name.
    static func offered(_ home: URL, _ context: Policy.Context = context(), now: Date = Date()) -> [String] {
        rows(home, context, now: now).flatMap(\.paths).map(\.lastPathComponent)
    }

    static func rows(
        _ home: URL, _ context: Policy.Context = context(), now: Date = Date()
    ) -> [(label: String, paths: [URL])] {
        OldToolVersionScanPolicy.definitions(
            home: home,
            now: now,
            android: .init(avdHomes: [], emulatorIsRunning: { false }),
            nvm: NvmNodeVersionPolicy.Context(
                nvmrcFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, linkFolders: []
            ),
            vitePlus: VitePlusNodeVersionPolicy.Context(
                pinFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, linkFolders: []
            ),
            rustup: rustupContext,
            pyenv: context
        )
        .filter { Policy.version(inLabel: $0.label) != nil }
    }

    static let rustupContext = RustupToolchainPolicy.Context(
        pinFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, environment: { _ in [] },
        rustupIsRunning: { false }, linkFolders: []
    )

    /// Whether `FileDeleter`'s last check, right before the move, lets it go.
    static func movable(
        _ home: URL, _ name: String, _ context: Policy.Context = context(), now: Date = Date()
    ) -> Bool {
        Policy.passesImmediateTrashBoundary(
            home.appendingPathComponent("\(root)/\(name)"), home: home.path, now: now, context: context
        )
    }

    /// Whether `isOfferedForCleanup`'s gate, which may run on the main thread, keeps the row.
    static func gateKeeps(
        _ home: URL, _ name: String, _ context: Policy.Context = context(), now: Date = Date()
    ) -> Bool {
        !OldToolVersionScanPolicy.refusesDeletion(
            home.appendingPathComponent("\(root)/\(name)"),
            home: home.path,
            now: now,
            android: .init(avdHomes: [], emulatorIsRunning: { false }),
            pyenv: context
        )
    }

    /// A `pyvenv.cfg` as `python -m venv` writes it, run from `version`.
    static func venv(_ home: URL, _ relative: String, from version: String) throws {
        let bin = home.appendingPathComponent("\(root)/\(version)/bin").path
        try write(
            "home = \(bin)\ninclude-system-site-packages = false\nversion = \(version)\n"
                + "executable = \(bin)/python3.11\ncommand = \(bin)/python3.11 -m venv \(home.path)/\(relative)\n",
            home, "\(relative)/pyvenv.cfg"
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Suite("pyenv Python versions (#404): shapes")
struct PyenvPythonVersionShapeTests {
    private let home = "/Users/someone"

    @Test(arguments: ["3.11.9", "3.12.10", "2.7.18", "3.9.0", "3.14.0"])
    func plainReleasesAreTheShape(name: String) {
        let path = "\(home)/.pyenv/versions/\(name)"
        #expect(OldToolVersionScanPolicy.kind(of: path, home: home) == .pyenvPythonVersion, "\(name)")
        #expect(OldToolVersionScanPolicy.isWhitelistedPath(path, home: home), "\(name)")
    }

    @Test(arguments: [
        ".pyenv", ".pyenv/versions", ".pyenv/version", ".pyenv/shims", ".pyenv/shims/python", ".pyenv/cache",
        ".pyenv/plugins", ".pyenv/plugins/pyenv-virtualenv",
        // What pyenv calls a version but `pyenv install` can't bring back as it was,
        // or that isn't plain CPython.
        ".pyenv/versions/system", ".pyenv/versions/3.13.0t", ".pyenv/versions/3.14-dev", ".pyenv/versions/3.14.0rc1",
        ".pyenv/versions/3.14.0a3", ".pyenv/versions/3.14.0b2", ".pyenv/versions/pypy3.10-7.3.15",
        ".pyenv/versions/miniconda3-latest", ".pyenv/versions/anaconda3-2024.02-1", ".pyenv/versions/graalpy-24.1.0",
        ".pyenv/versions/stackless-3.7.5", ".pyenv/versions/pyston-2.3.5",
        // Not three numbers.
        ".pyenv/versions/3.11", ".pyenv/versions/3", ".pyenv/versions/3.11.9.1", ".pyenv/versions/v3.11.9",
        ".pyenv/versions/3.11.x", ".pyenv/versions/.3.11.9",
        // A pyenv-virtualenv name, and what is inside a version.
        ".pyenv/versions/myenv", ".pyenv/versions/3.11.9/bin", ".pyenv/versions/3.11.9/envs/myenv",
        // The same names anywhere else.
        ".pyenv/3.11.9", "pyenv/versions/3.11.9", ".rbenv/versions/3.11.9", ".asdf/installs/python/3.11.9",
    ])
    func everythingElseIsNot(relative: String) {
        #expect(OldToolVersionScanPolicy.kind(of: "\(home)/\(relative)", home: home) == nil, "\(relative)")
    }

    /// A path in the real home, never touched: `evaluate` judges the real home's shapes.
    private func realHome(_ parts: String...) -> URL {
        parts.reduce(URL(fileURLWithPath: DeletionSafetyPolicy.cachedHomePath)) { $0.appendingPathComponent($1) }
    }

    @Test
    func evaluateAllowsOnlyTheShape() {
        #expect(DeletionSafetyPolicy.evaluate(realHome(".pyenv", "versions", PY.old)) == .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".pyenv")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".pyenv", "versions")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".pyenv", "versions", "3.13.0t")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".pyenv", "versions", "myenv")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".pyenv", "versions", PY.old, "bin")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".pyenv", "shims")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".pyenv", "version")) != .allow)
    }

    @Test
    func labelsCarryTheVersion() {
        #expect(PyenvPythonVersionPolicy.version(inLabel: "pyenv Python 3.11.9") == "3.11.9")
        #expect(PyenvPythonVersionPolicy.version(inLabel: "pyenv Python 3.11") == nil)
        #expect(PyenvPythonVersionPolicy.version(inLabel: "pyenv Python pypy3.10-7.3.15") == nil)
        #expect(PyenvPythonVersionPolicy.version(inLabel: "pyenv Python") == nil)
        #expect(PyenvPythonVersionPolicy.version(inLabel: "nvm Node.js 22.14.0") == nil)
        #expect(NvmNodeVersionPolicy.version(inLabel: "pyenv Python 3.11.9") == nil)
        #expect(RustupToolchainPolicy.toolchain(inLabel: "pyenv Python 3.11.9") == nil)
    }

    @Test
    func rowsAreCheckFirstAndSayHowToGetItBack() {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "pyenv Python 3.11.9", primaryPath: nil)
        #expect(info.level == .medium)
        #expect(info.headline.contains("3.11.9"))
        #expect(info.reinstallCommand == "pyenv install 3.11.9")
        #expect(info.explanation.contains("pyenv install"))
        #expect(BrandIconMapping.slug(forDefinitionKey: "pyenv Python 3.11.9") == "python")
    }

    @Test
    func versionFilesAreReadAsPyenvReadsThem() {
        #expect(PyenvPythonVersionPolicy.versionFileWords("3.11.9\n") == ["3.11.9"])
        #expect(PyenvPythonVersionPolicy.versionFileWords("3.11.9 3.12.4\n") == ["3.11.9"])
        #expect(PyenvPythonVersionPolicy.versionFileWords("# pinned\n\n  3.12.4\r\n3.11.9") == ["3.12.4", "3.11.9"])
        #expect(PyenvPythonVersionPolicy.versionFileWords("\t3.11.9\t# comment\n").first == "3.11.9")
        #expect(PyenvPythonVersionPolicy.versionFileWords("").isEmpty)
    }

    @Test(arguments: [
        ("3.11.9", ["3.11.9"]),
        ("3.11", ["3.11.10"]),
        ("3", ["3.13.1"]),
        ("python-3.11.9", ["3.11.9"]),
        ("python-3.11", ["3.11.10"]),
        ("3.11.9/envs/app", ["3.11.9"]),
        ("system", []),
        ("3.10", []),
        ("3.11.8", []),
        // `pyenv latest` passes over free-threaded builds and prereleases.
        ("3.13", ["3.13.1"]),
        ("3.13t", ["3.13.1t"]),
    ])
    func namesResolveAsPyenvResolvesThem(word: String, expected: [String]) {
        let installed = ["3.11.9", "3.11.10", "3.12.4", "3.13.1", "3.13.1t", "3.13.2rc1", "3.14-dev", "myenv"]
        #expect(PyenvPythonVersionPolicy.resolve(word, installed: installed) == Set(expected), "\(word)")
    }

    @Test
    func aNameThatClimbsOutIsNotUnderstood() {
        #expect(PyenvPythonVersionPolicy.resolve("../3.11.9", installed: ["3.11.9"]) == nil)
        #expect(PyenvPythonVersionPolicy.resolve("3.11.9/../x", installed: ["3.11.9"]) == nil)
        #expect(PyenvPythonVersionPolicy.resolve("..", installed: ["3.11.9"]) == nil)
    }

    @Test
    func recordedFilesCoverEveryFolderAndTheProjectsEnvironments() throws {
        let home = try PY.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write("home = /x\n", home, "code/app/env-311/pyvenv.cfg")
        try PY.write("home = /x\n", home, "code/app/.tox/py311/pyvenv.cfg")
        try PY.write("home = /x\n", home, "code/app/.nox/tests/pyvenv.cfg")
        try PY.write("x", home, "code/app/src/main.py")
        let files = PY.recorded(home, project: "code/app")
        let app = home.appendingPathComponent("code/app").path
        for folder in [app, home.appendingPathComponent("code").path, home.path, "/"] {
            #expect(files.contains(folder == "/" ? "/.python-version" : "\(folder)/.python-version"), "\(folder)")
        }
        // Recorded whether there or not, so one made after the scan counts.
        #expect(files.contains("\(app)/.venv/pyvenv.cfg"))
        #expect(files.contains("\(app)/venv/pyvenv.cfg"))
        // Seen by the walk now, under any name.
        #expect(files.contains("\(app)/env-311/pyvenv.cfg"))
        #expect(files.contains("\(app)/.tox/py311/pyvenv.cfg"))
        #expect(files.contains("\(app)/.nox/tests/pyvenv.cfg"))
        #expect(!files.contains("\(app)/src/pyvenv.cfg"))
    }

    @Test
    func theDefaultMoveCheckRunsPyenvToo() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let nvm = NvmNodeVersionPolicy.Context(nvmrcFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, linkFolders: [])
        let vitePlus = VitePlusNodeVersionPolicy.Context(
            pinFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, linkFolders: []
        )
        func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }
        func check(_ pyenv: PyenvPythonVersionPolicy.Context) -> @Sendable (URL) -> Bool {
            FileDeleter.defaultImmediateMoveCheck(
                home: home.path, nvm: nvm, vitePlus: vitePlus, rustup: PY.rustupContext, pyenv: pyenv
            )
        }
        #expect(check(PY.context())(path("\(PY.root)/\(PY.old)")))
        #expect(check(PY.context())(path("Library/Caches/something")))
        #expect(!check(PY.context(environment: ["3.11.9"]))(path("\(PY.root)/\(PY.old)")), "pyenv's part runs")
        #expect(!check(PY.context(lsof: nil))(path("\(PY.root)/\(PY.old)")))
    }
}

@Suite("pyenv Python versions (#404): what stays")
struct PyenvPythonVersionKeepTests {

    @Test
    func anOldPatchIsOfferedAndTheNewestOfEachMinorStays() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.install(home, "3.12.1", "3.13.0t", "pypy3.10-7.3.15")
        let rows = PY.rows(home)
        #expect(Set(rows.flatMap(\.paths).map(\.lastPathComponent)) == [PY.old, "3.12.1"])
        #expect(Set(rows.map(\.label)) == ["pyenv Python 3.11.9", "pyenv Python 3.12.1"])
        #expect(rows.allSatisfy { $0.paths.count == 1 })
    }

    @Test
    func noPyenvOffersNothing() throws {
        let home = try PY.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(PY.offered(home).isEmpty)
    }

    @Test(arguments: [
        ".pyenv/version", ".pyenv/global", ".pyenv/default", ".python-version",
    ])
    func aVersionFileInHomeKeepsItsVersion(file: String) throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write("3.12.4\n3.11.9\n", home, file)
        #expect(PY.offered(home).isEmpty, "\(file)")
    }

    @Test(arguments: ["3.11.9", "python-3.11.9", "3.11.9/envs/app", "system:3.11.9"])
    func theEnvironmentVariableKeepsItsVersion(value: String) throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(PY.offered(home, PY.context(environment: [value])).isEmpty, "\(value)")
    }

    @Test
    func aMinorPinKeepsOnlyTheNewestOfItsMinor() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write("3.11\n", home, ".pyenv/version")
        #expect(PY.offered(home) == [PY.old])
    }

    @Test
    func aProjectPinAndOneAboveItCount() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = PY.context(recorded: PY.recorded(home, project: "code/app"))
        #expect(PY.offered(home, context) == [PY.old])
        try PY.write("3.11.9\n", home, "code/app/.python-version")
        #expect(PY.offered(home, context).isEmpty)
        try FileManager.default.removeItem(at: home.appendingPathComponent("code/app/.python-version"))
        try PY.write("3.11.9\n", home, "code/.python-version")
        #expect(PY.offered(home, context).isEmpty)
    }

    @Test
    func aVersionFilePurgeCannotFollowKeepsEverything() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write("../../escape\n", home, ".pyenv/version")
        #expect(PY.offered(home).isEmpty)
    }

    @Test
    func aPinPurgeMayNotReadKeepsEverything() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let pins = PY.recorded(home, project: "Documents/app")
        let blocked = home.appendingPathComponent("Documents").path
        let context = PY.context(recorded: pins, mayRead: { !$0.hasPrefix(blocked) })
        #expect(PY.offered(home, context).isEmpty)
    }

    @Test
    func noRecordedProjectsYetKeepsEverything() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(PY.offered(home, PY.context(recorded: nil)).isEmpty)
    }

    @Test
    func anEnvironmentPurgeCouldNotReadKeepsEverything() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(PY.offered(home, PY.context(environment: nil)).isEmpty)
    }

    @Test
    func aPyenvVirtualenvKeepsItsBase() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write("home = x\n", home, "\(PY.root)/\(PY.old)/envs/app/pyvenv.cfg")
        try PY.link(home, "\(PY.root)/app", to: home.appendingPathComponent("\(PY.root)/\(PY.old)/envs/app").path)
        PY.settle(home, PY.old)
        #expect(PY.offered(home).isEmpty)
        // The environment alone keeps it, with no link beside it.
        try FileManager.default.removeItem(at: home.appendingPathComponent("\(PY.root)/app"))
        #expect(PY.offered(home).isEmpty)
    }

    @Test
    func aLinkInTheVersionsFolderKeepsTheVersionItLeadsInto() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.link(home, "\(PY.root)/3.11", to: PY.old)
        #expect(PY.offered(home).isEmpty)
    }

    @Test(arguments: [
        "code/app/.venv", "code/app/venv",
        ".local/share/uv/tools/ruff", ".local/pipx/venvs/black", ".local/share/pipx/venvs/black",
        "Library/Application Support/pipx/venvs/black", ".local/pipx/shared",
        ".virtualenvs/work", "Library/Caches/pypoetry/virtualenvs/app-x1y2-py3.11", ".local/share/virtualenvs/app-x1y2",
        "Library/Application Support/pdm/venvs/app-x1y2-3.11",
        "Library/Application Support/hatch/env/virtual/app/x1y2/default", ".venv",
    ])
    func aVirtualEnvironmentKeepsTheVersionItRunsFrom(relative: String) throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = PY.context(recorded: PY.recorded(home, project: "code/app"))
        #expect(PY.offered(home, context) == [PY.old])
        try PY.venv(home, relative, from: PY.old)
        #expect(PY.offered(home, context).isEmpty, "\(relative)")
    }

    @Test
    func aProjectEnvironmentUnderAnyNameSeenByTheWalkCounts() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.venv(home, "code/app/.tox/py311", from: PY.old)
        try PY.venv(home, "code/lib/env-old", from: PY.old)
        let recorded = PY.recorded(home, project: "code/app")
        #expect(PY.offered(home, PY.context(recorded: recorded)).isEmpty)
        let other = PY.recorded(home, project: "code/lib")
        #expect(PY.offered(home, PY.context(recorded: other)).isEmpty)
    }

    @Test
    func anEnvironmentWhosePythonLinkLeadsInKeepsIt() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        // No `pyvenv.cfg`, as `virtualenv` once made them: only the link says.
        try PY.link(home, ".virtualenvs/work/bin/python",
                    to: home.appendingPathComponent("\(PY.root)/\(PY.old)/bin/python3.11").path)
        #expect(PY.offered(home).isEmpty)
    }

    @Test
    func anEnvironmentReachedThroughALinkedSpellingCounts() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        // `home` names the version through another link, here outside pyenv.
        try PY.link(home, "py311", to: home.appendingPathComponent("\(PY.root)/\(PY.old)").path)
        try PY.write("home = \(home.path)/py311/bin\n", home, ".virtualenvs/work/pyvenv.cfg")
        #expect(PY.offered(home).isEmpty)
    }

    @Test
    func anEnvironmentPurgeMayNotReadKeepsEverything() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.venv(home, ".virtualenvs/work", from: PY.other)
        let blocked = home.appendingPathComponent(".virtualenvs").path
        #expect(PY.offered(home, PY.context(mayRead: { !$0.hasPrefix(blocked) })).isEmpty)
    }

    @Test
    func anEnvironmentOnAnotherVersionKeepsNothingHere() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.venv(home, ".virtualenvs/work", from: PY.other)
        try PY.venv(home, ".virtualenvs/longer", from: "3.11.90")
        #expect(PY.offered(home) == [PY.old])
    }

    @Test(arguments: [
        "bin/black", "lib/python3.11/site-packages/requests/__init__.py",
        "lib/python3.11/site-packages/requests-2.32.0.dist-info/METADATA",
        "lib/python3.11/site-packages/six.py",
    ])
    func aPackageInstalledIntoTheVersionKeepsIt(relative: String) throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write("x", home, "\(PY.root)/\(PY.old)/\(relative)")
        PY.settle(home, PY.old)
        #expect(PY.offered(home).isEmpty, "\(relative)")
    }

    @Test
    func anUpgradedPipIsStillWhatShips() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let site = "\(PY.root)/\(PY.old)/lib/python3.11/site-packages"
        try FileManager.default.removeItem(at: home.appendingPathComponent("\(site)/pip-24.0.dist-info"))
        try PY.write("x", home, "\(site)/pip-25.1.dist-info/METADATA")
        try PY.write("x", home, "\(site)/wheel-0.45.0.dist-info/METADATA")
        PY.settle(home, PY.old)
        #expect(PY.offered(home) == [PY.old])
    }

    @Test
    func aVersionThatRanInTheLast90DaysStays() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        PY.settle(home, PY.old, ran: 30 * PY.day)
        #expect(PY.offered(home).isEmpty)
        #expect(PY.offered(home, now: Date().addingTimeInterval(61 * PY.day)) == [PY.old])
    }

    /// A `--copies` environment runs its own program, but it still loads the
    /// version's `libpython` (probed with pyenv 2.8.15 and 3.11.9).
    @Test(arguments: ["lib/libpython3.11.dylib", "bin/python3.11", "lib/python3.11/lib-dynload/_json.cpython-311-darwin.so"])
    func aRecentLoadOfAnyOfItsProgramsKeepsIt(relative: String) throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        PY.setTimes(
            home.appendingPathComponent("\(PY.root)/\(PY.old)/\(relative)").path,
            accessed: Date().addingTimeInterval(-PY.day), changed: Date().addingTimeInterval(-200 * PY.day)
        )
        #expect(PY.offered(home).isEmpty, "\(relative)")
    }

    @Test
    func aVersionWithNothingToTellItsLastRunStays() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let base = home.appendingPathComponent("\(PY.root)/\(PY.old)")
        for relative in ["bin/python3.11", "bin/python3.11-config", "lib/libpython3.11.dylib",
                         "lib/python3.11/lib-dynload/_json.cpython-311-darwin.so"] {
            try FileManager.default.removeItem(at: base.appendingPathComponent(relative))
        }
        try PY.link(home, "\(PY.root)/\(PY.old)/bin/python3.11", to: "/usr/bin/true")
        PY.settle(home, PY.old)
        #expect(PY.offered(home).isEmpty)
    }

    @Test
    func anInstallThatIsUnfinishedOrJustChangedStays() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        // No `bin/python3` yet.
        try PY.install(home, "3.11.5")
        try FileManager.default.removeItem(at: home.appendingPathComponent("\(PY.root)/3.11.5/bin/python3"))
        PY.settle(home, "3.11.5")
        // Changed an hour ago, as a `pip install` into it would.
        try PY.install(home, "3.11.6")
        let changed = home.appendingPathComponent("\(PY.root)/3.11.6/lib").path
        PY.setTimes(changed, accessed: Date(), changed: Date().addingTimeInterval(-60 * 60))
        #expect(PY.offered(home) == [PY.old])
        #expect(Set(PY.offered(home, now: Date().addingTimeInterval(PY.day))) == [PY.old, "3.11.6"])
    }

    @Test
    func aLinkOnTheWayIsNeverFollowed() throws {
        let home = try PY.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.install(home, in: "elsewhere/versions", PY.old, PY.newest)
        try PY.link(home, PY.root, to: home.appendingPathComponent("elsewhere/versions").path)
        #expect(PY.offered(home).isEmpty)
        #expect(!PY.movable(home, PY.old))

        let other = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: other) }
        // A version that is itself a link, under a name pyenv would give.
        try PY.link(other, "\(PY.root)/3.11.1", to: other.appendingPathComponent("\(PY.root)/\(PY.newest)").path)
        #expect(PY.offered(other) == [PY.old], "the link is not offered")
        #expect(!PY.movable(other, "3.11.1"))
    }

    @Test(arguments: [
        (".zshrc", "pyenv shell 3.11.9\n"),
        (".zshrc", "export PATH=\"$HOME/.pyenv/versions/3.11.9/bin:$PATH\"\n"),
        (".bash_profile", "alias py311='~/.pyenv/versions/3.11.9/bin/python'\n"),
        ("Library/Application Support/Code/User/settings.json",
         #"{"python.defaultInterpreterPath":"~\/.pyenv\/versions\/3.11.9\/bin\/python"}"#),
        (".claude.json", #"{"mcpServers":{"x":{"command":"/Users/me/.pyenv/versions/3.11.9/bin/python"}}}"#),
        ("Library/LaunchAgents/dev.example.job.plist",
         "<plist><dict><key>ProgramArguments</key><array><string>/Users/me/.pyenv/versions/3.11.9/bin/python3</string></array></dict></plist>"),
        ("Library/Jupyter/kernels/py311/kernel.json",
         #"{"argv":["/Users/me/.pyenv/versions/3.11.9/bin/python","-m","ipykernel_launcher"]}"#),
        ("Library/Application Support/JetBrains/PyCharm2025.2/options/jdk.table.xml",
         "<homePath value=\"$USER_HOME$/.pyenv/versions/3.11.9/bin/python3.11\" />"),
    ])
    func aReferenceFileKeepsTheVersionItNames(file: String, text: String) throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write(text, home, file)
        #expect(PY.offered(home).isEmpty, "\(file)")
        #expect(!PY.movable(home, PY.old), "\(file)")
        // The list gate reads only small files, and lets the move decide.
        #expect(PY.gateKeeps(home, PY.old))
    }

    @Test
    func theVariableInAReferenceFileKeepsEverything() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write("export PYENV_VERSION=$(cat ~/.myversion)\n", home, ".zshrc")
        #expect(PY.offered(home).isEmpty)
    }

    @Test
    func aLongerVersionInAReferenceFileIsNotThisOne() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write("pyenv shell 3.11.90\nalias x=~/.pyenv/versions/3.11.95/bin/python\nv=13.11.9\n", home, ".zshrc")
        #expect(PY.offered(home) == [PY.old])
    }

    @Test
    func aReferenceFilePurgeMayNotReadKeepsEverything() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.write("x", home, "Library/Application Support/Code/User/settings.json")
        let blocked = home.appendingPathComponent("Library/Application Support/Code").path
        #expect(PY.offered(home, PY.context(mayRead: { !$0.hasPrefix(blocked) })).isEmpty)
    }

    @Test
    func aLinkInABinFolderKeepsItsVersion() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.link(home, ".local/bin/python3.11",
                    to: home.appendingPathComponent("\(PY.root)/\(PY.old)/bin/python3.11").path)
        #expect(PY.offered(home).isEmpty)
    }

    @Test
    func aScanReadsTheVersionFilesOnce() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        try PY.install(home, "3.11.5", "3.11.6")
        let reads = Counter()
        var context = PY.context()
        context.recordedFiles = { reads.add(); return [] }
        #expect(Set(PY.offered(home, context)) == [PY.old, "3.11.5", "3.11.6"])
        #expect(reads.value == 1)
    }
}

@Suite("pyenv Python versions (#404): the move")
struct PyenvPythonVersionMoveTests {

    @Test
    func theListGateNeverRunsLsof() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let calls = Counter()
        let context = PY.context(onLsof: { calls.add() })
        #expect(PY.gateKeeps(home, PY.old, context))
        #expect(PY.offered(home, context) == [PY.old])
        #expect(calls.value == 0)
        #expect(PY.movable(home, PY.old, context))
        #expect(calls.value == 1)
    }

    @Test
    func aProcessUsingTheVersionStopsTheMove() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let library = home.appendingPathComponent("\(PY.root)/\(PY.old)/lib/libpython3.11.dylib").path
        #expect(PY.movable(home, PY.old))
        #expect(!PY.movable(home, PY.old, PY.context(lsof: "p123\nn\(library)\n")))
        #expect(!PY.movable(home, PY.old, PY.context(lsof: nil)))
        let other = home.appendingPathComponent("\(PY.root)/\(PY.newest)/lib/libpython3.11.dylib").path
        #expect(PY.movable(home, PY.old, PY.context(lsof: "p123\nn\(other)\n")))
    }

    /// `launchctl setenv PYENV_VERSION` after the clean began: the move asks
    /// launchd again, and the list gate and the scan never do.
    @Test
    func theMoveReadsTheVariableAgain() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let setSince = PY.context(freshEnvironment: ["3.11.9"])
        #expect(PY.offered(home, setSince) == [PY.old])
        #expect(PY.gateKeeps(home, PY.old, setSince))
        #expect(!PY.movable(home, PY.old, setSince))
        #expect(!PY.movable(home, PY.old, PY.context(freshEnvironment: .some(nil))))

        let fresh = Counter(), earlier = Counter()
        var context = PY.context()
        context.environment = { isFresh in
            (isFresh ? fresh : earlier).add()
            return []
        }
        _ = PY.offered(home, context)
        #expect(fresh.value == 0)
        #expect(earlier.value > 0)
        #expect(PY.movable(home, PY.old, context))
        #expect(fresh.value == 1)
    }

    @Test
    func whatChangedAfterTheScanStopsTheMove() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = PY.context(recorded: PY.recorded(home, project: "code/app"))
        #expect(PY.offered(home, context) == [PY.old])

        // A pin added to a recorded project.
        try PY.write("3.11.9\n", home, "code/app/.python-version")
        #expect(!PY.movable(home, PY.old, context))
        try FileManager.default.removeItem(at: home.appendingPathComponent("code/app/.python-version"))
        #expect(PY.movable(home, PY.old, context))

        // A virtual environment made in the project.
        try PY.venv(home, "code/app/.venv", from: PY.old)
        #expect(!PY.movable(home, PY.old, context))
        try FileManager.default.removeItem(at: home.appendingPathComponent("code/app/.venv"))
        #expect(PY.movable(home, PY.old, context))

        // `pyenv global`.
        try PY.write("3.11.9\n", home, ".pyenv/version")
        #expect(!PY.movable(home, PY.old, context))
        try FileManager.default.removeItem(at: home.appendingPathComponent(".pyenv/version"))

        // The version ran just now.
        PY.setTimes(home.appendingPathComponent("\(PY.root)/\(PY.old)/bin/python3.11").path,
                    accessed: Date(), changed: Date().addingTimeInterval(-200 * PY.day))
        #expect(!PY.movable(home, PY.old, context))
    }

    /// The gate `isOfferedForCleanup` asks reads the small files again, so a
    /// row whose version became the global one is dropped before any move.
    @Test
    func theListGateRefusesWhatBecameGlobal() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(PY.gateKeeps(home, PY.old))
        try PY.write("3.11.9\n", home, ".pyenv/version")
        let later = Date().addingTimeInterval(NvmNodeVersionPolicy.recentReadLifetime + 1)
        #expect(!PY.gateKeeps(home, PY.old, now: later))
    }

    @Test
    func otherPathsPassTheMoveCheck() throws {
        let home = try PY.makePyenv()
        defer { try? FileManager.default.removeItem(at: home) }
        // Not this rule's to judge: other rules refuse them.
        for relative in [".pyenv", ".pyenv/versions", "\(PY.root)/3.13.0t", "Library/Caches/x", ".nvm/versions/node/v20.0.0"] {
            #expect(PyenvPythonVersionPolicy.passesImmediateTrashBoundary(
                home.appendingPathComponent(relative), home: home.path, context: PY.context(lsof: nil)
            ), "\(relative)")
        }
    }

    @Test
    func aFailedSaveSetsAsideIntoItsOwnFile() throws {
        let folder = try PY.makeHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = NvmrcLedger(
            fileURL: folder.appendingPathComponent("pyenv-files.json"),
            write: { data, url in
                if url.lastPathComponent == "pyenv-files.json" { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        ledger.record(["/Users/me/code/app/.python-version"], home: "/Users/me", fullAccess: true, mayRead: { _ in true })
        #expect(ledger.files() == nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pyenv-files.unsaved.json").path))
    }
}
