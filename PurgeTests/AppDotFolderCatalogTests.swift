import Foundation
import Testing
@testable import Purge

/// The dot-folder catalog (#224): the shipped list is valid and names exact
/// folders, and the parser refuses the shapes that would offer too much.
@Suite("App dot-folder catalog")
struct AppDotFolderCatalogTests {
    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)

    private func catalog(_ json: String) throws -> AppDotFolderCatalog {
        try AppDotFolderCatalog.parse(Data(json.utf8))
    }

    @Test
    func shippedCatalogLoadsFromTheAppBundle() {
        let shipped = AppDotFolderCatalog.shared
        #expect(!shipped.entries.isEmpty)
        let antigravity = shipped.entries.first { $0.bundleID == "com.google.antigravity" }
        #expect(antigravity?.displayName == "Antigravity")
        #expect(antigravity?.folders == [
            "~/.gemini/antigravity",
            "~/.gemini/antigravity-ide",
            "~/.gemini/antigravity-backup",
            "~/.gemini/antigravity-browser-profile",
            "~/.antigravity"
        ])
        #expect(shipped.entries.first { $0.bundleID == "com.trae.app" }?.folders == ["~/.trae"])
    }

    /// `~/.cursor` stays in use by the cursor-agent CLI after Cursor.app is gone,
    /// and the Cursor policies in Dev Tools promise it is never offered whole.
    @Test
    func cursorIsNotInTheCatalog() {
        let shipped = AppDotFolderCatalog.shared
        #expect(!shipped.entries.contains { $0.bundleID == "com.todesktop.230313mzl4w4u92" })
        #expect(!shipped.entries.flatMap(\.folders).contains { $0 == "~/.cursor" || $0.hasPrefix("~/.cursor/") })
    }

    /// `~/.gemini` also holds the Gemini CLI's settings, config and skills. It is
    /// not in the catalog, and the parser would refuse a catalog that listed it
    /// beside its children.
    @Test
    func sharedParentIsNeverListed() throws {
        let folders = AppDotFolderCatalog.shared.entries.flatMap(\.folders)
        #expect(!folders.contains("~/.gemini"))
        try AppDotFolderCatalog.validate(AppDotFolderCatalog.shared.entries)

        #expect(throws: AppDotFolderCatalog.ValidationError.sharedParent(parent: "~/.gemini", child: "~/.gemini/antigravity")) {
            try catalog("""
            {"apps": [{"bundle_id": "com.google.antigravity", "display_name": "Antigravity",
                       "folders": ["~/.gemini/antigravity", "~/.gemini"]}]}
            """)
        }
    }

    @Test
    func onlyHiddenHomeFoldersAreAccepted() {
        for bad in ["~/Documents/app", "~/.", "/Users/alice/.app", ".app", "~/.app/", "~/.app/../other", "~/.app//x"] {
            #expect(throws: AppDotFolderCatalog.ValidationError.notAHiddenHomeFolder(bad)) {
                try catalog("""
                {"apps": [{"bundle_id": "com.vendor.App", "display_name": "App", "folders": ["\(bad)"]}]}
                """)
            }
        }
    }

    @Test
    func badOrAppleBundleIDsAreRefused() {
        #expect(throws: AppDotFolderCatalog.ValidationError.badBundleID("App")) {
            try catalog("""
            {"apps": [{"bundle_id": "App", "display_name": "App", "folders": ["~/.app"]}]}
            """)
        }
        #expect(throws: AppDotFolderCatalog.ValidationError.appleBundleID("com.apple.Terminal")) {
            try catalog("""
            {"apps": [{"bundle_id": "com.apple.Terminal", "display_name": "Terminal", "folders": ["~/.terminal"]}]}
            """)
        }
    }

    @Test
    func duplicateFoldersAreRefused() {
        #expect(throws: AppDotFolderCatalog.ValidationError.duplicateFolder("~/.shared")) {
            try catalog("""
            {"apps": [{"bundle_id": "com.a.App", "display_name": "A", "folders": ["~/.shared"]},
                      {"bundle_id": "com.b.App", "display_name": "B", "folders": ["~/.shared"]}]}
            """)
        }
    }

    /// A broken catalog offers nothing rather than something half right.
    @Test
    func unreadableCatalogIsEmpty() {
        #expect(AppDotFolderCatalog.load(bundle: Bundle(for: ThrowawayDefaults.self)).entries.isEmpty)
    }

    @Test
    func entryMatchesExactPathsOnly() throws {
        let parsed = try catalog("""
        {"apps": [{"bundle_id": "com.google.antigravity", "display_name": "Antigravity",
                   "folders": ["~/.gemini/antigravity", "~/.antigravity"]}]}
        """)
        func entry(_ path: String) -> String? {
            parsed.entry(forFolderAt: URL(fileURLWithPath: path, isDirectory: true), home: home)?.bundleID
        }
        #expect(entry("/Users/alice/.gemini/antigravity") == "com.google.antigravity")
        #expect(entry("/Users/alice/.gemini/antigravity/") == "com.google.antigravity")
        #expect(entry("/Users/alice/.antigravity") == "com.google.antigravity")
        #expect(entry("/Users/alice/.gemini") == nil)
        #expect(entry("/Users/alice/.gemini/antigravity/extensions") == nil)
        #expect(entry("/Users/alice/.gemini/antigravity-ide") == nil)
        #expect(entry("/Users/bob/.antigravity") == nil)
    }
}
