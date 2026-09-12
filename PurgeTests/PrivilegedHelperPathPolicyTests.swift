import Foundation
import Testing
@testable import Purge

/// The helper runs with administrator access, so it must accept only paths the app
/// uninstaller can genuinely produce. These tests pin that narrow boundary.
@Suite("Privileged helper path policy")
struct PrivilegedHelperPathPolicyTests {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    private func isAllowed(_ path: String) -> Bool {
        PurgeHelperConstants.isAllowedUninstallLocation(
            URL(fileURLWithPath: path),
            homeDirectory: home
        )
    }

    @Test("Allows app bundles offered by the app picker")
    func allowsApplicationBundles() {
        #expect(isAllowed("/Applications/Teams.app"))
        #expect(isAllowed("/Applications/Utilities/Widget.app"))
        #expect(isAllowed("/Users/example/Applications/Personal.app"))
    }

    @Test("Allows only direct children of known leftover folders")
    func allowsKnownLeftovers() {
        #expect(isAllowed("/Users/example/Library/Caches/com.vendor.app"))
        #expect(isAllowed("/Users/example/Library/Application Support/Vendor"))
        #expect(isAllowed("/Library/LaunchDaemons/com.vendor.helper.plist"))
        #expect(isAllowed("/Library/Application Support/Vendor"))

        #expect(!isAllowed("/Users/example/Library/Caches/Vendor/nested.db"))
        #expect(!isAllowed("/Library/Application Support/Vendor/nested.db"))
    }

    @Test("Refuses sensitive and caller-chosen locations")
    func refusesOtherLocations() {
        #expect(!isAllowed("/"))
        #expect(!isAllowed("/System/Library/CoreServices/Finder.app"))
        #expect(!isAllowed("/Library/Keychains/System.keychain"))
        #expect(!isAllowed("/private/etc/passwd"))
        #expect(!isAllowed("/Users/other/Library/Caches/com.vendor.app"))
        #expect(!isAllowed("/Applications/not-an-app"))
        #expect(!isAllowed("/Applications/Group/TooDeep/App.app"))
    }

    @Test("Refuses paths redirected through a symlink")
    func refusesSymlinkTargets() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("PurgeHelperPolicy-\(UUID().uuidString)", isDirectory: true)
        let testHome = testRoot.appendingPathComponent("home", isDirectory: true)
        let cacheRoot = testHome.appendingPathComponent("Library/Caches", isDirectory: true)
        let outside = testRoot.appendingPathComponent("outside", isDirectory: true)
        let link = cacheRoot.appendingPathComponent("com.vendor.app")
        defer { try? fileManager.removeItem(at: testRoot) }

        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(!PurgeHelperConstants.isAllowedUninstallLocation(link, homeDirectory: testHome))
    }

    @Test("Helper behavior version is current")
    func helperVersionIsCurrent() {
        #expect(PurgeHelperConstants.version == "2")
    }
}
