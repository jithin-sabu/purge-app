import Foundation
import Testing
@testable import Purge

/// The command-line tool catalog (#225): the shipped list is valid, and the
/// parser refuses the shapes that would offer a shared folder.
@Suite("Command-line tool catalog")
struct CommandLineToolCatalogTests {
    private func parse(_ tools: String, appCatalog: AppDotFolderCatalog = .empty) throws -> CommandLineToolCatalog {
        try CommandLineToolCatalog.parse(Data((#"{"tools":["# + tools + "]}").utf8), appCatalog: appCatalog)
    }

    @Test
    func shippedCatalogLoadsFromTheAppBundle() {
        let shipped = CommandLineToolCatalog.shared
        #expect(shipped.entries.map(\.name) == ["Claude Code", "Cursor Agent", "opencode"])
        let claude = shipped.entries.first { $0.name == "Claude Code" }
        #expect(claude?.folder == "~/.local/share/claude")
        #expect(claude?.kept.contains("~/.claude") == true)
    }

    /// The shipped catalog must also pass against the shipped app catalog.
    @Test
    func shippedCatalogDoesNotTouchTheAppCatalog() throws {
        let url = try #require(Bundle.main.url(forResource: CommandLineToolCatalog.resourceName, withExtension: "json"))
        _ = try CommandLineToolCatalog.parse(Data(contentsOf: url), appCatalog: .shared)
    }

    @Test(arguments: ["~/.gemini", "~/.config", "~/.local/share", "~/.local", "~/.nvm", "~/.cursor"])
    func sharedFolderIsRefused(folder: String) {
        #expect(throws: CommandLineToolCatalog.ValidationError.sharedFolder(folder)) {
            try parse(#"{"name":"X","folder":"\#(folder)","shims":[],"kept":[]}"#)
        }
    }

    @Test(arguments: ["/usr/local/x", "~/visible", "~/.x/../y", "~/./x", "~/.x//y"])
    func pathOutsideAHiddenHomeFolderIsRefused(folder: String) {
        #expect(throws: CommandLineToolCatalog.ValidationError.notAHiddenHomePath(folder)) {
            try parse(#"{"name":"X","folder":"\#(folder)","shims":[],"kept":[]}"#)
        }
    }

    @Test
    func nestedFoldersAreRefused() {
        #expect(throws: CommandLineToolCatalog.ValidationError.nested(parent: "~/.tool", child: "~/.tool/sub")) {
            try parse("""
                {"name":"A","folder":"~/.tool","shims":[],"kept":[]},
                {"name":"B","folder":"~/.tool/sub","shims":[],"kept":[]}
                """)
        }
    }

    @Test(arguments: ["~/.local/bin", "~/.local/bin/a/b", "~/bin/tool", "~/.local/bin/.."])
    func shimOutsideTheShimFolderIsRefused(shim: String) {
        #expect(throws: CommandLineToolCatalog.ValidationError.shimOutsideLocalBin(shim)) {
            try parse(#"{"name":"X","folder":"~/.tool","shims":["\#(shim)"],"kept":[]}"#)
        }
    }

    @Test
    func keptPathInsideTheFolderIsRefused() {
        #expect(throws: CommandLineToolCatalog.ValidationError.keptInsideFolder("~/.tool/settings")) {
            try parse(#"{"name":"X","folder":"~/.tool","shims":[],"kept":["~/.tool/settings"]}"#)
        }
    }

    @Test
    func overlapWithTheAppCatalogIsRefused() throws {
        let apps = try AppDotFolderCatalog.parse(Data("""
            {"apps":[{"bundle_id":"com.example.app","display_name":"App","folders":["~/.antigravity"]}]}
            """.utf8))
        #expect(throws: CommandLineToolCatalog.ValidationError.overlapsAppCatalog("~/.antigravity")) {
            try parse(#"{"name":"X","folder":"~/.antigravity","shims":[],"kept":[]}"#, appCatalog: apps)
        }
    }
}
