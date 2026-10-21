import Foundation
import Testing
@testable import Purge

/// Standalone command-line tool installs (#225): which shims pair with which
/// folder, what is never offered whole, and what the gate accepts. Every test
/// builds its own home in a temporary folder.
@Suite("Command-line tool scan policy")
struct CommandLineToolScanPolicyTests {
    private let fm = FileManager.default

    private func makeHome() throws -> URL {
        let home = fm.temporaryDirectory
            .appendingPathComponent("CommandLineToolScanPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        return home.standardizedFileURL
    }

    @discardableResult
    private func makeFolder(_ relative: String, in home: URL) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    @discardableResult
    private func write(_ text: String, to relative: String, in home: URL) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.standardizedFileURL
    }

    @discardableResult
    private func link(_ relative: String, to destination: String, in home: URL) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fm.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        return url.standardizedFileURL
    }

    private func installs(_ home: URL, catalog: CommandLineToolCatalog = .empty,
                          appCatalog: AppDotFolderCatalog = .empty) -> [CommandLineToolInstall] {
        CommandLineToolScanPolicy.pairedInstalls(home: home, catalog: catalog, appCatalog: appCatalog)
    }

    // MARK: Pairing

    /// The Hermes shape on a real Mac: three `#!/bin/sh` launchers that exec a
    /// program inside `~/.hermes`.
    @Test
    func scriptShimsPointingIntoHermesPairWithIt() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".hermes/hermes-agent/.hermes/bin", in: home)
        let program = "\(home.path)/.hermes/hermes-agent/.hermes/bin/hermes"
        let a = try write("#!/bin/sh\nexec \(program) \"$@\"\n", to: ".local/bin/hermes", in: home)
        let b = try write("#!/bin/sh\nexec \(program)-acp \"$@\"\n", to: ".local/bin/hermes-acp", in: home)
        let c = try write("#!/bin/sh\nexec \"$HOME/.hermes/hermes-agent/.hermes/bin/hermes\" --run-module run_agent \"$@\"\n",
                          to: ".local/bin/hermes-agent", in: home)

        let found = installs(home)
        #expect(found.count == 1)
        #expect(found.first?.name == "hermes")
        #expect(found.first?.source == .shim)
        #expect(found.first?.folder.path == home.appendingPathComponent(".hermes").path)
        #expect(found.first?.shims.map(\.path) == [a, b, c].map(\.path))
    }

    /// The Grok shape: a symlink into `~/.grok`, whose own link stays inside it.
    @Test
    func symlinkShimPairsWithItsFolder() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".grok/bin", in: home)
        try write("binary", to: ".grok/downloads/grok-1.0", in: home)
        try link(".grok/bin/grok", to: "../downloads/grok-1.0", in: home)
        let shim = try link(".local/bin/grok", to: "\(home.path)/.grok/bin/grok", in: home)

        let found = installs(home)
        #expect(found.map(\.name) == ["grok"])
        #expect(found.first?.shims.map(\.path) == [shim.path])
    }

    @Test
    func shimPointingElsewherePairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".tool", in: home)
        try makeFolder("Library/Application Support/Reason/CLI", in: home)
        try link(".local/bin/ara", to: "\(home.path)/Library/Application Support/Reason/CLI/current", in: home)
        try link(".local/bin/brewed", to: "/opt/homebrew/bin/brewed", in: home)
        try write("#!/bin/sh\nexec /opt/homebrew/bin/tool --config \(home.path)/.tool \"$@\"\n",
                  to: ".local/bin/tool", in: home)

        #expect(installs(home).isEmpty)
    }

    /// `reason -> ara -> Application Support`: the chain leaves the dot folders.
    @Test
    func linkChainThroughTheShimFolderPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".reason/bin", in: home)
        try makeFolder("Library/Application Support/Reason", in: home)
        try link(".local/bin/ara", to: "\(home.path)/Library/Application Support/Reason/current", in: home)
        try link(".local/bin/reason", to: "ara", in: home)

        #expect(installs(home).isEmpty)
    }

    @Test
    func scriptNamingTwoDotFoldersPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".one", in: home)
        try makeFolder(".two", in: home)
        try write("#!/bin/sh\nexport DATA=~/.two\nexec ~/.one/bin/one \"$@\"\n", to: ".local/bin/one", in: home)

        #expect(installs(home).isEmpty)
    }

    @Test
    func compiledBinaryAndBigScriptPairWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".big", in: home)
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C]).write(to: home.appendingPathComponent(".local/bin/instabox"))
        let padding = String(repeating: "# filler\n", count: 600)
        try write("#!/bin/sh\n\(padding)exec ~/.big/bin/big\n", to: ".local/bin/big", in: home)

        #expect(installs(home).isEmpty)
    }

    /// Shared folders, version managers and app folders are never a tool's,
    /// even when a shim points straight into them.
    @Test(arguments: [".gemini", ".nvm", ".local", ".config", ".cargo", ".cursor", ".claude"])
    func sharedFolderIsNeverOfferedWhole(name: String) throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try write("binary", to: "\(name)/tool-bin/tool", in: home)
        try link(".local/bin/tool", to: "\(home.path)/\(name)/tool-bin/tool", in: home)

        #expect(installs(home).isEmpty)
        #expect(!CommandLineToolScanPolicy.isEligibleForDeletion(
            home.appendingPathComponent(name), home: home, catalog: .empty, appCatalog: .empty))
    }

    /// `~/.antigravity` belongs to an app in the app catalog, so a shim into it
    /// does not make it a command-line tool.
    @Test
    func appCatalogFolderIsNeverATool() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".antigravity/bin", in: home)
        try link(".local/bin/agy", to: "\(home.path)/.antigravity/bin/agy", in: home)
        let appCatalog = try AppDotFolderCatalog.parse(Data("""
            {"apps":[{"bundle_id":"com.google.antigravity","display_name":"Antigravity","folders":["~/.antigravity"]}]}
            """.utf8))

        #expect(installs(home, appCatalog: appCatalog).isEmpty)
    }

    @Test
    func linkedFolderPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let elsewhere = try makeFolder("Elsewhere/tool", in: home)
        try link(".tool", to: elsewhere.path, in: home)
        try link(".local/bin/tool", to: "\(home.path)/.tool/bin/tool", in: home)

        #expect(installs(home).isEmpty)
    }

    @Test
    func shimIntoAnAppBundlePairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".kit/Kit.app/Contents/MacOS", in: home)
        try link(".local/bin/kit", to: "\(home.path)/.kit/Kit.app/Contents/MacOS/kit", in: home)

        #expect(installs(home).isEmpty)
    }

    // MARK: Catalog

    private func catalog(_ json: String) throws -> CommandLineToolCatalog {
        try CommandLineToolCatalog.parse(Data(json.utf8), appCatalog: .empty)
    }

    /// Claude Code's native install: `~/.local/share/claude` with a symlink in
    /// `~/.local/bin`. Only the catalog can offer it, and `~/.claude` stays.
    @Test
    func catalogEntryPairsItsShimAndKeepsItsSettings() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".local/share/claude/versions", in: home)
        try write("binary", to: ".local/share/claude/versions/2.1.0", in: home)
        try makeFolder(".claude", in: home)
        let shim = try link(".local/bin/claude", to: "\(home.path)/.local/share/claude/versions/2.1.0", in: home)
        try link(".local/bin/other", to: "\(home.path)/.local/share/other/bin", in: home)
        let tools = try catalog("""
            {"tools":[{"name":"Claude Code","folder":"~/.local/share/claude",
              "shims":["~/.local/bin/claude","~/.local/bin/other"],"kept":["~/.claude","~/.claude.json"]}]}
            """)

        let found = installs(home, catalog: tools)
        #expect(found.count == 1)
        #expect(found.first?.name == "Claude Code")
        #expect(found.first?.source == .catalog)
        #expect(found.first?.shims.map(\.path) == [shim.path])
        #expect(found.first?.kept.map(\.lastPathComponent) == [".claude"])
        let removal = found.first?.removalPaths.map(\.path) ?? []
        #expect(removal == [home.appendingPathComponent(".local/share/claude").path, shim.path])
    }

    @Test
    func catalogEntryWithoutItsFolderIsNotOffered() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let tools = try catalog("""
            {"tools":[{"name":"opencode","folder":"~/.opencode","shims":[],"kept":[]}]}
            """)
        #expect(installs(home, catalog: tools).isEmpty)
        try makeFolder(".opencode/bin", in: home)
        #expect(installs(home, catalog: tools).map(\.name) == ["opencode"])
    }

    // MARK: LaunchAgents and settings

    @Test
    func launchAgentStartingFromTheFolderIsPaired() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".daemon/bin", in: home)
        try link(".local/bin/daemon", to: "\(home.path)/.daemon/bin/daemon", in: home)
        let agents = try makeFolder("Library/LaunchAgents", in: home)
        let paired = agents.appendingPathComponent("com.example.daemon.plist")
        let other = agents.appendingPathComponent("com.example.other.plist")
        try (["Label": "com.example.daemon",
              "ProgramArguments": ["\(home.path)/.daemon/bin/daemon", "serve"]] as NSDictionary).write(to: paired)
        try (["Label": "com.example.other", "Program": "/usr/bin/true"] as NSDictionary).write(to: other)

        let found = installs(home)
        #expect(found.first?.launchAgents.map(\.label) == ["com.example.daemon"])
        #expect(found.first?.launchAgents.map(\.plist.path) == [paired.standardizedFileURL.path])
        #expect(found.first?.removalPaths.map(\.path).contains(paired.standardizedFileURL.path) == true)
    }

    @Test
    func settingsFilesAreListedByName() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let folder = try makeFolder(".hermes", in: home)
        for name in [".env", "auth.json", "SOUL.md", "config.yaml", "README.md", "state.db", "models.json"] {
            try write("x", to: ".hermes/\(name)", in: home)
        }
        try makeFolder(".hermes/sessions.toml", in: home)

        #expect(CommandLineToolScanPolicy.settingsFiles(in: folder) == [".env", "auth.json", "config.yaml", "SOUL.md"])
    }

    // MARK: Gate

    @Test
    func gateAcceptsOnlyWhatTheScanPaired() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let folder = try makeFolder(".hermes/bin", in: home).deletingLastPathComponent()
        let inside = try write("x", to: ".hermes/.env", in: home)
        let shim = try link(".local/bin/hermes", to: "\(home.path)/.hermes/bin/hermes", in: home)
        let unpaired = try makeFolder(".unpaired", in: home)
        let strayShim = try link(".local/bin/stray", to: "/usr/bin/true", in: home)

        func eligible(_ url: URL) -> Bool {
            CommandLineToolScanPolicy.isEligibleForDeletion(url, home: home, catalog: .empty, appCatalog: .empty)
        }
        #expect(eligible(folder))
        #expect(eligible(shim))
        #expect(!eligible(inside))
        #expect(!eligible(unpaired))
        #expect(!eligible(strayShim))
        #expect(!eligible(home.appendingPathComponent(".local/bin")))
        #expect(!eligible(home))
    }
}
