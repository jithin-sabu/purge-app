import Foundation
import Testing
@testable import Purge

/// The About screen's "never touches" line once named Documents, Downloads and
/// Application Support, where cleaning does take caches and build folders, and
/// said Purge never needs admin rights, although the uninstaller removes apps
/// that need them (#191). Each folder it names must be one `evaluate` refuses
/// along with everything inside it.
@MainActor
@Suite("About's never-touches line matches the policy")
struct SafetyAllowlistSummaryTests {
    private let home = DeletionSafetyPolicy.cachedHomePath

    /// Folder for each label the line can name. Labels are compared as the app
    /// shows them, so the checks hold in every language the test host runs in.
    private let foldersByLabel = [
        String(localized: "keychains"): "Library/Keychains",
        String(localized: "preferences"): "Library/Preferences",
        String(localized: "Mail mailboxes"): "Library/Mail",
        String(localized: "pictures"): "Pictures",
        String(localized: "music"): "Music",
        String(localized: "movies"): "Movies",
    ]

    private var namedFolders: [String] {
        SafetyAllowlistSummary.neverCleanedFolderLabels.compactMap { foldersByLabel[$0] }
    }

    @Test
    func everyNamedFolderIsRefusedWithEverythingInside() {
        let named = SafetyAllowlistSummary.neverCleanedFolderLabels
        #expect(named.count == namedFolders.count, "a label with no folder: \(named)")
        #expect(namedFolders == ["Library/Keychains", "Library/Preferences", "Library/Mail", "Pictures", "Music"])
        let allowlisted = DeletionSafetyPolicy.whitelistedAbsolutePrefixes(home: home)
        for relative in namedFolders {
            let folder = "\(home)/\(relative)"
            // The allowlist is checked before the never-delete folders, so an
            // allowlisted path inside one would be cleaned.
            #expect(!allowlisted.contains { $0 == folder || $0.hasPrefix(folder + "/") }, "\(folder)")
            for inside in ["", "/Caches", "/Caches/com.example.app", "/project/node_modules", "/project/target"] {
                let url = URL(fileURLWithPath: folder + inside)
                #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete, "\(url.path)")
            }
        }
    }

    /// DaVinci Resolve's `~/Movies/CacheClip` is allowlisted and Safe, so the
    /// line must not say cleaning never touches movies.
    @Test
    func moviesIsNotNamedWhileCacheClipIsCleaned() {
        #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "\(home)/Movies/CacheClip")) == .allow)
        #expect(!namedFolders.contains("Movies"))
    }

    /// These are refused as folders only. Cleaning reaches inside them, so the
    /// line must not name them.
    @Test
    func foldersCleaningReachesInsideAreNotNamed() {
        let reachedInto = ["Documents", "Desktop", "Downloads", "Library/Application Support"]
        for folder in reachedInto {
            #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "\(home)/\(folder)")) == .blockedNeverDelete)
        }
        #expect(Set(namedFolders).isDisjoint(with: reachedInto))
    }

    @Test
    func lineSaysLargeFilesAndTheUninstallerAreSeparate() {
        let line = SafetyAllowlistSummary.boundaryLine
        for label in SafetyAllowlistSummary.neverCleanedFolderLabels {
            #expect(line.contains(label), "\(label)")
        }
        #expect(line.contains(String(localized: "system folders that need an admin password, except leftover macOS update files")))
        #expect(line.hasSuffix(String(localized: "Large Files and the uninstaller remove only what you confirm, which can include your own files and apps that need an admin password.")))
    }

    @Test
    func allowlistLinkFollowsTheInstalledVersion() {
        #expect(AboutView.allowlistPolicyURL(version: "1.13.1").absoluteString
            == "https://github.com/jithin-sabu/purge-app/blob/v1.13.1/purge/Services/DeletionSafetyPolicy.swift")
        for version in [nil, "", "1.14.0 beta", "1.0b2"] {
            #expect(AboutView.allowlistPolicyURL(version: version).absoluteString.contains("/blob/main/"), "\(version ?? "nil")")
        }
    }
}
