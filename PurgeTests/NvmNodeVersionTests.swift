import Foundation
import Testing
@testable import Purge

/// Old Node.js versions nvm keeps (#400). Each keep rule has its own test, and the
/// delete-time gate is checked against the disk as it is at the move. Every
/// fixture is a throwaway home folder with a fake `.nvmrc` list and `lsof`.
private enum Nvm {
    typealias Policy = NvmNodeVersionPolicy
    static let node = Policy.versionsRoot

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-400-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    /// A bare version as nvm installs it: Node's own packages and commands only.
    static func install(_ home: URL, _ versions: String...) throws {
        for version in versions {
            for file in [
                "lib/node_modules/npm/package.json", "lib/node_modules/corepack/package.json",
                "bin/node", "bin/npm", "bin/npx", "bin/corepack",
            ] {
                try write("x", home, "\(node)/\(version)/\(file)")
            }
        }
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

    /// An empty `.nvmrc` list unless a test gives one, every file readable, no
    /// open files, and only `~/.local/bin` searched for links, so the real
    /// `/usr/local/bin` and `/opt/homebrew/bin` are never read.
    static func context(
        nvmrc: [String]? = [],
        mayRead: Bool = true,
        lsof: String? = ""
    ) -> Policy.Context {
        Policy.Context(
            nvmrcFiles: { nvmrc }, mayRead: { _ in mayRead }, openFiles: { lsof }, linkFolders: [".local/bin"]
        )
    }

    /// The versions the Dev Tools scan offers, as folder names.
    static func offered(_ home: URL, _ context: Policy.Context = context()) -> [String] {
        OldToolVersionScanPolicy.definitions(
            home: home,
            android: .init(avdHomes: [], emulatorIsRunning: { false }),
            nvm: context
        )
        .filter { Policy.version(inLabel: $0.label) != nil }
        .flatMap(\.paths)
        .map(\.lastPathComponent)
    }

    /// Whether `FileDeleter`'s last check, right before the move, lets the version go.
    static func movable(_ home: URL, _ version: String, _ context: Policy.Context = context()) -> Bool {
        Policy.passesImmediateTrashBoundary(
            home.appendingPathComponent("\(node)/\(version)"),
            home: home.path,
            context: context
        )
    }

    /// Whether `isOfferedForCleanup`'s gate, which may run on the main thread, keeps the row.
    static func gateKeeps(_ home: URL, _ version: String, _ context: Policy.Context = context()) -> Bool {
        !OldToolVersionScanPolicy.refusesDeletion(
            home.appendingPathComponent("\(node)/\(version)"),
            home: home.path,
            android: .init(avdHomes: [], emulatorIsRunning: { false }),
            nvm: context
        )
    }
}

@Suite("nvm Node versions (#400): shapes")
struct NvmNodeVersionShapeTests {
    private let home = "/Users/someone"

    @Test
    func aVersionFolderIsTheShape() {
        let path = "\(home)/.nvm/versions/node/v22.14.0"
        #expect(OldToolVersionScanPolicy.kind(of: path, home: home) == .nvmNodeVersion)
        #expect(OldToolVersionScanPolicy.isWhitelistedPath(path, home: home))
    }

    @Test(arguments: [
        ".nvm", ".nvm/versions", ".nvm/versions/node", ".nvm/versions/node/v22.14.0/bin",
        ".nvm/versions/node/v22.14.0/lib/node_modules", ".nvm/versions/node/22.14.0",
        ".nvm/versions/node/v22", ".nvm/versions/node/v22.14", ".nvm/versions/node/.v22.14.0",
        ".nvm/versions/node/v22.14.0.1", ".nvm/versions/io.js/v3.3.1", ".nvm/alias/default",
        ".nvm/.cache/bin/node-v22.14.0-darwin-arm64",
    ])
    func everythingElseIsNot(relative: String) {
        #expect(OldToolVersionScanPolicy.kind(of: "\(home)/\(relative)", home: home) != .nvmNodeVersion, "\(relative)")
    }

    @Test
    func labelsCarryTheirVersion() {
        #expect(NvmNodeVersionPolicy.version(inLabel: "nvm Node.js 22.14.0") == "22.14.0")
        #expect(NvmNodeVersionPolicy.version(inLabel: "nvm Node.js") == nil)
        #expect(NvmNodeVersionPolicy.version(inLabel: "Android NDK 27.0.1") == nil)
    }

    @Test
    func rowsAreCheckFirstAndSayHowToGetItBack() {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "nvm Node.js 22.14.0", primaryPath: nil)
        #expect(info.level == .medium)
        #expect(info.headline.contains("22.14.0"))
        #expect(info.reinstallCommand == "nvm install 22.14.0")
        #expect(BrandIconMapping.slug(forDefinitionKey: "nvm Node.js 22.14.0") == "nodedotjs")
    }
}

@Suite("nvm Node versions (#400): what stays")
struct NvmNodeVersionKeepTests {
    typealias Policy = NvmNodeVersionPolicy

    @Test
    func theNewestOfEachMajorStays() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v18.20.8", "v20.1.0", "v20.9.0", "v20.10.0", "v22.14.0")
        #expect(Nvm.offered(home) == ["v20.1.0", "v20.9.0"])
        #expect(Nvm.movable(home, "v20.1.0"))
        #expect(!Nvm.movable(home, "v20.10.0"))
        #expect(!Nvm.movable(home, "v18.20.8"))
    }

    @Test
    func aMissingNvmOffersNothing() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(Nvm.offered(home).isEmpty)
        #expect(!Nvm.movable(home, "v20.1.0"))
    }

    /// Installed: v20.1.0, v20.1.5, v20.2.0 and v22.1.0. The newest of each major
    /// stays anyway, so only the two older v20.1 versions can be offered.
    @Test(arguments: [
        ("v20.1.0", ["v20.1.5"]),
        ("20.1", ["v20.1.0"]),
        ("v20.1", ["v20.1.0"]),
        ("20", ["v20.1.0", "v20.1.5"]),
        ("node", ["v20.1.0", "v20.1.5"]),
        ("stable", ["v20.1.0", "v20.1.5"]),
        ("system", ["v20.1.0", "v20.1.5"]),
        ("v20.9.9", ["v20.1.0", "v20.1.5"]),
    ])
    func defaultAliasResolvesAsNvmDoes(alias: String, offered: [String]) throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.1.5", "v20.2.0", "v22.1.0")
        try Nvm.write(alias + "\n", home, ".nvm/alias/default")
        #expect(Nvm.offered(home) == offered, "\(alias)")
    }

    @Test
    func chainedAndLTSAliasesAreFollowed() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0", "v20.4.0")
        try Nvm.write("work", home, ".nvm/alias/default")
        try Nvm.write("v20.1.0", home, ".nvm/alias/work")
        try Nvm.write("lts/jod", home, ".nvm/alias/lts/*")
        try Nvm.write("v20.2.0", home, ".nvm/alias/lts/jod")
        // An LTS line nvm knows of but that isn't installed names nothing.
        try Nvm.write("v20.99.0", home, ".nvm/alias/lts/iron")
        try Nvm.write("x", home, ".nvm/alias/.DS_Store")
        #expect(Nvm.offered(home) == ["v20.3.0"])
    }

    @Test(arguments: [">=20", "lts/*\nmore", "some alias", "work", "../../escape", "v20.1.0.0"])
    func anAliasPurgeCantReadKeepsEverything(alias: String) throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        try Nvm.write(alias, home, ".nvm/alias/default")
        #expect(Nvm.offered(home).isEmpty, "\(alias)")
        #expect(!Nvm.movable(home, "v20.1.0"), "\(alias)")
    }

    @Test
    func aLinkedAliasKeepsEverything() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        try Nvm.write("20", home, "elsewhere/default")
        try Nvm.link(home, ".nvm/alias/default", to: home.appendingPathComponent("elsewhere/default").path)
        #expect(Nvm.offered(home).isEmpty)
    }

    @Test
    func theCurrentLinkStays() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0")
        try Nvm.link(home, ".nvm/current", to: home.appendingPathComponent("\(Nvm.node)/v20.1.0").path)
        #expect(Nvm.offered(home) == ["v20.2.0"])
    }

    /// Installed: v20.1.0 to v20.4.0, with `lts/jod` naming v20.3.0. An alias file
    /// keeps its version on its own, so an `.nvmrc` naming one adds nothing, but
    /// is still understood.
    @Test(arguments: [
        ("v20.1.0\n", ["v20.2.0"]),
        ("20.1 # the CI pin\n", ["v20.2.0"]),
        ("# pinned\n\nlts/jod\n", ["v20.1.0", "v20.2.0"]),
        ("lts/iron", ["v20.1.0", "v20.2.0"]),
    ])
    func aScannedProjectsNvmrcStays(text: String, offered: [String]) throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0", "v20.4.0")
        try Nvm.write("v20.3.0", home, ".nvm/alias/lts/jod")
        try Nvm.write(text, home, "Developer/site/.nvmrc")
        let files = [home.appendingPathComponent("Developer/site/.nvmrc").path]
        #expect(Nvm.offered(home, Nvm.context(nvmrc: files)) == offered, "\(text)")
    }

    @Test
    func anNvmrcThatIsGonePinsNothing() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        let files = [home.appendingPathComponent("Developer/gone/.nvmrc").path]
        #expect(Nvm.offered(home, Nvm.context(nvmrc: files)) == ["v20.1.0"])
    }

    @Test(arguments: ["node=20", ""])
    func anNvmrcPurgeCantReadKeepsEverything(text: String) throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        try Nvm.write(text, home, "Developer/site/.nvmrc")
        let files = [home.appendingPathComponent("Developer/site/.nvmrc").path]
        #expect(Nvm.offered(home, Nvm.context(nvmrc: files)).isEmpty, "\(text)")
    }

    @Test
    func beforeAnyProjectScanNothingIsOffered() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        #expect(Nvm.offered(home, Nvm.context(nvmrc: nil)).isEmpty)
        #expect(!Nvm.movable(home, "v20.1.0", Nvm.context(nvmrc: nil)))
    }

    @Test
    func anNvmrcMacOSWouldAskAboutKeepsEverything() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        let files = [home.appendingPathComponent("Documents/site/.nvmrc").path]
        #expect(Nvm.offered(home, Nvm.context(nvmrc: files, mayRead: false)).isEmpty)
    }

    @Test(arguments: [
        "lib/node_modules/vercel/package.json",
        "lib/node_modules/@anthropic-ai/claude-code/package.json",
        "bin/pnpm",
    ])
    func aVersionWithGlobalPackagesStays(extra: String) throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0")
        try Nvm.write("x", home, "\(Nvm.node)/v20.1.0/\(extra)")
        #expect(Nvm.offered(home) == ["v20.2.0"], "\(extra)")
        #expect(!Nvm.movable(home, "v20.1.0"), "\(extra)")
    }

    @Test
    func aVersionWithNoPackagesFolderIsOffered() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.2.0")
        try Nvm.write("x", home, "\(Nvm.node)/v20.1.0/include/node/node.h")
        #expect(Nvm.offered(home) == ["v20.1.0"])
    }

    @Test(arguments: [
        ".claude.json",
        ".cursor/mcp.json",
        "Library/Application Support/Claude/claude_desktop_config.json",
        "Library/Application Support/Code/User/settings.json",
    ])
    func aVersionAnMCPConfigNamesStays(config: String) throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0")
        let node = home.appendingPathComponent("\(Nvm.node)/v20.1.0/bin/node").path
        try Nvm.write(#"{"mcpServers":{"x":{"command":"\#(node)"}}}"#, home, config)
        #expect(Nvm.offered(home) == ["v20.2.0"], "\(config)")
    }

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func aVersionALaunchAgentRunsStays(format: PropertyListSerialization.PropertyListFormat) throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0")
        let plist: [String: Any] = [
            "Label": "com.example.server",
            "ProgramArguments": [home.appendingPathComponent("\(Nvm.node)/v20.1.0/bin/node").path, "server.js"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        let url = home.appendingPathComponent("Library/LaunchAgents/com.example.server.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        #expect(Nvm.offered(home) == ["v20.2.0"])
    }

    @Test
    func aReferenceFileMacOSWouldAskAboutKeepsEverything() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        #expect(Nvm.offered(home, Nvm.context(mayRead: false)).isEmpty)
    }
}

@Suite("nvm Node versions (#400): review fixes")
struct NvmNodeVersionReviewTests {
    /// nvm falls back to `~/.nvmrc`, which no project walk records.
    @Test
    func theHomeNvmrcStays() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0")
        try Nvm.write("v20.1.0\n", home, ".nvmrc")
        #expect(Nvm.offered(home) == ["v20.2.0"])
        #expect(!Nvm.movable(home, "v20.1.0"))
    }

    /// nvm walks up from a project. The walk records the `.nvmrc` above a project
    /// too, up to home and never above it.
    @Test
    func aWalkRecordsTheNvmrcAboveAProject() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.write("20.1", home, "work/.nvmrc")
        try Nvm.write("20.1", home, ".nvmrc")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("work/clients/site"), withIntermediateDirectories: true
        )
        let found = NvmNodeVersionPolicy.nvmrcFiles(
            inProjectRoots: [home.appendingPathComponent("work/clients/site")], home: home.path
        )
        #expect(found == [home.appendingPathComponent("work/.nvmrc").path, home.appendingPathComponent(".nvmrc").path])
    }

    /// A recorded `.nvmrc` on a drive that isn't mounted may be back tomorrow.
    @Test
    func aPinOnAnUnpluggedDriveKeepsEverything() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        let unplugged = "/Volumes/purge-test-400-\(UUID().uuidString)/site/.nvmrc"
        #expect(Nvm.offered(home, Nvm.context(nvmrc: [unplugged])).isEmpty)
        #expect(!Nvm.movable(home, "v20.1.0", Nvm.context(nvmrc: [unplugged])))
    }

    /// A link in home can lead to such a drive, so a pin missing behind one counts the same.
    @Test
    func aPinMissingBehindALinkKeepsEverything() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        try Nvm.link(home, "Projects", to: "/Volumes/purge-test-400-\(UUID().uuidString)")
        let pin = home.appendingPathComponent("Projects/site/.nvmrc").path
        #expect(Nvm.offered(home, Nvm.context(nvmrc: [pin])).isEmpty)
        #expect(NvmNodeVersionPolicy.isGone(pin, home: home.path) == nil)
        #expect(NvmNodeVersionPolicy.isGone(home.appendingPathComponent("gone/site/.nvmrc").path, home: home.path) == true)
    }

    @Test(arguments: [".claude/settings.json", ".claude/settings.local.json", ".zshrc", ".config/fish/config.fish"])
    func aVersionAClaudeHookOrShellPathNamesStays(file: String) throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0")
        let bin = home.appendingPathComponent("\(Nvm.node)/v20.1.0/bin").path
        try Nvm.write("export PATH=\"\(bin):$PATH\"\n", home, file)
        #expect(Nvm.offered(home) == ["v20.2.0"], "\(file)")
    }

    /// People link one Node into a `bin` folder so apps and build scripts find it.
    @Test
    func aVersionABinLinkPointsIntoStays() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0")
        try Nvm.link(home, ".local/bin/node", to: home.appendingPathComponent("\(Nvm.node)/v20.1.0/bin/node").path)
        try Nvm.link(home, ".local/bin/other", to: "/usr/bin/true")
        #expect(Nvm.offered(home) == ["v20.2.0"])
        #expect(!Nvm.movable(home, "v20.1.0"))
    }

    /// `npm config set -g` writes into the version, and it can hold a token.
    @Test
    func aVersionWithGlobalNpmConfigStays() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0", "v20.3.0")
        try Nvm.write("//registry.example.com/:_authToken=x\n", home, "\(Nvm.node)/v20.1.0/etc/npmrc")
        try Nvm.write("", home, "\(Nvm.node)/v20.2.0/etc/npmrc")
        #expect(Nvm.offered(home) == ["v20.2.0"])
    }

    /// The list gate may answer from a read a moment ago. The move never does.
    @Test
    func theListGateMayReuseARecentReadButTheMoveNever() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        let now = Date()
        let first = NvmNodeVersionPolicy.recentKeptVersions(home: home.path, context: Nvm.context(), now: now)
        try Nvm.write("v20.1.0", home, ".nvm/alias/default")
        let reused = NvmNodeVersionPolicy.recentKeptVersions(home: home.path, context: Nvm.context(), now: now.addingTimeInterval(1))
        #expect(first == reused)
        let later = NvmNodeVersionPolicy.recentKeptVersions(
            home: home.path, context: Nvm.context(),
            now: now.addingTimeInterval(NvmNodeVersionPolicy.recentReadLifetime + 1)
        )
        #expect(later?.contains("v20.1.0") == true)
        #expect(!Nvm.movable(home, "v20.1.0"))
    }
}

@Suite("nvm Node versions (#400): the gate at the move")
struct NvmNodeVersionGateTests {
    @Test
    func aVersionInUseIsListedButNotMoved() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        let node = home.appendingPathComponent("\(Nvm.node)/v20.1.0/bin/node").path
        let context = Nvm.context(lsof: "p4242\ncnode\nftxt\nn\(node)\n")
        #expect(Nvm.offered(home, context) == ["v20.1.0"])
        #expect(!Nvm.movable(home, "v20.1.0", context))
    }

    /// The gate runs on every Dev Tools list update, on the main thread, where
    /// `lsof` must never run (the first live run crashed there). It lets a row
    /// in use stay listed, and the move refuses it.
    @Test
    func theListGateNeverRunsLsof() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func hit() { lock.lock(); count += 1; lock.unlock() }
        }
        let calls = Calls()
        let context = NvmNodeVersionPolicy.Context(
            nvmrcFiles: { [] }, mayRead: { _ in true }, openFiles: { calls.hit(); return nil }, linkFolders: []
        )
        #expect(Nvm.gateKeeps(home, "v20.1.0", context))
        #expect(calls.count == 0)
        #expect(!Nvm.movable(home, "v20.1.0", context))
        #expect(calls.count == 1)
    }

    /// A config read only at the scan and the move still keeps the version at the move.
    @Test
    func aConfigWrittenAfterTheScanStopsTheMove() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        #expect(Nvm.offered(home) == ["v20.1.0"])
        let node = home.appendingPathComponent("\(Nvm.node)/v20.1.0/bin/node").path
        try Nvm.write(#"{"command":"\#(node)"}"#, home, ".cursor/mcp.json")
        #expect(!Nvm.movable(home, "v20.1.0"))
    }

    @Test
    func otherPathsPassTheMoveCheck() {
        let url = URL(fileURLWithPath: "/Users/someone/Library/Caches/com.example")
        #expect(NvmNodeVersionPolicy.passesImmediateTrashBoundary(url, home: "/Users/someone", context: Nvm.context(lsof: nil)))
    }

    @Test
    func anUnreadableProcessListMovesNothing() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        #expect(!Nvm.movable(home, "v20.1.0", Nvm.context(lsof: nil)))
        #expect(Nvm.movable(home, "v20.1.0", Nvm.context(lsof: "")))
    }

    @Test
    func aVersionThatBecameTheDefaultIsNotMoved() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.1.0", "v20.2.0")
        #expect(Nvm.offered(home) == ["v20.1.0"])
        try Nvm.write("v20.1.0", home, ".nvm/alias/default")
        #expect(!Nvm.movable(home, "v20.1.0"))
    }

    @Test
    func linkedFoldersAreNeverOffered() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.install(home, "v20.2.0")
        let real = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: real) }
        try Nvm.install(real, "v20.1.0")
        // The version folder itself is a link.
        try Nvm.link(home, "\(Nvm.node)/v20.1.0", to: real.appendingPathComponent("\(Nvm.node)/v20.1.0").path)
        #expect(Nvm.offered(home).isEmpty)
        #expect(!Nvm.movable(home, "v20.1.0"))

        // `~/.nvm` is a link.
        let linked = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: linked) }
        try Nvm.install(real, "v20.2.0")
        try Nvm.link(linked, ".nvm", to: real.appendingPathComponent(".nvm").path)
        #expect(Nvm.offered(linked).isEmpty)
        #expect(!Nvm.movable(linked, "v20.1.0"))
    }
}

@Suite("nvm Node versions (#400): the .nvmrc list")
struct NvmrcLedgerTests {
    @Test
    func walksAddToTheListAndNeverDropFromIt() throws {
        let folder = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (a, b, c) = try (pin(folder, "a"), pin(folder, "b"), pin(folder, "c"))
        let ledger = NvmrcLedger(fileURL: folder.appendingPathComponent(NvmrcLedger.fileName))
        #expect(ledger.files() == nil)
        ledger.record([], home: folder.path)
        #expect(ledger.files() == [])
        ledger.record([a, b], home: folder.path)
        ledger.record([c, a], home: folder.path)
        #expect(ledger.files() == [c, a, b])
    }

    /// Past the limit nothing is dropped. The list keeps every version instead.
    @Test
    func aListOverTheLimitKeepsEveryVersion() throws {
        let folder = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (a, b, c) = try (pin(folder, "a"), pin(folder, "b"), pin(folder, "c"))
        let ledger = NvmrcLedger(fileURL: folder.appendingPathComponent(NvmrcLedger.fileName), limit: 2)
        ledger.record([a, b], home: folder.path)
        #expect(ledger.files()?.count == 2)
        ledger.record([c], home: folder.path)
        #expect(ledger.files() == nil)
        let reread = NvmrcLedger(fileURL: folder.appendingPathComponent(NvmrcLedger.fileName), limit: 2)
        #expect(reread.files() == nil)
    }

    private func pin(_ folder: URL, _ project: String) throws -> String {
        try Nvm.write("20", folder, "\(project)/.nvmrc")
        return folder.appendingPathComponent("\(project)/.nvmrc").path
    }

    /// A walk drops a recorded file only once it is confirmed gone. One on a
    /// drive that isn't mounted, or one macOS would ask about, stays.
    @Test
    func aWalkDropsOnlyFilesThatAreGone() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ledger = NvmrcLedger(fileURL: home.appendingPathComponent(NvmrcLedger.fileName))
        let gone = home.appendingPathComponent("old/site/.nvmrc").path
        let unplugged = "/Volumes/purge-test-400-\(UUID().uuidString)/site/.nvmrc"
        let protected = home.appendingPathComponent("Documents/gone/.nvmrc").path
        ledger.record([gone, unplugged, protected], home: home.path)
        ledger.record([], home: home.path, mayRead: { $0 != protected })
        #expect(ledger.files() == [unplugged, protected])
    }

    @Test
    func aWalkFindsTheNvmrcBesideEachProject() throws {
        let home = try Nvm.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Nvm.write("20", home, "Developer/site/.nvmrc")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Developer/api"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Developer/odd/.nvmrc"), withIntermediateDirectories: true
        )
        let found = NvmNodeVersionPolicy.nvmrcFiles(inProjectRoots: ["site", "api", "odd"].map {
            home.appendingPathComponent("Developer/\($0)")
        }, home: home.path)
        #expect(found == [home.appendingPathComponent("Developer/site/.nvmrc").path])
    }
}
