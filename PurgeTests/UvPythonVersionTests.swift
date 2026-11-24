import Foundation
import Testing
@testable import Purge

/// Python versions uv keeps next to its minor-version links (#405). Each keep
/// rule has its own test. Every fixture is a throwaway home folder with a fake
/// recorded-file list, process list and `lsof`.
private enum UV {
    typealias Policy = UvPythonVersionPolicy
    static let root = ".local/share/uv/python"
    static let oldest = "cpython-3.12.4-macos-aarch64-none"
    static let older = "cpython-3.12.6-macos-aarch64-none"
    static let newest = "cpython-3.12.8-macos-aarch64-none"
    static let minorLink = "cpython-3.12-macos-aarch64-none"
    static let day: TimeInterval = 24 * 60 * 60

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-405-\(UUID().uuidString)", isDirectory: true)
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

    static func setAge(_ path: String, _ age: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }

    /// A patch folder as uv leaves it once an install is done, last changed `age` ago.
    static func install(_ home: URL, age: TimeInterval = 2 * day, _ names: String...) throws {
        for name in names {
            let folder = "\(root)/\(name)"
            try write("x", home, "\(folder)/bin/python3.12")
            try link(home, "\(folder)/bin/python3", to: "python3.12")
            try link(home, "\(folder)/bin/python", to: "python3.12")
            try write("x", home, "\(folder)/lib/python3.12/os.py")
            try write("x", home, "\(folder)/BUILD")
            let path = home.appendingPathComponent(folder).path
            for entry in try FileManager.default.contentsOfDirectory(atPath: path) {
                try setAge("\(path)/\(entry)", age)
            }
            try setAge(path, age)
        }
    }

    /// The minor link uv keeps, with the whole path, as uv writes it.
    static func minorLink(_ home: URL, _ link: String = minorLink, to folder: String) throws {
        try self.link(home, "\(root)/\(link)", to: home.appendingPathComponent("\(root)/\(folder)").path)
    }

    /// The usual fixture: three 3.12 patches, the link on the newest.
    static func makeUv() throws -> URL {
        let home = try makeHome()
        try install(home, oldest, older, newest)
        try minorLink(home, to: newest)
        return home
    }

    static func path(_ home: URL, _ name: String) -> String {
        home.appendingPathComponent("\(root)/\(name)").path
    }

    /// An empty recorded-file list unless a test gives one, every file
    /// readable, uv idle, no open files, and only `~/.local/bin` searched for
    /// links and `~/.cargo/bin` for programs.
    static func context(
        recorded: [String]? = [],
        mayRead: @escaping @Sendable (String) -> Bool = { _ in true },
        lsof: String? = "",
        uvIsRunning: Bool = false
    ) -> Policy.Context {
        Policy.Context(
            recordedFiles: { recorded },
            mayRead: mayRead,
            openFiles: { lsof },
            uvIsRunning: { uvIsRunning },
            linkFolders: [".local/bin"],
            programFolders: [".cargo/bin"]
        )
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
            rustup: inertRustup,
            uv: context
        )
        .filter { Policy.folder(inLabel: $0.label) != nil }
    }

    static let inertRustup = RustupToolchainPolicy.Context(
        pinFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, environment: { _ in [] },
        rustupIsRunning: { false }, linkFolders: [], programFolders: []
    )

    /// Whether `FileDeleter`'s last check, right before the move, lets it go.
    static func movable(
        _ home: URL, _ name: String, _ context: Policy.Context = context(), now: Date = Date()
    ) -> Bool {
        Policy.passesImmediateTrashBoundary(
            URL(fileURLWithPath: path(home, name)), home: home.path, now: now, context: context
        )
    }

    /// Whether `isOfferedForCleanup`'s gate, which may run on the main thread, keeps the row.
    static func gateKeeps(
        _ home: URL, _ name: String, _ context: Policy.Context = context(), now: Date = Date()
    ) -> Bool {
        !OldToolVersionScanPolicy.refusesDeletion(
            URL(fileURLWithPath: path(home, name)),
            home: home.path,
            now: now,
            android: .init(avdHomes: [], emulatorIsRunning: { false }),
            rustup: inertRustup,
            uv: context
        )
    }

    /// The files a Dev Projects walk records for a project at `relative`.
    static func recorded(_ home: URL, project relative: String) -> [String] {
        Policy.recordedFiles(inProjectRoots: [home.appendingPathComponent(relative)])
    }
}

@Suite("uv Python versions (#405): shapes and names")
struct UvPythonVersionShapeTests {
    private let home = "/Users/someone"

    @Test(arguments: [
        "cpython-3.12.4-macos-aarch64-none", "cpython-3.12.4-macos-x86_64-none", "cpython-3.8.20-macos-aarch64-none",
        "cpython-3.13.1+freethreaded-macos-aarch64-none", "cpython-3.13.1+freethreaded+debug-macos-aarch64-none",
        "cpython-3.13.1+debug-macos-aarch64-none", "cpython-3.14.0+gil-macos-aarch64-none",
        "cpython-3.15.0a1-macos-aarch64-none", "cpython-3.14.0rc2-macos-aarch64-none",
        "cpython-3.14.0b3-macos-aarch64-none", "cpython-3.12.10-macos-aarch64-none",
    ])
    func patchFoldersAreTheShape(name: String) {
        let path = "\(home)/.local/share/uv/python/\(name)"
        #expect(OldToolVersionScanPolicy.kind(of: path, home: home) == .uvPythonVersion, "\(name)")
        #expect(OldToolVersionScanPolicy.isWhitelistedPath(path, home: home), "\(name)")
    }

    @Test(arguments: [
        ".local/share/uv", ".local/share/uv/python", ".local/share/uv/tools", ".local/share/uv/tools/ruff",
        ".local/share/uv/python/.lock", ".local/share/uv/python/.temp", ".local/share/uv/python/.gitignore",
        // The minor links.
        ".local/share/uv/python/cpython-3.12-macos-aarch64-none",
        ".local/share/uv/python/cpython-3.13+freethreaded-macos-aarch64-none",
        // Other implementations, which get no minor link.
        ".local/share/uv/python/pypy-3.10.14-macos-aarch64-none",
        ".local/share/uv/python/graalpy-3.11.0-macos-aarch64-none",
        ".local/share/uv/python/cpython-3.12.7-emscripten-wasm32-musl",
        // Other platforms, and names uv never writes.
        ".local/share/uv/python/cpython-3.12.4-linux-aarch64-gnu",
        ".local/share/uv/python/cpython-3.12.4-macos-arm64-none",
        ".local/share/uv/python/cpython-3.12.4-macos-aarch64-none-extra",
        ".local/share/uv/python/cpython-3.012.4-macos-aarch64-none",
        ".local/share/uv/python/cpython-3.12.04-macos-aarch64-none",
        ".local/share/uv/python/cpython-3.12.4+foo-macos-aarch64-none",
        ".local/share/uv/python/cpython-3.12.4c1-macos-aarch64-none",
        ".local/share/uv/python/cpython-3.12.4rc-macos-aarch64-none",
        ".local/share/uv/python/cpython-3.12-macos-aarch64",
        ".local/share/uv/python/CPython-3.12.4-macos-aarch64-none",
        ".local/share/uv/python/.cpython-3.12.4-macos-aarch64-none",
        // Inside a version, and the same name anywhere else.
        ".local/share/uv/python/cpython-3.12.4-macos-aarch64-none/bin",
        ".local/share/uv/python/cpython-3.12.4-macos-aarch64-none/lib/python3.12",
        ".local/share/uv/cpython-3.12.4-macos-aarch64-none",
        "Library/Application Support/uv/python/cpython-3.12.4-macos-aarch64-none",
        ".pyenv/versions/cpython-3.12.4-macos-aarch64-none",
    ])
    func everythingElseIsNot(relative: String) {
        let path = "\(home)/\(relative)"
        #expect(OldToolVersionScanPolicy.kind(of: path, home: home) == nil, "\(relative)")
    }

    @Test
    func versionsSortAsUvSortsThem() throws {
        func name(_ version: String) throws -> UvPythonVersionPolicy.Name {
            try #require(UvPythonVersionPolicy.parse(folderName: "cpython-\(version)-macos-aarch64-none"))
        }
        let order = ["3.12.4", "3.12.10", "3.13.0a1", "3.13.0a2", "3.13.0b1", "3.13.0rc1", "3.13.0", "3.13.1"]
        for (lower, higher) in zip(order, order.dropFirst()) {
            #expect(try name(lower).isOlder(than: name(higher)), "\(lower) < \(higher)")
            #expect(try !name(higher).isOlder(than: name(lower)), "\(higher) > \(lower)")
        }
        #expect(try !name("3.12.4").isOlder(than: name("3.12.4")))
    }

    /// A Java class file shares the universal magic, followed by its version.
    @Test
    func universalHeadersAreToldFromOtherFiles() {
        func bytes(_ words: [UInt32]) -> Data {
            Data(words.flatMap { withUnsafeBytes(of: $0.bigEndian, Array.init) })
        }
        typealias Policy = OldToolVersionScanPolicy
        #expect(Policy.fatSlices(in: bytes([0xCAFE_BABE, 1, 0x0100_000C, 0, 4096, 100, 14]))
            == .slices([Policy.FatSlice(offset: 4096, size: 100)]))
        #expect(Policy.fatSlices(in: bytes([0xCAFE_BABF, 1, 0x0100_000C, 0, 0, 8192, 0, 64, 14, 0]))
            == .slices([Policy.FatSlice(offset: 8192, size: 64)]))
        #expect(Policy.fatSlices(in: bytes([0xCAFE_BABE, 0x0000_0034])) == .notFat)
        #expect(Policy.fatSlices(in: bytes([0xFEED_FACF, 0x0100_000C])) == .notFat)
        #expect(Policy.fatSlices(in: Data("#!/bin/sh\n".utf8)) == .notFat)
        #expect(Policy.fatSlices(in: bytes([0xCAFE_BABE, 2, 0x0100_000C, 0, 4096])) == .malformed)
    }

    @Test
    func eachBuildHasItsOwnMinorLink() throws {
        let plain = try #require(UvPythonVersionPolicy.parse(folderName: "cpython-3.12.4-macos-aarch64-none"))
        #expect(plain.minorLinkName == "cpython-3.12-macos-aarch64-none")
        let threaded = try #require(
            UvPythonVersionPolicy.parse(folderName: "cpython-3.13.1+freethreaded-macos-x86_64-none")
        )
        #expect(threaded.minorLinkName == "cpython-3.13+freethreaded-macos-x86_64-none")
        #expect(threaded.request == "3.13.1+freethreaded")
    }

    @Test
    func labelsCarryTheWholeFolderName() {
        #expect(UvPythonVersionPolicy.folder(inLabel: "uv Python \(UV.oldest)") == UV.oldest)
        #expect(UvPythonVersionPolicy.folder(inLabel: "uv Python 3.12.4") == nil)
        #expect(UvPythonVersionPolicy.folder(inLabel: "uv Package Cache") == nil)
        #expect(RustupToolchainPolicy.toolchain(inLabel: "uv Python \(UV.oldest)") == nil)
        #expect(NvmNodeVersionPolicy.version(inLabel: "uv Python \(UV.oldest)") == nil)
    }

    @Test
    func rowsAreCheckFirstAndSayHowToGetItBack() {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "uv Python \(UV.oldest)", primaryPath: nil)
        #expect(info.level == .medium)
        let host = UvPythonVersionPolicy.hostArchitecture
        if host == "aarch64" {
            #expect(info.headline.contains("3.12.4"))
            #expect(!info.headline.contains("aarch64"))
            #expect(info.reinstallCommand == "uv python install 3.12.4")
        }
        #expect(BrandIconMapping.slug(forDefinitionKey: "uv Python \(UV.oldest)") == "python")
    }

    /// The short request installs this Mac's own build, so another build is
    /// named whole.
    @Test
    func anotherBuildIsNamedWhole() {
        let other = UvPythonVersionPolicy.hostArchitecture == "aarch64" ? "x86_64" : "aarch64"
        let folder = "cpython-3.12.4-macos-\(other)-none"
        #expect(UvPythonVersionPolicy.reinstallCommand(forFolderName: folder) == "uv python install \(folder)")
        #expect(UvPythonVersionPolicy.displayVersion(ofFolderName: folder) == "3.12.4 \(other)")
        let own = "cpython-3.13.1+freethreaded-macos-\(UvPythonVersionPolicy.hostArchitecture)-none"
        #expect(UvPythonVersionPolicy.reinstallCommand(forFolderName: own) == "uv python install 3.13.1+freethreaded")
        #expect(UvPythonVersionPolicy.displayVersion(ofFolderName: own) == "3.13.1+freethreaded")
    }

    @Test
    func aWalkRecordsPinsUpToTheTopAndEachProjectsEnvironments() {
        let files = UvPythonVersionPolicy.recordedFiles(inProjectRoots: [URL(fileURLWithPath: "/Users/me/code/app")])
        for folder in ["/Users/me/code/app", "/Users/me/code", "/Users/me", "/Users"] {
            #expect(files.contains("\(folder)/.python-version"), "\(folder)")
        }
        #expect(files.contains("/.python-version"))
        #expect(files.contains("/Users/me/code/app/.venv/pyvenv.cfg"))
        #expect(files.contains("/Users/me/code/app/venv/pyvenv.cfg"))
        #expect(files.contains("/Users/me/code/app/*"))
        #expect(!files.contains("/Users/me/code/.venv/pyvenv.cfg"))
    }
}

@Suite("uv Python versions (#405): the link")
struct UvPythonVersionLinkTests {
    @Test
    func versionsBehindTheLinkAreOfferedAndTheLinkedOneIsNot() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(UV.offered(home) == [UV.oldest, UV.older])
        let rows = UV.rows(home)
        #expect(rows.map(\.label) == ["uv Python \(UV.oldest)", "uv Python \(UV.older)"])
        #expect(UV.gateKeeps(home, UV.oldest))
        #expect(!UV.gateKeeps(home, UV.newest))
        #expect(UV.movable(home, UV.oldest))
        #expect(!UV.movable(home, UV.newest))
    }

    /// Before uv 0.10 there was no link, and environments point at the patch folder.
    @Test
    func noLinkOffersNothing() throws {
        let home = try UV.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.install(home, UV.oldest, UV.newest)
        #expect(UV.offered(home).isEmpty)
        #expect(!UV.movable(home, UV.oldest))
    }

    @Test
    func aLinkOnAnOlderPatchKeepsEverythingNewerAndItsOwn() throws {
        let home = try UV.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.install(home, UV.oldest, UV.older, UV.newest)
        try UV.minorLink(home, to: UV.older)
        #expect(UV.offered(home) == [UV.oldest])
    }

    @Test
    func aDanglingLinkOffersNothing() throws {
        let home = try UV.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.install(home, UV.oldest, UV.older)
        try UV.minorLink(home, to: "cpython-3.12.9-macos-aarch64-none")
        #expect(UV.offered(home).isEmpty)
    }

    @Test
    func aLinkOutOfUvsFolderOffersNothing() throws {
        let home = try UV.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.install(home, UV.oldest)
        try UV.write("x", home, "elsewhere/\(UV.newest)/bin/python3")
        try UV.link(home, "\(UV.root)/\(UV.minorLink)", to: home.appendingPathComponent("elsewhere/\(UV.newest)").path)
        #expect(UV.offered(home).isEmpty)
    }

    /// A link to the newest of another build doesn't speak for this one.
    @Test
    func eachBuildIsJudgedByItsOwnLink() throws {
        let home = try UV.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let threaded = "cpython-3.12.4+freethreaded-macos-aarch64-none"
        try UV.install(home, UV.oldest, UV.newest, threaded)
        try UV.minorLink(home, to: UV.newest)
        // The plain link points at a newer patch, but of another build.
        try UV.minorLink(home, "cpython-3.12+freethreaded-macos-aarch64-none", to: UV.newest)
        #expect(UV.offered(home) == [UV.oldest])
    }

    /// Another link in uv's folder that leads into a version keeps it.
    @Test
    func anyOtherLinkInUvsFolderKeepsItsVersion() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.link(home, "\(UV.root)/my-python", to: UV.path(home, UV.oldest))
        #expect(UV.offered(home) == [UV.older])
        #expect(!UV.gateKeeps(home, UV.oldest))
    }

    @Test
    func aFreshOrUnfinishedInstallIsNotOffered() throws {
        let home = try UV.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.install(home, UV.newest)
        try UV.install(home, age: 60, UV.oldest)
        try UV.install(home, UV.older)
        try FileManager.default.removeItem(atPath: "\(UV.path(home, UV.older))/bin/python3")
        try UV.minorLink(home, to: UV.newest)
        #expect(UV.offered(home).isEmpty)
        // A day later the fresh one is offered.
        #expect(UV.offered(home, now: Date().addingTimeInterval(UV.day + 60)) == [UV.oldest])
    }

    @Test
    func aLinkedUvFolderOffersNothing() throws {
        let base = try UV.makeHome()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/share"), withIntermediateDirectories: true)
        let real = base.appendingPathComponent("real-uv", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".local/share/uv"), withDestinationURL: real
        )
        try UV.install(home, UV.oldest, UV.newest)
        try UV.minorLink(home, to: UV.newest)
        #expect(UV.offered(home).isEmpty)
        #expect(!UV.gateKeeps(home, UV.oldest))
        #expect(!UV.movable(home, UV.oldest))
    }

    /// uv never links a patch name. One that is a link keeps every version.
    @Test
    func aPatchNameThatIsALinkKeepsEverything() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.link(home, "\(UV.root)/cpython-3.12.5-macos-aarch64-none", to: UV.path(home, UV.newest))
        #expect(UV.offered(home).isEmpty)
    }
}

@Suite("uv Python versions (#405): pins and environments")
struct UvPythonVersionKeepTests {
    @Test(arguments: [".python-version", ".config/uv/.python-version"])
    func aPinInHomeKeepsItsVersion(file: String) throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write("3.12.4\n", home, file)
        #expect(UV.offered(home) == [UV.older])
        #expect(!UV.gateKeeps(home, UV.oldest))
    }

    @Test(arguments: [
        ("3.12.6", true), ("cpython-3.12.6", true), ("3.12.6+freethreaded", true), ("cpython@3.12.6", true),
        ("# a comment\n3.12.6\n", true), ("==3.12.6", true),
        // A range or a wildcard may be met by this version alone, and Purge doesn't work ranges out.
        (">=3.12.3,<3.12.5", true), ("3.12.*", true), ("~=3.11", true),
        ("3.12", false), ("3", false), ("3.12.60", false), ("13.12.6", false), ("3.12.6.1", false), ("", false),
    ])
    func whatAPinNames(text: String, keeps: Bool) throws {
        #expect(UvPythonVersionPolicy.pinNames(text, folder: UV.older) == keeps, "\(text)")
    }

    @Test
    func aProjectPinKeepsItsVersion() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        let recorded = UV.recorded(home, project: "code/app")
        try UV.write("3.12.6\n", home, "code/app/.python-version")
        #expect(UV.offered(home, UV.context(recorded: recorded)) == [UV.oldest])
        // A pin in a folder above the project counts too.
        try UV.write("3.12.4\n", home, "code/.python-version")
        #expect(UV.offered(home, UV.context(recorded: recorded)).isEmpty)
    }

    @Test
    func aPinAddedAfterTheScanStopsTheMove() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = UV.context(recorded: UV.recorded(home, project: "code/app"))
        #expect(UV.offered(home, context) == [UV.oldest, UV.older])
        try UV.write("3.12.4\n", home, "code/app/.python-version")
        #expect(!UV.movable(home, UV.oldest, context))
        #expect(UV.movable(home, UV.older, context))
    }

    /// uv also takes a path to an interpreter, which may be a link into a version.
    @Test
    func aPinThatIsAPathKeepsWhereItLeads() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.link(home, "tools/python-for-app", to: "\(UV.path(home, UV.older))/bin/python3.12")
        try UV.write("../../tools/python-for-app\n", home, "code/app/.python-version")
        let context = UV.context(recorded: UV.recorded(home, project: "code/app"))
        #expect(UV.offered(home, context) == [UV.oldest])
        // A path Purge may not follow keeps every version.
        let tools = home.appendingPathComponent("tools/python-for-app").path
        #expect(UV.offered(home, UV.context(recorded: context.recordedFiles(), mayRead: { $0 != tools })).isEmpty)
        // Even one written inside a version: a link on the way may lead elsewhere.
        let inside = "\(UV.path(home, UV.older))/bin/python3"
        try UV.write("\(inside)\n", home, "code/app/.python-version")
        #expect(UV.offered(home, UV.context(recorded: context.recordedFiles(), mayRead: { $0 != inside })).isEmpty)
    }

    @Test
    func aPinNamingTheMinorKeepsNothing() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write("3.12\n", home, ".python-version")
        #expect(UV.offered(home) == [UV.oldest, UV.older])
    }

    /// uv tool environments are always pinned to a patch folder.
    @Test
    func aToolEnvironmentKeepsItsVersion() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write(
            "home = \(UV.path(home, UV.oldest))/bin\nimplementation = CPython\nuv = 0.13.9\nversion_info = 3.12.4\n",
            home, ".local/share/uv/tools/ruff/pyvenv.cfg"
        )
        #expect(UV.offered(home) == [UV.older])
        #expect(!UV.gateKeeps(home, UV.oldest))
        #expect(!UV.movable(home, UV.oldest))
    }

    @Test(arguments: [
        ".local/pipx/venvs/black", ".local/share/pipx/venvs/black", ".virtualenvs/work",
        ".local/share/virtualenvs/app-AbC12345", "Library/Application Support/pdm/venvs/app-AbC123-3.12",
        "Library/Caches/pypoetry/virtualenvs/app-abc123-py3.12", ".venv",
    ])
    func environmentsInHomeKeepTheirVersion(folder: String) throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write("home = \(UV.path(home, UV.older))/bin\n", home, "\(folder)/pyvenv.cfg")
        #expect(UV.offered(home) == [UV.oldest])
    }

    /// Only `bin/python` may name the version, as in an environment whose
    /// `pyvenv.cfg` was edited by hand.
    @Test
    func theEnvironmentsPythonLinkKeepsItsVersion() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write("include-system-site-packages = false\n", home, ".virtualenvs/work/pyvenv.cfg")
        try UV.link(home, ".virtualenvs/work/bin/python", to: "\(UV.path(home, UV.older))/bin/python3.12")
        #expect(UV.offered(home) == [UV.oldest])
    }

    @Test
    func aProjectEnvironmentKeepsItsVersion() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = UV.context(recorded: UV.recorded(home, project: "code/app"))
        try UV.write("home = \(UV.path(home, UV.oldest))/bin\n", home, "code/app/.venv/pyvenv.cfg")
        #expect(UV.offered(home, context) == [UV.older])
        // One made after the scan stops the move.
        try UV.write("home = \(UV.path(home, UV.older))/bin\n", home, "code/app/venv/pyvenv.cfg")
        #expect(!UV.movable(home, UV.older, context))
    }

    /// `UV_PROJECT_ENVIRONMENT` may give a project's environment another name.
    /// The project is listed again at the scan and the move, so one made after
    /// the walk counts too.
    @Test
    func aProjectEnvironmentWithAnotherNameKeepsItsVersion() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("code/app/src"), withIntermediateDirectories: true
        )
        let recorded = UV.recorded(home, project: "code/app")
        #expect(recorded.contains(home.appendingPathComponent("code/app/*").path))
        let context = UV.context(recorded: recorded)
        #expect(UV.offered(home, context) == [UV.oldest, UV.older])
        try UV.write("home = \(UV.path(home, UV.older))/bin\n", home, "code/app/env/pyvenv.cfg")
        #expect(UV.offered(home, context) == [UV.oldest])
        #expect(!UV.movable(home, UV.older, context))
        // A project Purge can't list keeps every version. One that is gone keeps none.
        let project = home.appendingPathComponent("code/app").path
        #expect(UV.offered(home, UV.context(recorded: recorded, mayRead: { $0 != project })).isEmpty)
        try FileManager.default.removeItem(atPath: project)
        #expect(UV.offered(home, context) == [UV.oldest, UV.older])
    }

    /// A `bin/python` Purge can't look at may be a link into a version.
    @Test
    func anEnvironmentWhosePythonCantBeCheckedKeepsEverything() throws {
        let home = try UV.makeUv()
        let bin = home.appendingPathComponent(".virtualenvs/work/bin")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            try? FileManager.default.removeItem(at: home)
        }
        try UV.write("home = /nowhere\n", home, ".virtualenvs/work/pyvenv.cfg")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bin.path)
        #expect(UV.offered(home).isEmpty)
    }

    /// An environment made through the minor link follows it to the newest patch.
    @Test
    func anEnvironmentOnTheMinorLinkKeepsNothingOld() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write("home = \(UV.path(home, UV.minorLink))/bin\n", home, ".virtualenvs/work/pyvenv.cfg")
        try UV.link(home, ".virtualenvs/work/bin/python", to: "\(UV.path(home, UV.minorLink))/bin/python3.12")
        #expect(UV.offered(home) == [UV.oldest, UV.older])
    }

    /// A path through a link to uv's folder still names the version.
    @Test
    func anotherSpellingOfThePathCounts() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.link(home, "pythons", to: home.appendingPathComponent(UV.root).path)
        try UV.write("home = \(home.path)/PYTHONS/\(UV.older)/bin\n", home, ".virtualenvs/work/pyvenv.cfg")
        #expect(UV.offered(home) == [UV.oldest])
    }

    @Test
    func whatCantBeReadKeepsEverything() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        // Before a walk with Full Disk Access saved the list.
        #expect(UV.offered(home, UV.context(recorded: nil)).isEmpty)
        #expect(!UV.gateKeeps(home, UV.oldest, UV.context(recorded: nil)))
        #expect(!UV.movable(home, UV.oldest, UV.context(recorded: nil)))
        // A pin macOS would ask about.
        let pin = home.appendingPathComponent(".python-version").path
        #expect(UV.offered(home, UV.context(mayRead: { $0 != pin })).isEmpty)
        // An environment macOS would ask about.
        try UV.write("home = /nowhere\n", home, ".virtualenvs/work/pyvenv.cfg")
        let config = home.appendingPathComponent(".virtualenvs/work/pyvenv.cfg").path
        #expect(UV.offered(home, UV.context(mayRead: { $0 != config })).isEmpty)
        // A folder of environments macOS would ask about.
        let poetry = home.appendingPathComponent("Library/Caches/pypoetry/virtualenvs").path
        #expect(UV.offered(home, UV.context(mayRead: { $0 != poetry })).isEmpty)
        #expect(UV.offered(home) == [UV.oldest, UV.older])
    }
}

@Suite("uv Python versions (#405): outside uv's folder")
struct UvPythonVersionOutsideTests {
    @Test
    func aReferenceFileKeepsItsVersion() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write("export PATH=\"\(UV.path(home, UV.oldest))/bin:$PATH\"\n", home, ".zshrc")
        #expect(UV.offered(home) == [UV.older])
        // The list gate reads small files only, so the move catches it.
        #expect(UV.gateKeeps(home, UV.oldest))
        #expect(!UV.movable(home, UV.oldest))
    }

    /// PyCharm keeps the interpreters it knows in each JetBrains IDE's SDK
    /// table, and a Jupyter kernel spec starts with an interpreter path.
    @Test(arguments: [
        ("Library/Application Support/JetBrains/PyCharm2026.2/options/jdk.table.xml",
         "<jdk><homePath value=\"$USER_HOME$/.local/share/uv/python/\(UV.older)/bin/python3.12\" /></jdk>"),
        ("Library/Jupyter/kernels/py312/kernel.json",
         "{\"argv\": [\"/opt/py/\(UV.older)/bin/python3.12\", \"-m\", \"ipykernel_launcher\"]}"),
    ])
    func anInterpreterSettingKeepsItsVersion(file: String, text: String) throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write(text, home, file)
        #expect(UV.offered(home) == [UV.oldest])
        #expect(!UV.movable(home, UV.older))
        // A folder of them Purge can't list keeps every version.
        let parent = file.split(separator: "/").prefix(3).joined(separator: "/")
        let blocked = home.appendingPathComponent(parent).path
        #expect(UV.offered(home, UV.context(mayRead: { $0 != blocked })).isEmpty)
    }

    @Test
    func aLaunchAgentNamingTheFolderKeepsIt() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write(
            "<plist><dict><key>Program</key><string>/opt/py/\(UV.older)/bin/python3</string></dict></plist>",
            home, "Library/LaunchAgents/com.example.job.plist"
        )
        #expect(UV.offered(home) == [UV.oldest])
    }

    /// uv's own `python3.12` link in `~/.local/bin` may point at a patch folder.
    @Test
    func aBinLinkKeepsItsVersion() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.link(home, ".local/bin/python3.12", to: "\(UV.path(home, UV.older))/bin/python3.12")
        #expect(UV.offered(home) == [UV.oldest])
        #expect(!UV.movable(home, UV.older))
    }

    /// A folder of programs that lists but can't be searched gives no answer.
    @Test
    func aProgramFolderThatCantBeSearchedKeepsEverything() throws {
        let home = try UV.makeUv()
        let programs = home.appendingPathComponent(".cargo/bin")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: programs.path)
            try? FileManager.default.removeItem(at: home)
        }
        try UV.write("x", home, ".cargo/bin/tool")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: programs.path)
        #expect(UV.offered(home).isEmpty)
    }

    /// uv names `libpython` by its whole path, so a program linked against it
    /// carries the folder's name.
    @Test
    func aProgramThatLoadsItsLibpythonKeepsIt() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        try UV.write(
            "\u{CF}\u{FA}\u{ED}\u{FE}...\(UV.path(home, UV.oldest))/lib/libpython3.12.dylib...",
            home, ".cargo/bin/pyo3-tool"
        )
        #expect(UV.offered(home) == [UV.older])
        #expect(!UV.movable(home, UV.oldest))
    }

    /// A universal program keeps each slice's load commands at its own
    /// offset, which can begin far past the first read.
    @Test
    func aLaterSliceOfAUniversalProgramCounts() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        let needle = Data("\(UV.path(home, UV.oldest))/lib/libpython3.12.dylib".utf8)
        let first = UInt32(4096), firstSize = UInt32(300_000)
        let second = first + firstSize, secondSize = UInt32(8192)
        var file = Data()
        func put(_ value: UInt32) { file.append(contentsOf: withUnsafeBytes(of: value.bigEndian, Array.init)) }
        put(0xCAFE_BABE); put(2)
        put(0x0100_0007); put(3); put(first); put(firstSize); put(12)
        put(0x0100_000C); put(0); put(second); put(secondSize); put(14)
        file.append(Data(count: Int(second) - file.count))
        file.append(needle)
        file.append(Data(count: Int(secondSize) - needle.count))
        let program = home.appendingPathComponent(".cargo/bin/pyo3-tool")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: program)
        #expect(UV.offered(home) == [UV.older])
        #expect(!UV.movable(home, UV.oldest))
        // A header naming a slice past the end of the file can't be read whole.
        var broken = file.prefix(Int(second))
        broken.append(Data(count: 16))
        try broken.write(to: program)
        #expect(UV.offered(home).isEmpty)
    }

    @Test
    func theMoveWaitsForUvAndOpenFiles() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(UV.movable(home, UV.oldest))
        #expect(!UV.movable(home, UV.oldest, UV.context(uvIsRunning: true)))
        #expect(!UV.movable(home, UV.oldest, UV.context(lsof: nil)))
        let binary = "\(UV.path(home, UV.oldest))/bin/python3.12"
        #expect(!UV.movable(home, UV.oldest, UV.context(lsof: "p123\nn\(binary)\n")))
        let other = "\(UV.path(home, UV.newest))/bin/python3.12"
        #expect(UV.movable(home, UV.oldest, UV.context(lsof: "p123\nn\(other)\n")))
        // The scan reads neither.
        #expect(UV.offered(home, UV.context(lsof: nil, uvIsRunning: true)) == [UV.oldest, UV.older])
    }

    /// The link is read again last, so uv moving it onto the version while the
    /// other checks ran stops the move.
    @Test
    func theMoveReadsTheLinkAgainLast() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        let link = home.appendingPathComponent("\(UV.root)/\(UV.minorLink)").path
        let older = UV.path(home, UV.older)
        let context = UvPythonVersionPolicy.Context(
            recordedFiles: { [] },
            mayRead: { _ in true },
            openFiles: {
                try? FileManager.default.removeItem(atPath: link)
                try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: older)
                return ""
            },
            uvIsRunning: { false },
            linkFolders: [".local/bin"],
            programFolders: [".cargo/bin"]
        )
        #expect(!UV.movable(home, UV.older, context))
    }

    @Test
    func otherPathsPassTheMoveCheck() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [UV.minorLink, ".lock"] {
            #expect(UV.movable(home, path, UV.context(uvIsRunning: true)), "\(path)")
        }
        #expect(UvPythonVersionPolicy.passesImmediateTrashBoundary(
            home.appendingPathComponent("Library/Caches/Homebrew"), home: home.path, context: UV.context(lsof: nil)
        ))
    }

    @Test
    func theDefaultMoveCheckRunsUvToo() throws {
        let home = try UV.makeUv()
        defer { try? FileManager.default.removeItem(at: home) }
        let nvm = NvmNodeVersionPolicy.Context(nvmrcFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, linkFolders: [])
        let vitePlus = VitePlusNodeVersionPolicy.Context(
            pinFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, linkFolders: []
        )
        let old = URL(fileURLWithPath: UV.path(home, UV.oldest))
        let check = FileDeleter.defaultImmediateMoveCheck(
            home: home.path, nvm: nvm, vitePlus: vitePlus, rustup: UV.inertRustup, uv: UV.context()
        )
        #expect(check(old))
        #expect(check(home.appendingPathComponent("Library/Caches/Homebrew")))
        let busy = FileDeleter.defaultImmediateMoveCheck(
            home: home.path, nvm: nvm, vitePlus: vitePlus, rustup: UV.inertRustup, uv: UV.context(uvIsRunning: true)
        )
        #expect(!busy(old), "uv's part runs")
    }
}
