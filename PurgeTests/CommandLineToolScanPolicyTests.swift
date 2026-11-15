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

    /// An executable file, as a tool's program is.
    @discardableResult
    private func program(_ relative: String, in home: URL) throws -> URL {
        let url = try write("#!/bin/sh\n", to: relative, in: home)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A launcher script in `~/.local/bin`, executable like a real one.
    @discardableResult
    private func script(_ name: String, _ body: String, in home: URL) throws -> URL {
        let url = try write("#!/bin/sh\n\(body)\n", to: ".local/bin/\(name)", in: home)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
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
    /// program inside `~/.hermes`, each named after the folder.
    @Test
    func scriptShimsPointingIntoHermesPairWithIt() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".hermes/hermes-agent/.hermes/bin/hermes", in: home)
        try program(".hermes/hermes-agent/.hermes/bin/hermes-acp", in: home)
        let bin = "\(home.path)/.hermes/hermes-agent/.hermes/bin"
        let a = try script("hermes", "exec \(bin)/hermes \"$@\"", in: home)
        let b = try script("hermes-acp", "exec \(bin)/hermes-acp \"$@\"", in: home)
        let c = try script("hermes-agent", "exec \"$HOME/.hermes/hermes-agent/.hermes/bin/hermes\" --run-module run_agent \"$@\"", in: home)

        let found = installs(home)
        #expect(found.count == 1)
        #expect(found.first?.name == "hermes")
        #expect(found.first?.source == .shim)
        #expect(found.first?.folder.path == home.appendingPathComponent(".hermes").path)
        #expect(found.first?.shims.map(\.path) == [a, b, c].map(\.path))
    }

    /// The Grok shape: a symlink into `~/.grok`, whose own link stays inside it
    /// and ends at an executable.
    @Test
    func symlinkShimPairsWithItsFolder() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".grok/bin", in: home)
        try program(".grok/downloads/grok-1.0", in: home)
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
        try program(".tool/bin/tool", in: home)
        try makeFolder("Library/Application Support/Reason/CLI", in: home)
        try link(".local/bin/ara", to: "\(home.path)/Library/Application Support/Reason/CLI/current", in: home)
        try link(".local/bin/brewed", to: "/opt/homebrew/bin/brewed", in: home)
        try script("tool", "exec /opt/homebrew/bin/tool --config \(home.path)/.tool \"$@\"", in: home)

        #expect(installs(home).isEmpty)
    }

    /// `reason -> ara -> Application Support`: the chain leaves the dot folders.
    @Test
    func linkChainThroughTheShimFolderPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".reason/bin/reason", in: home)
        try program("Library/Application Support/Reason/current", in: home)
        try link(".local/bin/ara", to: "\(home.path)/Library/Application Support/Reason/current", in: home)
        try link(".local/bin/reason", to: "ara", in: home)

        #expect(installs(home).isEmpty)
    }

    @Test
    func scriptNamingTwoDotFoldersPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".one/bin/one", in: home)
        try makeFolder(".two", in: home)
        try script("one", "export DATA=~/.two\nexec ~/.one/bin/one \"$@\"", in: home)

        #expect(installs(home).isEmpty)
    }

    @Test
    func compiledBinaryAndBigScriptPairWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".big/bin/big", in: home)
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C]).write(to: home.appendingPathComponent(".local/bin/instabox"))
        let padding = String(repeating: "# filler\n", count: 600)
        try script("big", "\(padding)exec ~/.big/bin/big", in: home)

        #expect(installs(home).isEmpty)
    }

    /// Stow or a dotfiles `install.sh` links commands into `~/.local/bin`. The
    /// shim is not named after the folder, and the folder is a repo that can
    /// hold unpushed work, so neither part may offer it.
    @Test
    func dotfilesRepoLinkPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".dotfiles/bin/foo", in: home)
        try program(".dotfiles/bin/dotfiles", in: home)
        try makeFolder(".dotfiles/.git", in: home)
        try link(".local/bin/foo", to: "\(home.path)/.dotfiles/bin/foo", in: home)
        try link(".local/bin/dotfiles", to: "\(home.path)/.dotfiles/bin/dotfiles", in: home)

        #expect(installs(home).isEmpty)
    }

    /// Doom Emacs links `doom` into `~/.emacs.d`. The name doesn't match the
    /// folder, so the whole Emacs config is never offered.
    @Test
    func shimNamedForSomethingElsePairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".emacs.d/bin/doom", in: home)
        try link(".local/bin/doom", to: "\(home.path)/.emacs.d/bin/doom", in: home)

        #expect(installs(home).isEmpty)
    }

    /// A wrapper that only sets a variable to a folder runs nothing from it.
    @Test(arguments: [
        "PASSWORD_STORE_DIR=~/.password-store exec pass \"$@\"",
        "PASSWORD_STORE_DIR=\"$HOME/.password-store/bin/password-store\" exec pass \"$@\"",
        "exec /usr/bin/env --store=~/.password-store/bin/password-store"
    ])
    func folderNamedOnlyAsDataPairsWithNothing(body: String) throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".password-store/bin/password-store", in: home)
        try script("password-store", body, in: home)

        #expect(installs(home).isEmpty)
    }

    /// A link whose target is gone runs nothing, even into a folder that exists.
    @Test
    func danglingLinkPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".tool/bin", in: home)
        try link(".local/bin/tool", to: "\(home.path)/.tool/bin/tool", in: home)

        #expect(installs(home).isEmpty)
    }

    @Test
    func folderThatIsARepositoryPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".tool/bin/tool", in: home)
        try write("gitdir: elsewhere", to: ".tool/.git", in: home)
        try link(".local/bin/tool", to: "\(home.path)/.tool/bin/tool", in: home)

        #expect(installs(home).isEmpty)
    }

    /// Shared folders, version managers and app folders are never a tool's,
    /// even when a shim named after one points straight into it.
    @Test(arguments: [".gemini", ".nvm", ".local", ".config", ".cargo", ".cursor", ".claude",
                      ".lmstudio", ".ollama", ".rd", ".ghcup", ".dotnet", ".aws"])
    func sharedFolderIsNeverOfferedWhole(name: String) throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let tool = String(name.dropFirst())
        try program("\(name)/tool-bin/\(tool)", in: home)
        try link(".local/bin/\(tool)", to: "\(home.path)/\(name)/tool-bin/\(tool)", in: home)

        #expect(installs(home).isEmpty)
        #expect(!CommandLineToolScanPolicy.isEligibleForDeletion(
            home.appendingPathComponent(name), home: home, catalog: .empty, appCatalog: .empty))
    }

    /// The volume ignores case. A shim spelling `~/.SSH` or `~/.TOOL` reaches
    /// `~/.ssh` or `~/.tool`; neither spelling may pair.
    @Test
    func caseVariantSpellingPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".ssh/bin/ssh", in: home)
        try program(".tool/bin/tool", in: home)
        try link(".local/bin/ssh", to: "\(home.path)/.SSH/bin/ssh", in: home)
        try link(".local/bin/tool", to: "\(home.path)/.TOOL/bin/tool", in: home)

        #expect(installs(home).isEmpty)
    }

    /// `~/.antigravity` belongs to an app in the app catalog, so a shim into it
    /// does not make it a command-line tool.
    @Test
    func appCatalogFolderIsNeverATool() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".antigravity/bin/antigravity", in: home)
        try link(".local/bin/antigravity", to: "\(home.path)/.antigravity/bin/antigravity", in: home)
        let appCatalog = try AppDotFolderCatalog.parse(Data("""
            {"apps":[{"bundle_id":"com.google.antigravity","display_name":"Antigravity","folders":["~/.antigravity"]}]}
            """.utf8))

        #expect(installs(home).map(\.name) == ["antigravity"])
        #expect(installs(home, appCatalog: appCatalog).isEmpty)
    }

    /// A model store moved with `OLLAMA_MODELS` into a folder the deny list
    /// does not know still keeps that folder from being offered as a tool.
    @Test
    func folderHoldingAModelStoreIsNeverATool() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try makeFolder(".mytool/models", in: home)
        try program(".mytool/bin/mytool", in: home)
        try link(".local/bin/mytool", to: "\(home.path)/.mytool/bin/mytool", in: home)
        let environment = ["OLLAMA_MODELS": home.appendingPathComponent(".mytool/models").path]

        #expect(installs(home).map(\.name) == ["mytool"])
        #expect(CommandLineToolScanPolicy.pairedInstalls(
            home: home, catalog: .empty, appCatalog: .empty, environment: environment
        ).isEmpty)
    }

    @Test
    func linkedFolderPairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program("Elsewhere/tool/bin/tool", in: home)
        try link(".tool", to: home.appendingPathComponent("Elsewhere/tool").path, in: home)
        try link(".local/bin/tool", to: "\(home.path)/.tool/bin/tool", in: home)

        #expect(installs(home).isEmpty)
    }

    @Test
    func shimIntoAnAppBundlePairsWithNothing() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try program(".kit/Kit.app/Contents/MacOS/kit", in: home)
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
        try program(".local/share/claude/versions/2.1.0", in: home)
        try makeFolder(".claude", in: home)
        let shim = try link(".local/bin/claude", to: "\(home.path)/.local/share/claude/versions/2.1.0", in: home)
        try program(".local/share/other/bin", in: home)
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

    private func makeDaemon(in home: URL) throws -> URL {
        try program(".daemon/bin/daemon", in: home)
        try link(".local/bin/daemon", to: "\(home.path)/.daemon/bin/daemon", in: home)
        return try makeFolder("Library/LaunchAgents", in: home)
    }

    @Test
    func launchAgentStartingFromTheFolderIsPaired() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let agents = try makeDaemon(in: home)
        let paired = agents.appendingPathComponent("com.example.daemon.plist")
        let script = agents.appendingPathComponent("com.example.script.plist")
        let other = agents.appendingPathComponent("com.example.other.plist")
        try (["Label": "com.example.daemon",
              "ProgramArguments": ["\(home.path)/.daemon/bin/daemon", "serve"]] as NSDictionary).write(to: paired)
        try (["Label": "com.example.script",
              "ProgramArguments": ["/bin/sh", "\(home.path)/.daemon/bin/daemon"]] as NSDictionary).write(to: script)
        try (["Label": "com.example.other", "Program": "/usr/bin/true"] as NSDictionary).write(to: other)

        let found = installs(home)
        #expect(found.first?.launchAgents.map(\.label) == ["com.example.daemon", "com.example.script"])
        #expect(found.first?.removalPaths.map(\.path).contains(paired.standardizedFileURL.path) == true)
    }

    /// A user's backup job, or another tool's job, that only names the folder
    /// as data is neither stopped nor trashed with the tool.
    @Test
    func launchAgentNamingTheFolderAsDataIsNotPaired() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let agents = try makeDaemon(in: home)
        try (["Label": "com.example.backup",
              "ProgramArguments": ["/usr/bin/rsync", "-a", "\(home.path)/.daemon/sessions", "/Volumes/B/"]] as NSDictionary)
            .write(to: agents.appendingPathComponent("com.example.backup.plist"))
        try (["Label": "com.example.other",
              "ProgramArguments": ["/usr/local/bin/other", "--config", "\(home.path)/.daemon/cfg.yaml"]] as NSDictionary)
            .write(to: agents.appendingPathComponent("com.example.other.plist"))
        try (["Label": "com.example.inline",
              "ProgramArguments": ["/bin/sh", "-c", "\(home.path)/.daemon/bin/daemon"]] as NSDictionary)
            .write(to: agents.appendingPathComponent("com.example.inline.plist"))

        let found = installs(home)
        #expect(found.map(\.name) == ["daemon"])
        #expect(found.first?.launchAgents.isEmpty == true)
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
        try program(".hermes/bin/hermes", in: home)
        let folder = home.appendingPathComponent(".hermes").standardizedFileURL
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
