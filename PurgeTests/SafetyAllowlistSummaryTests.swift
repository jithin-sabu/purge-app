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

    @Test
    func everyNamedFolderIsRefusedWithEverythingInside() {
        let named = SafetyAllowlistSummary.neverCleanedFolderLabels
        #expect(named == ["keychains", "preferences", "mail", "pictures", "music", "movies"])
        for folder in ["Library/Keychains", "Library/Preferences", "Library/Mail", "Pictures", "Music", "Movies"] {
            for inside in ["", "/Caches", "/Caches/com.example.app", "/project/node_modules", "/project/target"] {
                let url = URL(fileURLWithPath: "\(home)/\(folder)\(inside)")
                #expect(DeletionSafetyPolicy.evaluate(url) == .blockedNeverDelete, "\(url.path)")
            }
        }
    }

    /// These are refused as folders only. Cleaning reaches inside them, so the
    /// line must not name them.
    @Test
    func foldersCleaningReachesInsideAreNotNamed() {
        for folder in ["Documents", "Desktop", "Downloads", "Library/Application Support"] {
            #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "\(home)/\(folder)")) == .blockedNeverDelete)
        }
        let line = SafetyAllowlistSummary.boundaryLine.lowercased()
        for name in ["documents", "desktop", "downloads", "application support"] {
            #expect(!line.contains(name), "\(name)")
        }
    }

    @Test
    func lineSaysLargeFilesAndTheUninstallerAreSeparate() {
        let line = SafetyAllowlistSummary.boundaryLine
        #expect(line.hasPrefix("Cleaning never touches "))
        #expect(line.contains("Large Files and the uninstaller remove only what you confirm"))
        #expect(line.contains("apps that need an admin password"))
        #expect(!line.contains("anything requiring admin privileges"))
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
