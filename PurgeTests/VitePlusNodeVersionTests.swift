import Foundation
import Testing
@testable import Purge

/// Node.js versions Vite+ installs, and the folders an unfinished install
/// leaves (#398). Each keep rule has its own test. Every fixture is a throwaway
/// home folder with a fake pin-file list and `lsof`.
private enum VP {
    typealias Policy = VitePlusNodeVersionPolicy
    /// The older single folder, and the newer XDG data folder.
    static let old = ".vite-plus"
    static let new = ".local/share/vite-plus"
    static let day: TimeInterval = 24 * 60 * 60

    static func node(_ root: String) -> String { "\(root)/js_runtime/node" }

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-398-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    /// A bare version as Vite+ installs it, with its `.lock` beside it.
    static func install(_ home: URL, _ root: String = new, _ versions: String...) throws {
        for version in versions {
            for file in [
                "lib/node_modules/npm/package.json", "lib/node_modules/corepack/package.json",
                "bin/node", "bin/npm", "bin/npx", "bin/corepack",
            ] {
                try write("x", home, "\(node(root))/\(version)/\(file)")
            }
            try write("", home, "\(node(root))/\(version).lock")
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

    /// An empty pin-file list unless a test gives one, every file readable, no
    /// open files, and only `~/.local/bin` searched for links.
    static func context(
        pins: [String]? = [],
        mayRead: @escaping @Sendable (String) -> Bool = { _ in true },
        lsof: String? = "",
        onLsof: @escaping @Sendable () -> Void = {}
    ) -> Policy.Context {
        Policy.Context(
            pinFiles: { pins },
            mayRead: mayRead,
            openFiles: { onLsof(); return lsof },
            linkFolders: [".local/bin"]
        )
    }

    /// The pin files for a project at `relative`, as a Dev Projects walk records them.
    static func pins(_ home: URL, project relative: String) -> [String] {
        Policy.pinFiles(inProjectRoots: [home.appendingPathComponent(relative)])
    }

    /// What the Dev Tools scan offers, as paths relative to home.
    static func offered(_ home: URL, _ context: Policy.Context = context(), now: Date = Date()) -> [String] {
        rows(home, context, now: now)
            .flatMap(\.paths)
            .map { String($0.standardizedFileURL.path.dropFirst(home.path.count + 1)) }
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
            vitePlus: context
        )
        .filter { Policy.version(inLabel: $0.label) != nil || $0.label == Policy.leftoversLabel }
    }

    /// Whether `FileDeleter`'s last check, right before the move, lets it go.
    static func movable(
        _ home: URL, _ relative: String, _ context: Policy.Context = context(), now: Date = Date()
    ) -> Bool {
        Policy.passesImmediateTrashBoundary(
            home.appendingPathComponent(relative), home: home.path, now: now, context: context
        )
    }

    /// Whether `isOfferedForCleanup`'s gate, which may run on the main thread, keeps the row.
    static func gateKeeps(
        _ home: URL, _ relative: String, _ context: Policy.Context = context(), now: Date = Date()
    ) -> Bool {
        !OldToolVersionScanPolicy.refusesDeletion(
            home.appendingPathComponent(relative),
            home: home.path,
            now: now,
            android: .init(avdHomes: [], emulatorIsRunning: { false }),
            vitePlus: context
        )
    }
}

@Suite("Vite+ Node versions (#398): shapes")
struct VitePlusNodeVersionShapeTests {
    private let home = "/Users/someone"

    @Test(arguments: [VP.old, VP.new])
    func versionsAndLeftoversInEitherDataFolderAreTheShape(root: String) {
        let version = "\(home)/\(root)/js_runtime/node/22.14.0"
        #expect(OldToolVersionScanPolicy.kind(of: version, home: home) == .vitePlusNodeVersion)
        #expect(OldToolVersionScanPolicy.isWhitelistedPath(version, home: home))
        let leftover = "\(home)/\(root)/js_runtime/.tmpAb12Cd"
        #expect(OldToolVersionScanPolicy.kind(of: leftover, home: home) == .vitePlusInstallLeftover)
    }

    @Test(arguments: [
        ".vite-plus", ".vite-plus/js_runtime", ".vite-plus/js_runtime/node",
        ".vite-plus/js_runtime/node/22.14.0.lock", ".vite-plus/js_runtime/node/v22.14.0",
        ".vite-plus/js_runtime/node/22.14", ".vite-plus/js_runtime/node/27.0.0-rc.1",
        ".vite-plus/js_runtime/node/.22.14.0", ".vite-plus/js_runtime/node/22.14.0/bin",
        ".vite-plus/js_runtime/node/index_cache.json", ".vite-plus/js_runtime/.tmp",
        ".vite-plus/js_runtime/node/.tmpAb12Cd", ".vite-plus/js_runtime/.tmpAb12Cd/node-v22.14.0-darwin-arm64",
        ".vite-plus/bin", ".vite-plus/packages", ".vite-plus/config.json",
        ".local/share/vite-plus", ".local/share/vite-plus/js_runtime/node",
        ".config/vite-plus/js_runtime/node/22.14.0", ".cache/vite-plus/js_runtime/node/22.14.0",
        "vite-plus/js_runtime/node/22.14.0",
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
        #expect(DeletionSafetyPolicy.evaluate(realHome(".vite-plus", "js_runtime", "node", "22.14.0")) == .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".local", "share", "vite-plus", "js_runtime", ".tmpAb12Cd")) == .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".vite-plus")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".vite-plus", "js_runtime")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".vite-plus", "js_runtime", "node")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".vite-plus", "js_runtime", "node", "22.14.0.lock")) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(realHome(".vite-plus", "packages")) != .allow)
    }

    @Test
    func labelsCarryTheirVersion() {
        #expect(VitePlusNodeVersionPolicy.version(inLabel: "Vite+ Node.js 22.14.0") == "22.14.0")
        #expect(VitePlusNodeVersionPolicy.version(inLabel: "Vite+ Node.js") == nil)
        #expect(VitePlusNodeVersionPolicy.version(inLabel: "nvm Node.js 22.14.0") == nil)
        #expect(NvmNodeVersionPolicy.version(inLabel: "Vite+ Node.js 22.14.0") == nil)
    }

    @Test
    func rowsAreCheckFirstAndSayHowToGetItBack() {
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "Vite+ Node.js 22.14.0", primaryPath: nil)
        #expect(info.level == .medium)
        #expect(info.headline.contains("22.14.0"))
        #expect(info.reinstallCommand == "vp env install 22.14.0")
        #expect(BrandIconMapping.slug(forDefinitionKey: "Vite+ Node.js 22.14.0") == "vite")

        let leftovers = DevScanner.automaticSafetyInfo(forDevToolLabel: VitePlusNodeVersionPolicy.leftoversLabel, primaryPath: nil)
        #expect(leftovers.level == .medium)
        #expect(BrandIconMapping.slug(forDefinitionKey: VitePlusNodeVersionPolicy.leftoversExplanationKey) == "vite")
    }

    @Test
    func theLedgerSetsAsideIntoItsOwnFile() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        #expect(NvmrcLedger.fileName != "node-pin-files.json")
        // Each list derives its unsaved name from its own, so nvm's is unchanged.
        #expect("\(folder.appendingPathComponent(NvmrcLedger.fileName).deletingPathExtension().lastPathComponent).unsaved.json"
            == NvmrcLedger.unsavedFileName)
    }

    @Test
    func pinFilesCoverEveryFolderUpToTheRoot() {
        let files = VitePlusNodeVersionPolicy.pinFiles(inProjectRoots: [URL(fileURLWithPath: "/Users/me/code/app")])
        for folder in ["/Users/me/code/app", "/Users/me/code", "/Users/me", "/Users"] {
            for name in [".node-version", "package.json", ".nvmrc"] {
                #expect(files.contains("\(folder)/\(name)"), "\(folder)/\(name)")
            }
        }
        #expect(files.contains("/.node-version"))
        #expect(files.contains("/package.json"))
    }
}

@Suite("Vite+ Node versions (#398): what stays")
struct VitePlusNodeVersionKeepTests {

    @Test
    func theNewestOfEachMajorStaysInEachDataFolder() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "20.1.0", "20.2.0", "22.1.0", "22.10.0")
        try VP.install(home, VP.old, "20.1.0", "22.5.0")
        #expect(Set(VP.offered(home)) == [
            "\(VP.node(VP.new))/20.1.0", "\(VP.node(VP.new))/22.1.0",
        ])
    }

    @Test
    func theNewestWithANodeProgramStaysToo() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.1.0", "22.2.0")
        // An install that never finished: Vite+ doesn't count it, so it uses 22.2.0.
        try VP.write("x", home, "\(VP.node(VP.new))/22.3.0/README.md")
        #expect(VP.offered(home) == ["\(VP.node(VP.new))/22.1.0"])
    }

    @Test(arguments: [
        (".vite-plus/config.json", #"{"defaultNodeVersion":"22.1.0"}"#),
        (".config/vite-plus/config.json", #"{"defaultNodeVersion":"v22.1.0","other":1}"#),
        (".vite-plus/.session-node-version", "22.1.0\n"),
        (".local/state/vite-plus/.session-node-version", "22.1\n"),
        (".local/share/vite-plus/bins/tsc.json", #"{"name":"tsc","nodeVersion":"22.1.0","source":"npm"}"#),
        (".vite-plus/packages/typescript.json", #"{"name":"typescript","platform":{"node":"22.1.0","npm":"10.0.0"}}"#),
        (".local/share/vite-plus/packages/@scope/tool.json", #"{"platform":{"node":"22.1.0"}}"#),
    ])
    func viteOwnFilesKeepWhatTheyName(file: String, text: String) throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.1.0", "22.0.0", "22.9.0")
        try VP.write(text, home, file)
        #expect(VP.offered(home) == ["\(VP.node(VP.new))/22.0.0"], "\(file)")
    }

    @Test(arguments: ["lts", "latest", "lts/*", "lts/iron", "lts/-1", "LTS"])
    func aliasesKeepOnlyTheNewest(alias: String) throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.1.0", "22.9.0")
        try VP.write(#"{"defaultNodeVersion":"\#(alias)"}"#, home, ".config/vite-plus/config.json")
        #expect(VP.offered(home) == ["\(VP.node(VP.new))/22.1.0"])
    }

    @Test(arguments: [
        (".node-version", "22.1.0\n"),
        (".node-version", "v22.1.0"),
        (".nvmrc", "# pinned\n22.1.0\n"),
        ("package.json", #"{"engines":{"node":"22.1.0"}}"#),
        ("package.json", #"{"engines":{"node":">=22.0.0 <22.2.0"}}"#),
        ("package.json", #"{"devEngines":{"runtime":{"name":"node","version":"~22.1.0"}}}"#),
        ("package.json", #"{"devEngines":{"runtime":[{"name":"bun"},{"name":"node","version":"22.1.x"}]}}"#),
    ])
    func projectPinsKeepTheirVersion(name: String, text: String) throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.1.0", "22.9.0")
        try VP.write(text, home, "code/app/\(name)")
        #expect(VP.offered(home, VP.context(pins: VP.pins(home, project: "code/app"))) == [
            "\(VP.node(VP.new))/22.0.0",
        ], "\(name): \(text)")
    }

    @Test
    func aPinInAFolderAboveTheProjectCounts() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.1.0", "22.9.0")
        try VP.write("22.1.0", home, "code/.node-version")
        #expect(VP.offered(home, VP.context(pins: VP.pins(home, project: "code/app"))) == [
            "\(VP.node(VP.new))/22.0.0",
        ])
    }

    @Test
    func aPartialPinKeepsTheNewestMatchBothWays() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "20.4.0", "20.5.1", "20.5.3", "20.6.0", "20.9.0")
        try VP.write("20.5", home, "code/app/.node-version")
        // npm reads 20.5 as 20.5.x (20.5.3), Vite+ as ^20.5.0 (20.9.0).
        #expect(Set(VP.offered(home, VP.context(pins: VP.pins(home, project: "code/app")))) == [
            "\(VP.node(VP.new))/20.4.0", "\(VP.node(VP.new))/20.5.1", "\(VP.node(VP.new))/20.6.0",
        ])
    }

    @Test
    func emptyAndMissingPinsKeepNothingMore() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.9.0")
        try VP.write("\n22.0.0\n", home, "code/app/.node-version")
        try VP.write(#"{"name":"app"}"#, home, "code/app/package.json")
        // Vite+ reads only the first line of `.node-version`.
        #expect(VP.offered(home, VP.context(pins: VP.pins(home, project: "code/app"))) == [
            "\(VP.node(VP.new))/22.0.0",
        ])
    }

    @Test(arguments: [
        ("code/app/.node-version", "27.0.0-rc.1"),
        ("code/app/.node-version", "hydrogen"),
        ("code/app/package.json", "{ not json"),
        ("code/app/package.json", #"{"engines":{"node":22}}"#),
        ("code/app/.nvmrc", "node=22\n"),
        (".config/vite-plus/config.json", "{ not json"),
        (".vite-plus/bins/tsc.json", "[]"),
        (".vite-plus/packages/tool.json", #"{"platform":"22"}"#),
    ])
    func anythingUnreadKeepsEveryVersion(file: String, text: String) throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.9.0")
        try VP.write(text, home, file)
        #expect(VP.offered(home, VP.context(pins: VP.pins(home, project: "code/app"))).isEmpty, "\(file)")
    }

    @Test
    func nothingIsOfferedBeforeAProjectWalkRecordedItsPins() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.9.0")
        #expect(VP.offered(home, VP.context(pins: nil)).isEmpty)
        #expect(!VP.gateKeeps(home, "\(VP.node(VP.new))/22.0.0", VP.context(pins: nil)))
    }

    @Test
    func aPinFileMacOSWouldAskAboutKeepsEveryVersion() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.9.0")
        let protected = home.appendingPathComponent("Documents").path
        let context = VP.context(
            pins: VP.pins(home, project: "Documents/app"),
            mayRead: { !PathContainment.isSameOrInside($0, protected) }
        )
        #expect(VP.offered(home, context).isEmpty)
    }

    @Test
    func aVersionWithGlobalPackagesOrAnNpmConfigStays() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.1.0", "22.2.0", "22.9.0")
        try VP.write("x", home, "\(VP.node(VP.new))/22.0.0/lib/node_modules/typescript/package.json")
        try VP.write("x", home, "\(VP.node(VP.new))/22.1.0/bin/tsc")
        try VP.write("//registry.npmjs.org/:_authToken=x", home, "\(VP.node(VP.new))/22.2.0/etc/npmrc")
        #expect(VP.offered(home).isEmpty)
    }

    @Test
    func aConfigOrABinLinkNamingItKeepsIt() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.1.0", "22.9.0")
        try VP.write(
            #"{"mcpServers":{"x":{"command":"\/Users\/me\/.local\/share\/vite-plus\/js_runtime\/node\/22.0.0\/bin\/node"}}}"#,
            home, ".cursor/mcp.json"
        )
        try VP.link(home, ".local/bin/node22", to: home.appendingPathComponent("\(VP.node(VP.new))/22.1.0/bin/node").path)
        #expect(VP.offered(home).isEmpty)
        // The list gate doesn't read them; the move does.
        #expect(VP.gateKeeps(home, "\(VP.node(VP.new))/22.0.0"))
        #expect(!VP.movable(home, "\(VP.node(VP.new))/22.0.0"))
        #expect(!VP.movable(home, "\(VP.node(VP.new))/22.1.0"))
    }

    @Test
    func aLinkedVersionNameKeepsEveryVersion() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.9.0")
        try VP.write("x", home, "elsewhere/bin/node")
        try VP.link(home, "\(VP.node(VP.new))/22.5.0", to: home.appendingPathComponent("elsewhere").path)
        #expect(VP.offered(home).isEmpty)
    }

    @Test
    func aLinkOnTheWayDownIsNeverOffered() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, "real-vite-plus", "22.0.0", "22.9.0")
        try VP.link(home, ".vite-plus", to: home.appendingPathComponent("real-vite-plus").path)
        #expect(VP.offered(home).isEmpty)
    }
}

@Suite("Vite+ Node versions (#398): the move")
struct VitePlusNodeVersionMoveTests {

    @Test
    func theListGateNeverRunsLsof() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.9.0")
        let calls = Counter()
        let context = VP.context(onLsof: { calls.add() })
        #expect(VP.gateKeeps(home, "\(VP.node(VP.new))/22.0.0", context))
        #expect(VP.offered(home, context) == ["\(VP.node(VP.new))/22.0.0"])
        #expect(calls.value == 0)
        #expect(VP.movable(home, "\(VP.node(VP.new))/22.0.0", context))
        #expect(calls.value == 1)
    }

    @Test
    func aProcessUsingTheVersionStopsTheMove() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.9.0")
        let binary = home.appendingPathComponent("\(VP.node(VP.new))/22.0.0/bin/node").path
        #expect(!VP.movable(home, "\(VP.node(VP.new))/22.0.0", VP.context(lsof: "p123\nn\(binary)\n")))
        #expect(!VP.movable(home, "\(VP.node(VP.new))/22.0.0", VP.context(lsof: nil)))
    }

    @Test
    func aPinAddedAfterTheScanStopsTheMove() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "22.0.0", "22.9.0")
        let context = VP.context(pins: VP.pins(home, project: "code/app"))
        #expect(VP.movable(home, "\(VP.node(VP.new))/22.0.0", context))
        try VP.write("22.0.0", home, "code/app/.node-version")
        #expect(!VP.movable(home, "\(VP.node(VP.new))/22.0.0", context))
    }

    @Test
    func otherPathsAreLeftToTheirOwnRules() {
        #expect(VitePlusNodeVersionPolicy.passesImmediateTrashBoundary(
            URL(fileURLWithPath: "/Users/someone/.nvm/versions/node/v20.0.0"), home: "/Users/someone",
            context: VP.context(lsof: nil)
        ))
    }

    @Test
    func eachVersionIsItsOwnRowAndTheLockStays() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.install(home, VP.new, "20.0.0", "20.9.0", "22.0.0", "22.9.0")
        try VP.install(home, VP.old, "22.0.0", "22.9.0")
        let rows = VP.rows(home)
        #expect(rows.map(\.label) == ["Vite+ Node.js 20.0.0", "Vite+ Node.js 22.0.0"])
        #expect(rows.last?.paths.count == 2)
        #expect(!rows.flatMap(\.paths).contains { $0.lastPathComponent.hasSuffix(".lock") })
    }
}

@Suite("Vite+ unfinished downloads (#398)")
struct VitePlusInstallLeftoverTests {
    private static let leftover = "\(VP.new)/js_runtime/.tmpAb12Cd"

    private func lay(_ home: URL) throws {
        try VP.write("x", home, "\(Self.leftover)/node-v22.1.0-darwin-arm64.tar.gz")
        try VP.write("x", home, "\(Self.leftover)/node-v22.1.0-darwin-arm64/bin/node")
    }

    @Test
    func aLeftoverWaitsADay() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try lay(home)
        // Tests can't set a change time back, so the clock moves forward instead.
        #expect(VP.offered(home).isEmpty)
        #expect(!VP.gateKeeps(home, Self.leftover))
        let later = Date().addingTimeInterval(2 * VP.day)
        #expect(VP.offered(home, now: later) == [Self.leftover])
        #expect(VP.gateKeeps(home, Self.leftover, now: later))
        #expect(VP.movable(home, Self.leftover, now: later))
        #expect(VP.rows(home, now: later).map(\.label) == [VitePlusNodeVersionPolicy.leftoversLabel])
    }

    @Test
    func anUnpackedFileWithAnOldDateStillCountsAsNew() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try lay(home)
        // Unpacking stamps files with Node's release date. The change time stays now.
        let old = Date().addingTimeInterval(-300 * VP.day)
        for relative in [Self.leftover, "\(Self.leftover)/node-v22.1.0-darwin-arm64",
                         "\(Self.leftover)/node-v22.1.0-darwin-arm64/bin",
                         "\(Self.leftover)/node-v22.1.0-darwin-arm64.tar.gz"] {
            try FileManager.default.setAttributes(
                [.modificationDate: old], ofItemAtPath: home.appendingPathComponent(relative).path
            )
        }
        #expect(VP.offered(home).isEmpty)
    }

    @Test
    func aBusyLeftoverIsNotMoved() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try lay(home)
        let later = Date().addingTimeInterval(2 * VP.day)
        let archive = home.appendingPathComponent("\(Self.leftover)/node-v22.1.0-darwin-arm64.tar.gz").path
        #expect(!VP.movable(home, Self.leftover, VP.context(lsof: "p9\nn\(archive)\n"), now: later))
        #expect(!VP.movable(home, Self.leftover, VP.context(lsof: nil), now: later))
    }

    @Test
    func onlyRealFoldersCount() throws {
        let home = try VP.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try VP.write("x", home, "\(VP.new)/js_runtime/.tmpFile01")
        try VP.write("x", home, "elsewhere/file")
        try VP.link(home, "\(VP.new)/js_runtime/.tmpLink01", to: home.appendingPathComponent("elsewhere").path)
        #expect(VP.offered(home, now: Date().addingTimeInterval(2 * VP.day)).isEmpty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}
