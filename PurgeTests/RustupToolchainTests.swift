import Foundation
import Testing
@testable import Purge

/// Rust toolchains rustup keeps (#406). Each keep rule has its own test. Every
/// fixture is a throwaway home folder with a fake pin-file list, environment,
/// process list and `lsof`.
private enum RT {
    typealias Policy = RustupToolchainPolicy
    static let root = ".rustup/toolchains"
    static let stable = "stable-aarch64-apple-darwin"
    static let old = "1.84.0-aarch64-apple-darwin"
    static let nightly = "nightly-2024-05-01-aarch64-apple-darwin"
    static let day: TimeInterval = 24 * 60 * 60

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-406-\(UUID().uuidString)", isDirectory: true)
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

    /// A toolchain as rustup leaves it once an install is done, its records
    /// last written `age` ago.
    static func install(_ home: URL, in folder: String = root, age: TimeInterval = 2 * day, _ names: String...) throws {
        for name in names {
            try write("x", home, "\(folder)/\(name)/bin/rustc")
            try write("x", home, "\(folder)/\(name)/lib/rustlib/aarch64-apple-darwin/lib/libstd.rlib")
            for record in Policy.installRecords {
                try write("x", home, "\(folder)/\(name)/\(record)")
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-age)],
                    ofItemAtPath: home.appendingPathComponent("\(folder)/\(name)/\(record)").path
                )
            }
        }
    }

    /// `settings.toml` as rustup 1.29 writes it.
    static func settings(
        _ home: URL, default toolchain: String? = stable, overrides: [(String, String)] = []
    ) throws {
        var text = "version = \"12\"\n"
        if let toolchain { text += "default_toolchain = \"\(toolchain)\"\n" }
        text += "profile = \"default\"\n\n[overrides]\n"
        for (folder, name) in overrides { text += "\"\(folder)\" = \"\(name)\"\n" }
        try write(text, home, Policy.settingsFile)
    }

    /// The usual fixture: the default `stable`, one old version and one dated nightly.
    static func makeRustup() throws -> URL {
        let home = try makeHome()
        try install(home, stable, old, nightly)
        try settings(home)
        return home
    }

    /// An empty pin-file list unless a test gives one, every file readable, no
    /// `RUSTUP_TOOLCHAIN`, rustup idle, no open files, and only `~/.local/bin`
    /// searched for links.
    static func context(
        pins: [String]? = [],
        mayRead: @escaping @Sendable (String) -> Bool = { _ in true },
        lsof: String? = "",
        onLsof: @escaping @Sendable () -> Void = {},
        environment: [String] = [],
        rustupIsRunning: Bool = false,
        onProcessList: @escaping @Sendable () -> Void = {}
    ) -> Policy.Context {
        Policy.Context(
            pinFiles: { pins },
            mayRead: mayRead,
            openFiles: { onLsof(); return lsof },
            environment: { environment },
            rustupIsRunning: { onProcessList(); return rustupIsRunning },
            linkFolders: [".local/bin"]
        )
    }

    /// The pin files for a project at `relative`, as a Dev Projects walk records them.
    static func pins(_ home: URL, project relative: String) -> [String] {
        Policy.pinFiles(inProjectRoots: [home.appendingPathComponent(relative)])
    }

    /// The toolchain folders the Dev Tools scan offers, by name.
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
            rustup: context
        )
        .filter { Policy.toolchain(inLabel: $0.label) != nil }
    }

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
            rustup: context
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Suite("rustup toolchains (#406): shapes")
struct RustupToolchainShapeTests {
    private let home = "/Users/someone"

    @Test(arguments: [
        "1.84.0-aarch64-apple-darwin", "1.84-aarch64-apple-darwin", "1.84.0-x86_64-apple-darwin",
        "0.9.0-x86_64-apple-darwin", "1.100.0-aarch64-apple-darwin", "1.84.12-aarch64-apple-darwin",
        "1.84.0-beta-aarch64-apple-darwin", "1.84.0-beta.2-aarch64-apple-darwin",
        "nightly-2024-05-01-aarch64-apple-darwin", "beta-2024-05-01-x86_64-apple-darwin",
        "stable-2024-05-02-aarch64-apple-darwin",
    ])
    func versionsAndDatedChannelsAreTheShape(name: String) {
        let path = "\(home)/.rustup/toolchains/\(name)"
        #expect(OldToolVersionScanPolicy.kind(of: path, home: home) == .rustupToolchain, "\(name)")
        #expect(OldToolVersionScanPolicy.isWhitelistedPath(path, home: home), "\(name)")
    }

    @Test(arguments: [
        ".rustup", ".rustup/toolchains", ".rustup/settings.toml", ".rustup/downloads", ".rustup/tmp",
        ".rustup/update-hashes", ".rustup/update-hashes/1.84.0-aarch64-apple-darwin",
        // The moving channels, which `rustup update` tracks.
        ".rustup/toolchains/stable-aarch64-apple-darwin", ".rustup/toolchains/beta-aarch64-apple-darwin",
        ".rustup/toolchains/nightly-x86_64-apple-darwin",
        // Custom names, which `rustup toolchain install` can't bring back.
        ".rustup/toolchains/stage1", ".rustup/toolchains/esp", ".rustup/toolchains/my-nightly",
        ".rustup/toolchains/nightly-2024-05-01-custom",
        // No host, half a host, or a host no Mac runs.
        ".rustup/toolchains/1.84.0", ".rustup/toolchains/nightly-2024-05-01",
        ".rustup/toolchains/1.84.0-apple-darwin", ".rustup/toolchains/1.84.0-aarch64-unknown-linux-gnu",
        ".rustup/toolchains/1.84.0-aarch64-apple-darwin-extra",
        // Numbers outside rustup's own pattern are custom names to rustup.
        ".rustup/toolchains/10.0.0-aarch64-apple-darwin", ".rustup/toolchains/1.084.0-aarch64-apple-darwin",
        ".rustup/toolchains/1.1000.0-aarch64-apple-darwin", ".rustup/toolchains/1.84.100-aarch64-apple-darwin",
        ".rustup/toolchains/1.84.0.1-aarch64-apple-darwin", ".rustup/toolchains/1-aarch64-apple-darwin",
        ".rustup/toolchains/v1.84.0-aarch64-apple-darwin", ".rustup/toolchains/1.84.0-rc.1-aarch64-apple-darwin",
        ".rustup/toolchains/1.84.0-2025-01-09-aarch64-apple-darwin",
        ".rustup/toolchains/nightly-2024-5-1-aarch64-apple-darwin",
        ".rustup/toolchains/Nightly-2024-05-01-aarch64-apple-darwin",
        ".rustup/toolchains/.1.84.0-aarch64-apple-darwin",
        // Inside a toolchain, and the same names anywhere else.
        ".rustup/toolchains/1.84.0-aarch64-apple-darwin/bin",
        ".rustup/toolchains/1.84.0-aarch64-apple-darwin/lib/rustlib",
        ".cargo/toolchains/1.84.0-aarch64-apple-darwin", "rustup/toolchains/1.84.0-aarch64-apple-darwin",
        ".rustup/1.84.0-aarch64-apple-darwin",
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
        #expect(DeletionSafetyPolicy.evaluate(realHome(".rustup", "toolchains", RT.old)) == .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".rustup", "toolchains", RT.nightly)) == .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".rustup")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".rustup", "toolchains")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".rustup", "toolchains", RT.stable)) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".rustup", "toolchains", "stage1")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".rustup", "toolchains", RT.old, "bin")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".rustup", "update-hashes", RT.old)) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".rustup", "settings.toml")) != .allow)
    }

    @Test
    func labelsCarryTheWholeFolderName() {
        #expect(RustupToolchainPolicy.toolchain(inLabel: "rustup toolchain \(RT.old)") == RT.old)
        #expect(RustupToolchainPolicy.toolchain(inLabel: "rustup toolchain \(RT.stable)") == nil)
        #expect(RustupToolchainPolicy.toolchain(inLabel: "rustup toolchain 1.84.0") == nil)
        #expect(RustupToolchainPolicy.toolchain(inLabel: "rustup toolchain") == nil)
        #expect(RustupToolchainPolicy.toolchain(inLabel: "nvm Node.js 22.14.0") == nil)
        #expect(NvmNodeVersionPolicy.version(inLabel: "rustup toolchain \(RT.old)") == nil)
    }

    @Test
    func rowsAreCheckFirstAndSayHowToGetItBack() {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "rustup toolchain \(RT.old)", primaryPath: nil)
        #expect(info.level == .medium)
        #expect(info.headline.contains(RT.old))
        #expect(info.reinstallCommand == "rustup toolchain install \(RT.old)")
        #expect(BrandIconMapping.slug(forDefinitionKey: "rustup toolchain \(RT.old)") == "rust")
    }

    /// `rustup toolchain install` brings back the host's parts only, so the
    /// command names the targets the toolchain had.
    @Test
    func theReinstallCommandNamesAddedTargets() throws {
        let home = try RT.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.install(home, RT.nightly)
        let toolchain = home.appendingPathComponent("\(RT.root)/\(RT.nightly)")
        for target in ["wasm32-unknown-unknown", "thumbv7em-none-eabihf"] {
            try RT.write("x", home, "\(RT.root)/\(RT.nightly)/lib/rustlib/\(target)/lib/libcore.rlib")
        }
        // Not targets: the source component, and a folder with no `lib`.
        try RT.write("x", home, "\(RT.root)/\(RT.nightly)/lib/rustlib/src/rust/library/core/lib.rs")
        try RT.write("x", home, "\(RT.root)/\(RT.nightly)/lib/rustlib/etc/gdb_load_rust_pretty_printers.py")
        try RT.write("x", home, "\(RT.root)/\(RT.nightly)/lib/rustlib/some-thing/readme")
        let info = DevScanner.automaticSafetyInfo(
            forDevToolLabel: "rustup toolchain \(RT.nightly)", primaryPath: toolchain
        )
        #expect(info.reinstallCommand
            == "rustup toolchain install \(RT.nightly) --target thumbv7em-none-eabihf,wasm32-unknown-unknown")
    }

    @Test(arguments: [
        // rustup adds the host to a name without one.
        ("1.84.0", "1.84.0-aarch64-apple-darwin", true),
        ("1.84.0-aarch64-apple-darwin", "1.84.0-aarch64-apple-darwin", true),
        (" 1.84.0\n", "1.84.0-aarch64-apple-darwin", true),
        ("1.84.0-apple-darwin", "1.84.0-aarch64-apple-darwin", true),
        ("NIGHTLY-2024-05-01", "nightly-2024-05-01-aarch64-apple-darwin", true),
        ("nightly-2024-05-01-apple-darwin", "nightly-2024-05-01-x86_64-apple-darwin", true),
        // A minor version is its own toolchain, not any patch of it.
        ("1.84", "1.84-aarch64-apple-darwin", true),
        ("1.84", "1.84.0-aarch64-apple-darwin", false),
        ("1.84.0", "1.84-aarch64-apple-darwin", false),
        ("1.8", "1.84.0-aarch64-apple-darwin", false),
        // Part of a name keeps what starts with it, which errs on keeping.
        ("1.84.0", "1.84.0-beta.2-aarch64-apple-darwin", true),
        ("nightly", "nightly-2024-05-01-aarch64-apple-darwin", true),
        ("stable", "nightly-2024-05-01-aarch64-apple-darwin", false),
        ("nightly-2024-05-02", "nightly-2024-05-01-aarch64-apple-darwin", false),
        // Strings a settings or pin file also holds.
        ("12", "1.84.0-aarch64-apple-darwin", false),
        ("minimal", "1.84.0-aarch64-apple-darwin", false),
        ("aarch64-apple-darwin", "1.84.0-aarch64-apple-darwin", false),
        ("", "1.84.0-aarch64-apple-darwin", false),
    ])
    func namesMatchAsRustupResolvesThem(value: String, folder: String, expected: Bool) {
        #expect(RustupToolchainPolicy.names(value, folder: folder) == expected, "\(value) for \(folder)")
    }

    @Test
    func pinFilesCoverEveryFolderUpToTheRoot() {
        let files = RustupToolchainPolicy.pinFiles(inProjectRoots: [URL(fileURLWithPath: "/Users/me/code/app")])
        for folder in ["/Users/me/code/app", "/Users/me/code", "/Users/me", "/Users"] {
            for name in ["rust-toolchain", "rust-toolchain.toml"] {
                #expect(files.contains("\(folder)/\(name)"), "\(folder)/\(name)")
            }
        }
        #expect(files.contains("/rust-toolchain"))
        #expect(files.contains("/rust-toolchain.toml"))
    }

    @Test
    func aFailedSaveSetsAsideIntoItsOwnFile() throws {
        let folder = try RT.makeHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = NvmrcLedger(
            fileURL: folder.appendingPathComponent("rust-toolchain-files.json"),
            write: { data, url in
                if url.lastPathComponent == "rust-toolchain-files.json" { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        ledger.record(["/Users/me/code/app/rust-toolchain.toml"], home: "/Users/me", fullAccess: true, mayRead: { _ in true })
        #expect(ledger.files() == nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("rust-toolchain-files.unsaved.json").path))
        // nvm's own set-aside file, which would make nvm's list untrusted, is never written.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(NvmrcLedger.unsavedFileName).path))
    }

    @Test
    func theDefaultMoveCheckRunsRustupToo() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let nvm = NvmNodeVersionPolicy.Context(nvmrcFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, linkFolders: [])
        let vitePlus = VitePlusNodeVersionPolicy.Context(
            pinFiles: { [] }, mayRead: { _ in true }, openFiles: { "" }, linkFolders: []
        )
        func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }
        let check = FileDeleter.defaultImmediateMoveCheck(home: home.path, nvm: nvm, vitePlus: vitePlus, rustup: RT.context())
        #expect(check(path("\(RT.root)/\(RT.old)")))
        #expect(check(path("Library/Caches/something")))
        let pinned = FileDeleter.defaultImmediateMoveCheck(
            home: home.path, nvm: nvm, vitePlus: vitePlus, rustup: RT.context(environment: ["1.84.0"])
        )
        #expect(!pinned(path("\(RT.root)/\(RT.old)")), "rustup's part runs")
        let busy = FileDeleter.defaultImmediateMoveCheck(
            home: home.path, nvm: nvm, vitePlus: vitePlus, rustup: RT.context(lsof: nil)
        )
        #expect(!busy(path("\(RT.root)/\(RT.old)")))
    }
}

@Suite("rustup toolchains (#406): what stays")
struct RustupToolchainKeepTests {

    @Test
    func aToolchainNothingNamesIsOfferedAndTheMovingChannelNeverIs() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.install(home, "beta-aarch64-apple-darwin", "stage1")
        #expect(Set(RT.offered(home)) == [RT.old, RT.nightly])
    }

    @Test
    func eachToolchainIsItsOwnRowAndTwoBuildsOfOneVersionAreTwo() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let intel = "1.84.0-x86_64-apple-darwin"
        try RT.install(home, intel)
        let rows = RT.rows(home)
        #expect(Set(rows.map(\.label)) == Set([RT.old, intel, RT.nightly].map { "rustup toolchain \($0)" }))
        #expect(rows.allSatisfy { $0.paths.count == 1 })
    }

    @Test
    func theDefaultStays() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.settings(home, default: RT.old)
        #expect(RT.offered(home) == [RT.nightly])
    }

    @Test(arguments: ["nightly-2024-05-01-aarch64-apple-darwin", "nightly-2024-05-01", "NIGHTLY-2024-05-01"])
    func aDirectoryOverrideKeepsItsToolchain(value: String) throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        // The folder need not be there: rustup keeps an override until it is unset.
        try RT.settings(home, overrides: [("/Users/me/code/app = b #2", value)])
        #expect(RT.offered(home) == [RT.old], "\(value)")
    }

    /// Without settings Purge understands, it can't tell what rustup runs.
    @Test(arguments: [
        "",
        "default_toolchain = \"stable-aarch64-apple-darwin\"\n",
        "version = \"2\"\ndefault_toolchain = \"stable-aarch64-apple-darwin\"\n",
        "version = \"13\"\ndefault_toolchain = \"stable-aarch64-apple-darwin\"\n",
        "version = 12\ndefault_toolchain = \"stable-aarch64-apple-darwin\"\n",
        // No default: every use goes through routes Purge sees least.
        "version = \"12\"\nprofile = \"default\"\n\n[overrides]\n",
        "version = \"12\"\ndefault_toolchain = \"\"\n",
        "version = \"12\"\ndefault_toolchain = \"stable\"\ndefault_toolchain = \"1.84.0\"\n",
        "version = \"12\"\n[overrides]\ndefault_toolchain = \"stable-aarch64-apple-darwin\"\n",
        // Forms the reader doesn't take.
        "version = \"12\"\ndefault_toolchain = \"stable\"\n\n[other]\nkey = \"x\"\n",
        "version = \"12\"\ndefault_toolchain = \"stable\"\nlist = [\"a\"]\n",
        "version = \"12\"\ndefault_toolchain = \"\"\"stable\"\"\"\n",
        "version = \"12\"\ndefault_toolchain = \"stable\"\noverrides = { \"/a\" = \"1.84.0\" }\n",
        "version = \"12\"\ndefault_toolchain = \"stable\"\noverrides.\"/a\" = \"1.84.0\"\n",
        "version = \"12\"\ndefault_toolchain = \"sta\\u0062le\"\n",
        "version = \"12\"\ndefault_toolchain = \"stable\"\nnot a line\n",
    ])
    func settingsPurgeCannotReadKeepEverything(text: String) throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.write(text, home, RustupToolchainPolicy.settingsFile)
        #expect(RT.offered(home).isEmpty, "\(text.debugDescription)")
    }

    @Test
    func missingOrUnreadableSettingsKeepEverything() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(RustupToolchainPolicy.settingsFile).path
        #expect(RT.offered(home, RT.context(mayRead: { $0 != settings })).isEmpty)
        try FileManager.default.removeItem(atPath: settings)
        #expect(RT.offered(home).isEmpty)
        try FileManager.default.createDirectory(atPath: settings, withIntermediateDirectories: true)
        #expect(RT.offered(home).isEmpty)
    }

    @Test(arguments: ["1.84.0", "1.84.0-aarch64-apple-darwin", "1.84.0-apple-darwin"])
    func theEnvironmentVariableKeepsItsToolchain(value: String) throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(RT.offered(home, RT.context(environment: ["stable", value])) == [RT.nightly], "\(value)")
    }

    @Test
    func theEnvironmentVariableMayBeAPath() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("\(RT.root)/\(RT.old)").path
        #expect(RT.offered(home, RT.context(environment: [path])) == [RT.nightly])
        // A path macOS would ask about following keeps everything.
        let elsewhere = "/Users/someone/Documents/rust/build/stage1"
        #expect(RT.offered(home, RT.context(mayRead: { $0 != elsewhere }, environment: [elsewhere])).isEmpty)
    }

    @Test(arguments: [
        ("rust-toolchain", "1.84.0\n"),
        ("rust-toolchain", "1.84.0"),
        ("rust-toolchain", "  1.84.0-aarch64-apple-darwin  \n"),
        ("rust-toolchain", "[toolchain]\nchannel = \"1.84.0\"\n"),
        ("rust-toolchain.toml", "[toolchain]\nchannel = \"1.84.0\"\n"),
        ("rust-toolchain.toml", "[toolchain]\nchannel = '1.84.0'\nprofile = \"minimal\"\n"),
        ("rust-toolchain.toml", "# pinned for CI\n[ toolchain ] # see docs\nchannel=\"1.84.0\" # exact\r\n"),
        ("rust-toolchain.toml",
         "[toolchain]\ncomponents = [\n  \"rustfmt\", # see [docs\n  'clippy',\n]\ntargets = [\"wasm32-unknown-unknown\"]\nchannel = \"1.84.0\"\n"),
        // Not what rustup reads, but a string in the file all the same.
        ("rust-toolchain.toml", "channel = \"1.84.0\"\n"),
    ])
    func aProjectPinKeepsItsToolchain(name: String, text: String) throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.write(text, home, "code/app/\(name)")
        #expect(RT.offered(home, RT.context(pins: RT.pins(home, project: "code/app"))) == [RT.nightly],
                "\(name): \(text.debugDescription)")
    }

    @Test
    func aPinAboveTheProjectOrInHomeCounts() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.write("[toolchain]\nchannel = \"nightly-2024-05-01\"\n", home, "code/rust-toolchain.toml")
        #expect(RT.offered(home, RT.context(pins: RT.pins(home, project: "code/workspace/app"))) == [RT.old])
        // rustup also runs in home itself, where no project is recorded.
        try RT.write("1.84.0\n", home, "rust-toolchain")
        #expect(RT.offered(home) == [RT.nightly])
    }

    @Test
    func aMinorPinKeepsTheMinorToolchainOnly() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let minor = "1.84-aarch64-apple-darwin"
        try RT.install(home, minor)
        try RT.write("[toolchain]\nchannel = \"1.84\"\n", home, "code/app/rust-toolchain.toml")
        #expect(Set(RT.offered(home, RT.context(pins: RT.pins(home, project: "code/app")))) == [RT.old, RT.nightly])
    }

    @Test
    func aPathInAPinKeepsTheToolchainItLeadsInto() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let toolchain = home.appendingPathComponent("\(RT.root)/\(RT.old)").path
        try RT.write("[toolchain]\npath = \"\(toolchain)\"\n", home, "code/app/rust-toolchain.toml")
        #expect(RT.offered(home, RT.context(pins: RT.pins(home, project: "code/app"))) == [RT.nightly])
        // An older rustup read a path from the pin file's folder.
        try RT.write(
            "[toolchain]\npath = \"../../.rustup/toolchains/\(RT.nightly)\"\n", home, "code/app/rust-toolchain.toml"
        )
        #expect(RT.offered(home, RT.context(pins: RT.pins(home, project: "code/app"))) == [RT.old])
    }

    /// A pin Purge can't read or understand may name any toolchain.
    @Test(arguments: [
        ("rust-toolchain.toml", "[toolchain]\nchannel = \"\"\"\n1.84.0\"\"\"\n"),
        ("rust-toolchain.toml", "[toolchain]\nchannel = '''1.84.0'''\n"),
        ("rust-toolchain.toml", "[toolchain]\nchannel = \"1.84\\u002E0\"\n"),
        ("rust-toolchain.toml", "[[toolchain]]\nchannel = \"stable\"\n"),
        ("rust-toolchain.toml", "[\"toolchain\"]\nchannel = \"stable\"\n"),
        ("rust-toolchain.toml", "[tool]\nchannel = \"stable\"\n"),
        ("rust-toolchain.toml", "toolchain.channel = \"stable\"\n"),
        ("rust-toolchain.toml", "toolchain = { channel = \"stable\" }\n"),
        ("rust-toolchain.toml", "[toolchain]\ncomponents = [\"rustfmt\"\n"),
        ("rust-toolchain.toml", "[toolchain]\ncomponents = [1, 2]\n"),
        ("rust-toolchain.toml", "[toolchain]\nchannel = \"stable\" extra\n"),
        ("rust-toolchain.toml", "[toolchain]\u{2028}channel = \"stable\"\n"),
        ("rust-toolchain.toml", "stable\n"),
        // Two lines are TOML to rustup, and this isn't.
        ("rust-toolchain", "stable\n1.84.0\n"),
        ("rust-toolchain", "stable\u{0}\n"),
    ])
    func aPinPurgeCannotUnderstandKeepsEverything(name: String, text: String) throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.write(text, home, "code/app/\(name)")
        #expect(RT.offered(home, RT.context(pins: RT.pins(home, project: "code/app"))).isEmpty,
                "\(name): \(text.debugDescription)")
    }

    @Test
    func aPinPurgeMayNotReadKeepsEverything() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let pins = RT.pins(home, project: "Documents/app")
        let guarded = home.appendingPathComponent("Documents").path
        #expect(RT.offered(home, RT.context(pins: pins, mayRead: { !$0.hasPrefix(guarded) })).isEmpty)
        #expect(Set(RT.offered(home, RT.context(pins: pins))) == [RT.old, RT.nightly])
    }

    @Test
    func noRecordedProjectsYetKeepsEverything() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(RT.offered(home, RT.context(pins: nil)).isEmpty)
    }

    @Test
    func aPinOnADriveThatMayOnlyBeUnpluggedKeepsEverything() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let pin = "/Volumes/purge-test-406-\(UUID().uuidString)/app/rust-toolchain.toml"
        #expect(RT.offered(home, RT.context(pins: [pin])).isEmpty)
    }

    @Test
    func aLinkedToolchainKeepsTheOneItLeadsInto() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.link(home, "\(RT.root)/mine", to: home.appendingPathComponent("\(RT.root)/\(RT.old)").path)
        // One that leads elsewhere, as `rustup toolchain link` makes, keeps nothing.
        try RT.write("x", home, "code/rust/build/stage1/bin/rustc")
        try RT.link(home, "\(RT.root)/stage1", to: home.appendingPathComponent("code/rust/build/stage1").path)
        #expect(RT.offered(home) == [RT.nightly])
    }

    @Test
    func anInstallThatIsUnfinishedOrJustChangedStays() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        // Still being installed: rustup writes its records last.
        try RT.write("x", home, "\(RT.root)/1.80.0-aarch64-apple-darwin/bin/rustc")
        // Installed an hour ago, or just given a component.
        try RT.install(home, age: 60 * 60, "1.81.0-aarch64-apple-darwin")
        // Not from a release manifest, so rustup can't install it again.
        try RT.install(home, "1.82.0-aarch64-apple-darwin")
        try FileManager.default.removeItem(
            at: home.appendingPathComponent("\(RT.root)/1.82.0-aarch64-apple-darwin/\(RustupToolchainPolicy.releaseManifest)")
        )
        #expect(Set(RT.offered(home)) == [RT.old, RT.nightly])
        // The hour-old one is offered once its day has passed.
        let later = Date().addingTimeInterval(RT.day)
        #expect(Set(RT.offered(home, now: later)) == [RT.old, RT.nightly, "1.81.0-aarch64-apple-darwin"])
    }

    @Test
    func aLinkOnTheWayIsNeverFollowed() throws {
        let home = try RT.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.install(home, in: "elsewhere/toolchains", RT.stable, RT.old)
        try RT.settings(home)
        try RT.link(home, RT.root, to: home.appendingPathComponent("elsewhere/toolchains").path)
        #expect(RT.offered(home).isEmpty)
        #expect(!RT.movable(home, RT.old))

        let other = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: other) }
        // A toolchain that is itself a link, under a name rustup would give.
        let linked = "1.70.0-aarch64-apple-darwin"
        try RT.link(other, "\(RT.root)/\(linked)", to: other.appendingPathComponent("\(RT.root)/\(RT.old)").path)
        #expect(RT.offered(other) == [RT.nightly], "the link is not offered, and what it leads into stays")
    }

    @Test(arguments: [
        (".zshrc", "alias ct='cargo +1.84.0 test'\n"),
        (".zshrc", "cargo +1.84.0-aarch64-apple-darwin build\n"),
        (".config/fish/config.fish", "set PATH $HOME/.rustup/toolchains/1.84.0-aarch64-apple-darwin/bin $PATH\n"),
        (".cargo/config.toml", "[build]\nrustc = \"/Users/me/.rustup/toolchains/1.84.0-aarch64-apple-darwin/bin/rustc\"\n"),
        (".config/zed/settings.json", #"{"lsp":{"rust-analyzer":{"binary":{"path":"~\/.rustup\/toolchains\/1.84.0-aarch64-apple-darwin\/bin\/rust-analyzer"}}}}"#),
        ("Library/LaunchAgents/dev.example.build.plist",
         "<plist><dict><key>ProgramArguments</key><array><string>cargo</string><string>+1.84.0</string></array></dict></plist>"),
    ])
    func aReferenceFileKeepsTheToolchainItNames(file: String, text: String) throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.write(text, home, file)
        #expect(RT.offered(home) == [RT.nightly], "\(file)")
    }

    @Test(arguments: [
        (".zshrc", "export RUSTUP_TOOLCHAIN=nightly-2024-05-01\n"),
        ("Library/Application Support/Code/User/settings.json",
         #"{"rust-analyzer.server.extraEnv":{"RUSTUP_TOOLCHAIN":"1.84.0"}}"#),
    ])
    func theVariableInAReferenceFileKeepsEverything(file: String, text: String) throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.write(text, home, file)
        #expect(RT.offered(home).isEmpty, "\(file)")
    }

    @Test
    func aLongerNameInAReferenceFileIsNotThisToolchain() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.write("cargo +1.84.01 build\ncargo +1.84 build\ncargo +1.84.0.1 x\n", home, ".zshrc")
        #expect(Set(RT.offered(home)) == [RT.old, RT.nightly])
    }

    @Test
    func aReferenceFilePurgeMayNotReadKeepsEverything() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = home.appendingPathComponent("Library/LaunchAgents").path
        #expect(RT.offered(home, RT.context(mayRead: { $0 != agents })).isEmpty)
    }

    @Test
    func aLinkInABinFolderKeepsItsToolchain() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        try RT.link(home, ".local/bin/rust-analyzer", to: home.appendingPathComponent("\(RT.root)/\(RT.old)/bin/rustc").path)
        #expect(RT.offered(home) == [RT.nightly])
    }

    @Test
    func kaniAndDylintKeepTheNightlyTheyUse() throws {
        let kani = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: kani) }
        try RT.link(kani, ".kani/kani-0.56.0/toolchain", to: kani.appendingPathComponent("\(RT.root)/\(RT.nightly)").path)
        #expect(RT.offered(kani) == [RT.old])

        let dylint = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: dylint) }
        try RT.write("x", dylint, ".dylint_drivers/\(RT.nightly)/dylint-driver")
        #expect(RT.offered(dylint) == [RT.old])
    }
}

@Suite("rustup toolchains (#406): the move")
struct RustupToolchainMoveTests {

    @Test
    func theListGateNeverRunsLsofOrListsProcesses() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let calls = Counter()
        let context = RT.context(onLsof: { calls.add() }, onProcessList: { calls.add() })
        #expect(RT.gateKeeps(home, RT.old, context))
        #expect(Set(RT.offered(home, context)) == [RT.old, RT.nightly])
        #expect(calls.value == 0)
        #expect(RT.movable(home, RT.old, context))
        #expect(calls.value == 2)
    }

    @Test
    func aProcessUsingTheToolchainStopsTheMove() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("\(RT.root)/\(RT.old)/bin/rustc").path
        #expect(RT.movable(home, RT.old))
        #expect(!RT.movable(home, RT.old, RT.context(lsof: "p123\nn\(binary)\n")))
        #expect(!RT.movable(home, RT.old, RT.context(lsof: nil)))
        // Another toolchain in use holds nothing back.
        let other = home.appendingPathComponent("\(RT.root)/\(RT.stable)/bin/rustc").path
        #expect(RT.movable(home, RT.old, RT.context(lsof: "p123\nn\(other)\n")))
    }

    @Test
    func rustupAtWorkStopsTheMove() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!RT.movable(home, RT.old, RT.context(rustupIsRunning: true)))
        // The scan still lists it: only a move asks.
        #expect(Set(RT.offered(home, RT.context(rustupIsRunning: true))) == [RT.old, RT.nightly])
    }

    @Test
    func whatChangedAfterTheScanStopsTheMove() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        let pins = RT.pins(home, project: "code/app")
        let context = RT.context(pins: pins)
        #expect(Set(RT.offered(home, context)) == [RT.old, RT.nightly])

        // A pin added to a recorded project.
        try RT.write("[toolchain]\nchannel = \"1.84.0\"\n", home, "code/app/rust-toolchain.toml")
        #expect(!RT.movable(home, RT.old, context))
        #expect(RT.movable(home, RT.nightly, context))

        // `rustup default`, and `rustup override set`.
        try RT.settings(home, default: RT.nightly)
        #expect(!RT.movable(home, RT.nightly, context))
        try RT.settings(home, overrides: [("/Users/me/x", RT.nightly)])
        #expect(!RT.movable(home, RT.nightly, context))

        // A shell profile that now runs it.
        try RT.settings(home)
        try FileManager.default.removeItem(at: home.appendingPathComponent("code/app/rust-toolchain.toml"))
        #expect(RT.movable(home, RT.old, context))
        try RT.write("alias t='cargo +1.84.0 test'\n", home, ".zshrc")
        #expect(!RT.movable(home, RT.old, context))
    }

    /// The gate `isOfferedForCleanup` asks reads the small files again, so a
    /// row whose toolchain became the default is dropped before any move.
    @Test
    func theListGateRefusesWhatBecameTheDefault() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(RT.gateKeeps(home, RT.old))
        try RT.settings(home, default: RT.old)
        // Past the ten seconds the main-thread gate may answer from an earlier read.
        let later = Date().addingTimeInterval(NvmNodeVersionPolicy.recentReadLifetime + 1)
        #expect(!RT.gateKeeps(home, RT.old, now: later))
    }

    @Test
    func otherPathsPassTheMoveCheck() throws {
        let home = try RT.makeRustup()
        defer { try? FileManager.default.removeItem(at: home) }
        // Not this rule's to judge: other rules refuse them.
        for relative in ["\(RT.root)/\(RT.stable)", ".rustup", "Library/Caches/x", ".nvm/versions/node/v20.0.0"] {
            #expect(RustupToolchainPolicy.passesImmediateTrashBoundary(
                home.appendingPathComponent(relative), home: home.path, context: RT.context(lsof: nil)
            ), "\(relative)")
        }
    }
}

@Suite("rustup toolchains (#406): the TOML reader")
struct RustupTOMLTests {

    @Test
    func readsWhatRustupWrites() {
        let text = """
        version = "12"
        default_host_triple = "aarch64-apple-darwin"
        default_toolchain = "stable-aarch64-apple-darwin"
        profile = "default"
        auto_self_update = "disable"
        auto_install = true

        [overrides]
        "/Users/me/code/app" = "nightly-2024-05-01-aarch64-apple-darwin"
        "/Users/me/a \\"b\\" = c # d" = '1.84.0-aarch64-apple-darwin'

        """
        let read = RustupTOML.read(text, tables: ["overrides"], allowsArrays: false)
        #expect(read?.topLevel["version"] == ["12"])
        #expect(read?.topLevel["default_toolchain"] == ["stable-aarch64-apple-darwin"])
        #expect(read?.otherTopLevelKeys == ["auto_install"])
        #expect(read?.strings.contains("nightly-2024-05-01-aarch64-apple-darwin") == true)
        #expect(read?.strings.contains("1.84.0-aarch64-apple-darwin") == true)
        // A key is never a value, whatever it holds.
        #expect(read?.strings.contains { $0.contains("/Users/me") } == false)
        // A key under a table is not a top-level one.
        #expect(read?.topLevel.keys.contains { $0.contains("Users") } == false)
    }

    @Test
    func aKeyUnderATableIsNotTopLevel() {
        let read = RustupTOML.read(
            "version = \"12\"\n[overrides]\ndefault_toolchain = \"1.84.0\"\n", tables: ["overrides"], allowsArrays: false
        )
        #expect(read?.topLevel["default_toolchain"] == nil)
        #expect(read?.strings == ["12", "1.84.0"])
    }

    @Test
    func readsArraysOfStringsAcrossLines() {
        let text = "[toolchain]\ncomponents = [ \"rustfmt\", # one ] \"\n  'rustc-dev'\n  ,\n]\ntargets = []\nchannel = \"nightly-2020-07-10\"\n"
        let read = RustupTOML.read(text, tables: ["toolchain"], allowsArrays: true)
        #expect(read?.strings == ["rustfmt", "rustc-dev", "nightly-2020-07-10"])
        #expect(RustupTOML.read(text, tables: ["toolchain"], allowsArrays: false) == nil)
    }

    @Test
    func aHashOrBracketInsideAStringIsText() {
        let read = RustupTOML.read(
            "[toolchain]\nchannel = \"night#ly [toolchain]\" # real comment\n", tables: ["toolchain"], allowsArrays: true
        )
        #expect(read?.strings == ["night#ly [toolchain]"])
    }

    @Test(arguments: [
        "channel = \"\"\"\nx\"\"\"\n",
        "channel = '''x'''\n",
        "# a comment with \"\"\" in it\n",
        "[[toolchain]]\n",
        "[other]\n",
        "[toolchain.sub]\n",
        "[\"toolchain\"]\n",
        "[toolchain\n",
        "[toolchain] x\n",
        "a.b = \"x\"\n",
        "a = { b = \"x\" }\n",
        "a = \"x\\\"y\"\n",
        "a = \"unclosed\n",
        "a = 'unclosed\n",
        "a =\n",
        "= \"x\"\n",
        "a \"x\"\n",
        "a = \"x\" \"y\"\n",
        "a = [\"x\"\n",
        "a = [\"x\" \"y\"]\n",
        "a = [[\"x\"]]\n",
        "a = [1]\n",
        "a = \"x\"\rb = \"y\"\n",
        "a = \"x\"\u{0B}\n",
        "a = \"x\"\u{85}\n",
        "\u{FEFF}a = \"x\"\n",
        "just words\n",
    ])
    /// A byte-order mark is refused here, though one at the start of a file
    /// never arrives: reading the file as UTF-8 drops it, as rustup's TOML
    /// reader does.
    func refusesWhatItDoesNotRead(text: String) {
        #expect(RustupTOML.read(text, tables: ["toolchain"], allowsArrays: true) == nil, "\(text.debugDescription)")
    }

    @Test
    func theLegacyFileIsReadBothWays() {
        #expect(RustupToolchainPolicy.pinStrings("nightly-2021-01-21\n", legacyNameAllowed: true) == ["nightly-2021-01-21"])
        #expect(RustupToolchainPolicy.pinStrings("", legacyNameAllowed: true) == [])
        #expect(RustupToolchainPolicy.pinStrings("\n", legacyNameAllowed: true) == [""])
        #expect(RustupToolchainPolicy.pinStrings("[toolchain]\nchannel = \"1.84.0\"\n", legacyNameAllowed: true) == ["1.84.0"])
        #expect(RustupToolchainPolicy.pinStrings("stable\nbeta\n", legacyNameAllowed: true) == nil)
        // `rust-toolchain.toml` is never a bare name.
        #expect(RustupToolchainPolicy.pinStrings("nightly-2021-01-21\n", legacyNameAllowed: false) == nil)
        #expect(RustupToolchainPolicy.pinStrings("", legacyNameAllowed: false) == [])
    }
}
