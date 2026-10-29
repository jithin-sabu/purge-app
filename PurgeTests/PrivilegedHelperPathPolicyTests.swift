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
        #expect(isAllowed("/Applications/Autodesk/AutoCAD 2026/AutoCAD 2026.app"))
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
        #expect(isAllowed("/Applications/Group/Product/Deeper/App.app"))
        #expect(!isAllowed("/Applications/Host.app/Contents/Inner.app"))
        #expect(!isAllowed("/Applications/Vendor/Host.app/Inner.app"))
        #expect(!isAllowed("/Applications/Vendor/Pane.prefPane/Contents/Inner.app"))
        #expect(!isAllowed("/Applications/.Hidden/Inner.app"))
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
        #expect(PurgeHelperConstants.version == "6")
    }

    private func isAllowedMove(_ path: String, ruleHolds: Bool) -> Bool {
        PurgeHelperConstants.isAllowedMoveSource(
            URL(fileURLWithPath: path),
            homeDirectory: home,
            installLeftoverRuleHolds: ruleHolds
        )
    }

    @Test("Moves macOS install leftovers only while the date rule holds")
    func installLeftoversNeedTheRule() {
        let root = MacOSInstallLeftovers.root.path
        #expect(isAllowedMove("\(root)/UpdateBundle", ruleHolds: true))
        #expect(!isAllowedMove("\(root)/UpdateBundle", ruleHolds: false))
        #expect(!isAllowedMove(root, ruleHolds: true))
        #expect(!isAllowedMove("\(root)/Locked Files", ruleHolds: true))
        #expect(!isAllowedMove("\(root)/UpdateBundle/Payload", ruleHolds: true))
        #expect(!isAllowedMove("\(root)/.hidden", ruleHolds: true))
        #expect(!isAllowedMove("/macOS Install Data/UpdateBundle", ruleHolds: true))
        // The rule never widens the uninstall reach, and never narrows it.
        #expect(!isAllowedMove("/Library/Keychains/System.keychain", ruleHolds: true))
        #expect(isAllowedMove("/Applications/Teams.app", ruleHolds: false))
    }

    @Test("Refuses a macOS install leftover reached through a symlink")
    func refusesSymlinkedInstallLeftover() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("PurgeHelperLeftover-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let root = folder.appendingPathComponent("macOS Install Data", isDirectory: true)
        let outside = folder.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Linked")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)

        // Only the refusal can be checked here: Foundation drops /private from a
        // temporary path when it resolves links, so no temporary path passes. The
        // live folder has no links on the way, and the test above covers it.
        #expect(!PurgeHelperConstants.isAllowedInstallLeftoverLocation(link, root: root))
    }

    /// If the helper and the picker disagree, an app the picker lists is refused
    /// at the root move, or the helper accepts more than the app offers.
    @Test("Helper app reach matches the uninstaller's")
    func helperReachMatchesUninstaller() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let roots = ["/Applications", "/Users/example/Applications"]
        for path in [
            "/Applications/A.app",
            "/Applications/V/A.app",
            "/Applications/V/P/A.app",
            "/Applications/V/P/Q/A.app",
            "/Applications/V/P/Q/R/S/A.app",
            "/Applications/V/Kit.framework/A.app",
            "/Applications/V/Pane.prefPane/Contents/A.app",
            "/Applications/.Hidden/A.app",
            "/Applications/Host.app/Contents/A.app",
            "/Users/example/Applications/V/P/A.app",
            "/Users/example/Applications/V/P/Q/A.app",
        ] {
            let helper = PurgeHelperConstants.isAllowedUninstallLocation(
                URL(fileURLWithPath: path, isDirectory: true),
                homeDirectory: home
            )
            let app = AppBundleReach.folderDepth(ofAppAtPath: path, roots: roots) != nil
            #expect(helper == app, "\(path)")
        }
    }

    /// The helper keeps its own copy of the leftover folders, since it does not
    /// compile the uninstaller. A folder only the uninstaller has is refused at the
    /// root move; one only the helper has lets root move more than the app offers.
    @Test("Helper leftover folders match the uninstaller's")
    func helperLeftoverRootsMatchUninstaller() {
        let helper = PurgeHelperConstants.leftoverRoots(homeDirectory: home).map(\.standardizedFileURL.path)
        let app = AppUninstallScanPolicy.leftoverSearchRoots(home: home).map(\.url.standardizedFileURL.path)
        #expect(Set(helper) == Set(app))
        #expect(helper.count == Set(helper).count)

        // And through the check the helper runs: one entry directly inside each.
        for root in app {
            let entry = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("com.vendor.leftover")
            #expect(isAllowed(entry.path), "\(root)")
        }
    }
}

/// A leftover keyed by bundle id belongs to every installed app that carries that
/// id. When two copies share one (Xcode and Xcode-beta are both
/// `com.apple.dt.Xcode`), removing one copy must not strip files the other reads.
/// These pin the matching primitive the shared-leftover guard relies on.
@Suite("Shared leftover detection")
struct SharedLeftoverDetectionTests {
    private func app(_ name: String, bundleID: String?, path: String) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: path),
            bundleID: bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )
    }

    @Test("A second copy with the same bundle id claims the same leftover")
    func secondCopyClaimsLeftover() {
        let beta = app("Xcode-beta", bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode-beta.app")
        // A preferences file keyed by the shared bundle id matches the other copy too.
        #expect(
            AppUninstallScanPolicy.matchReason(
                forLeftoverName: "com.apple.dt.Xcode.plist",
                category: .preferences,
                app: beta
            ) != nil
        )
    }

    @Test("An unrelated app does not claim the leftover")
    func unrelatedAppDoesNotClaim() {
        let other = app("Rectangle", bundleID: "com.knollsoft.Rectangle", path: "/Applications/Rectangle.app")
        #expect(
            AppUninstallScanPolicy.matchReason(
                forLeftoverName: "com.apple.dt.Xcode.plist",
                category: .preferences,
                app: other
            ) == nil
        )
    }
}

@Suite("Kept-for-other-app is informational")
struct KeptForOtherAppReasonTests {
    @Test("Offers neither retry nor settings")
    func nonActionable() {
        #expect(CleanFailureReason.keptForOtherApp.showsRetry == false)
        #expect(CleanFailureReason.keptForOtherApp.showsOpenSettings == false)
    }
}
