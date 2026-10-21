import Foundation
import Testing
@testable import Purge

/// Tools a package manager owns (#225): found from the manager's folders, each
/// with the manager's own command, and never a path Purge itself moves.
@Suite("Package-manager tool scanner")
struct PackageManagerToolScannerTests {
    private let fm = FileManager.default

    private func makeRoot() throws -> (root: URL, roots: PackageManagerToolScanner.Roots) {
        let root = fm.temporaryDirectory
            .appendingPathComponent("PackageManagerToolScannerTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let home = root.appendingPathComponent("home", isDirectory: true)
        let brew = root.appendingPathComponent("homebrew", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: brew, withIntermediateDirectories: true)
        return (root, PackageManagerToolScanner.Roots(home: home, homebrewPrefixes: [brew]))
    }

    private func makeFolder(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeExecutable(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func receipt(_ onRequest: Bool, formula: String, version: String, prefix: URL) throws {
        let folder = prefix.appendingPathComponent("Cellar/\(formula)/\(version)", isDirectory: true)
        try makeFolder(folder)
        let json = #"{"installed_on_request":\#(onRequest),"installed_as_dependency":\#(!onRequest)}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("INSTALL_RECEIPT.json"))
    }

    // MARK: Homebrew

    @Test
    func homebrewListsOnlyFormulaeInstalledOnRequest() throws {
        let (root, roots) = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let prefix = roots.homebrewPrefixes[0]
        try makeExecutable(prefix.appendingPathComponent("bin/brew"))
        try receipt(true, formula: "jq", version: "1.7.1", prefix: prefix)
        try receipt(false, formula: "oniguruma", version: "6.9.9", prefix: prefix)
        try receipt(false, formula: "node", version: "20.0", prefix: prefix)
        try receipt(true, formula: "node", version: "22.0", prefix: prefix)

        let tools = PackageManagerToolScanner.homebrewFormulae(roots: roots)
        #expect(tools.map(\.name) == ["jq", "node"])
        let jq = try #require(tools.first)
        #expect(jq.command == "brew uninstall --formula jq")
        #expect(jq.executable?.path == prefix.appendingPathComponent("bin/brew").path)
        #expect(jq.arguments == ["uninstall", "--formula", "jq"])
        #expect(jq.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(jq.environment["PATH"]?.hasPrefix(prefix.appendingPathComponent("bin").path + ":") == true)
        #expect(jq.locations.map(\.path) == [prefix.appendingPathComponent("Cellar/jq").path])
    }

    // MARK: npm

    @Test
    func npmUnderNvmSkipsBundledPackagesAndNamesTheNodeVersion() throws {
        let (root, roots) = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let node = roots.home.appendingPathComponent(".nvm/versions/node/v20.20.0", isDirectory: true)
        try makeExecutable(node.appendingPathComponent("bin/node"))
        try makeExecutable(node.appendingPathComponent("bin/npm"))
        let modules = node.appendingPathComponent("lib/node_modules", isDirectory: true)
        for name in ["npm", "corepack", "vercel", "@anthropic-ai/claude-code", ".bin"] {
            try makeFolder(modules.appendingPathComponent(name))
        }
        try fm.createSymbolicLink(at: modules.appendingPathComponent("linked-project"),
                                  withDestinationURL: roots.home)

        let tools = PackageManagerToolScanner.npmGlobals(roots: roots)
        #expect(tools.map(\.name) == ["@anthropic-ai/claude-code", "vercel"])
        let vercel = try #require(tools.last)
        #expect(vercel.context == "Node 20.20.0")
        #expect(vercel.command == "npm uninstall -g vercel")
        #expect(vercel.executable?.path == node.appendingPathComponent("bin/npm").path)
        #expect(vercel.environment["npm_config_prefix"] == node.path)
        #expect(vercel.environment["PATH"]?.hasPrefix(node.appendingPathComponent("bin").path + ":") == true)
    }

    @Test
    func npmWithNoNodeOffersTheCommandToCopyOnly() throws {
        let (root, roots) = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        try makeFolder(roots.homebrewPrefixes[0].appendingPathComponent("lib/node_modules/eas-cli"))

        let tools = PackageManagerToolScanner.npmGlobals(roots: roots)
        #expect(tools.map(\.name) == ["eas-cli"])
        #expect(tools.first?.canRun == false)
    }

    // MARK: pipx, uv, Cargo

    @Test
    func pipxUvAndCargoInstallsAreListed() throws {
        let (root, roots) = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let home = roots.home
        try makeExecutable(home.appendingPathComponent(".local/bin/pipx"))
        try makeFolder(home.appendingPathComponent(".local/pipx/venvs/black"))
        try makeExecutable(home.appendingPathComponent(".local/bin/uv"))
        try makeFolder(home.appendingPathComponent(".local/share/uv/tools/ruff"))
        try makeExecutable(home.appendingPathComponent(".cargo/bin/cargo"))
        try makeExecutable(home.appendingPathComponent(".cargo/bin/rg"))
        let crates = #"{"installs":{"ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)":{"bins":["rg"]},"gone 1.0.0 (registry)":{"bins":["gone"]}}}"#
        try Data(crates.utf8).write(to: home.appendingPathComponent(".cargo/.crates2.json"))

        let tools = PackageManagerToolScanner.tools(roots: roots)
        #expect(tools.map(\.command) == ["pipx uninstall black", "uv tool uninstall ruff", "cargo uninstall ripgrep"])
        #expect(tools.allSatisfy { $0.canRun })
        #expect(tools.first { $0.manager == .pipx }?.environment["PIPX_HOME"]
            == home.appendingPathComponent(".local/pipx").path)
        #expect(tools.first { $0.manager == .cargo }?.locations.map(\.lastPathComponent) == ["rg"])
    }

    // MARK: Names

    @Test(arguments: [
        (PackageManager.homebrew, "-rf"), (.homebrew, "jq; rm"), (.homebrew, "../x"),
        (.npm, "--global"), (.npm, "@scope/"), (.npm, "a/b/c"),
        (.pipx, "-e"), (.uv, "x y"), (.cargo, "a.b")
    ])
    func optionLikeOrOddNamesAreRefused(manager: PackageManager, name: String) {
        #expect(!manager.isValidPackageName(name))
    }

    @Test(arguments: [
        (PackageManager.homebrew, "python@3.12"), (.homebrew, "libgit2"), (.npm, "@anthropic-ai/claude-code"),
        (.npm, "eas-cli"), (.pipx, "black"), (.uv, "ruff"), (.cargo, "cargo-edit")
    ])
    func realNamesAreAccepted(manager: PackageManager, name: String) {
        #expect(manager.isValidPackageName(name))
    }

    // MARK: Hand-off only

    /// A manager-owned tool is a hand-off: the delete engine refuses its
    /// folder, so nothing it lists can reach the Trash through Purge.
    @MainActor
    @Test func managerOwnedToolIsNeverAFileDeleterCandidate() async throws {
        let (root, roots) = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let home = roots.home
        let node = home.appendingPathComponent(".nvm/versions/node/v20.20.0", isDirectory: true)
        try makeFolder(node.appendingPathComponent("lib/node_modules/vercel"))
        try makeFolder(home.appendingPathComponent(".local/pipx/venvs/black"))
        try makeFolder(home.appendingPathComponent(".local/share/uv/tools/ruff"))
        try makeExecutable(home.appendingPathComponent(".local/bin/black"))

        let tools = PackageManagerToolScanner.tools(roots: roots)
        #expect(tools.count == 3)
        let trash = FakeTrash()
        let report = try await FileDeleter(home: home, trash: trash.trash)
            .deleteUserSelectedFiles(at: tools.flatMap(\.locations))
        #expect(trash.trashedPaths.isEmpty)
        #expect(report.skippedItems.count == 3)
    }
}
