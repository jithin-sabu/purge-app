import Foundation
import Testing
@testable import Purge

/// Finder's "Uninstall with Purge" and a Dock drop both go through
/// `ExternalUninstallRequest`. These check which selections open the
/// uninstaller and which get turned down, against fake app folders.
@Suite("Uninstall requests from Finder and the Dock")
struct ExternalUninstallRequestTests {

    /// Two fake roots standing in for /Applications and ~/Applications. Only
    /// paths matter here: `readInfo` is faked, so nothing is read from disk.
    private let applications = URL(fileURLWithPath: "/tmp/purge-tests/Applications", isDirectory: true)
    private let homeApplications = URL(fileURLWithPath: "/tmp/purge-tests/home/Applications", isDirectory: true)
    private var roots: [URL] { [applications, homeApplications] }

    private func info(name: String? = nil, bundleID: String? = nil) -> [String: Any] {
        var info: [String: Any] = [:]
        if let name { info["CFBundleName"] = name }
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        return info
    }

    private func resolve(_ urls: [URL], info: [String: Any] = [:]) -> ExternalUninstallRequest.Outcome {
        ExternalUninstallRequest.resolve(
            urls: urls,
            roots: roots,
            purgeBundleIDs: ["io.getpurge.app"],
            readInfo: { _ in info }
        )
    }

    @Test("An app in Applications opens the uninstaller on its bundle path")
    func appInApplications() {
        let app = applications.appendingPathComponent("Rectangle.app")
        let outcome = resolve([app], info: info(name: "Rectangle", bundleID: "com.knollsoft.Rectangle"))
        #expect(outcome == .uninstall(appID: app.standardizedFileURL.path, name: "Rectangle"))
    }

    @Test("Finder's trailing slash does not change the app id")
    func trailingSlashMatchesInstalledAppID() {
        let app = URL(fileURLWithPath: applications.path + "/Rectangle.app/", isDirectory: true)
        let outcome = resolve([app], info: info(name: "Rectangle"))
        #expect(outcome == .uninstall(appID: applications.path + "/Rectangle.app", name: "Rectangle"))
    }

    @Test("One folder down is listed, as the uninstaller walks it")
    func appOneFolderDown() {
        let app = applications.appendingPathComponent("Utilities/Thing.app")
        #expect(resolve([app], info: info(name: "Thing")) == .uninstall(appID: app.path, name: "Thing"))
    }

    @Test("The home Applications folder counts too")
    func appInHomeApplications() {
        let app = homeApplications.appendingPathComponent("Thing.app")
        #expect(resolve([app], info: info(name: "Thing")) == .uninstall(appID: app.path, name: "Thing"))
    }

    @Test("Two folders down is outside what the uninstaller lists")
    func appTwoFoldersDown() {
        let app = applications.appendingPathComponent("A/B/Thing.app")
        #expect(resolve([app], info: info(name: "Thing")) == .outsideApplications(name: "Thing"))
    }

    @Test("An app on the Desktop is turned down by name")
    func appOutsideApplications() {
        let app = URL(fileURLWithPath: "/tmp/purge-tests/Desktop/Thing.app")
        #expect(resolve([app], info: info(name: "Thing")) == .outsideApplications(name: "Thing"))
    }

    @Test("The name falls back to the bundle's file name without an Info.plist")
    func nameFallsBackToFileName() {
        let app = URL(fileURLWithPath: "/tmp/purge-tests/Desktop/Thing.app")
        #expect(resolve([app]) == .outsideApplications(name: "Thing"))
    }

    @Test("The display name wins over the bundle name")
    func displayNameWins() {
        let app = applications.appendingPathComponent("Thing.app")
        var info = info(name: "Thing")
        info["CFBundleDisplayName"] = "Thing Pro"
        #expect(resolve([app], info: info) == .uninstall(appID: app.path, name: "Thing Pro"))
    }

    @Test("Apple's apps under /System are never offered")
    func appleAppIsProtected() {
        let app = URL(fileURLWithPath: "/System/Applications/Safari.app")
        #expect(resolve([app], info: info(name: "Safari", bundleID: "com.apple.Safari")) == .appleApp(name: "Safari"))
    }

    @Test("A symlink from Applications into /System is still Apple's app")
    func symlinkedAppleAppIsProtected() throws {
        // Like /Applications/Safari.app, which points into the system cryptex.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-tests-symlink-\(UUID().uuidString)", isDirectory: true)
        let root = folder.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = root.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications/Safari.app")
        )

        let outcome = ExternalUninstallRequest.resolve(
            urls: [link],
            roots: [root],
            purgeBundleIDs: [],
            readInfo: { _ in info(name: "Safari", bundleID: "com.apple.Safari") }
        )
        #expect(outcome == .appleApp(name: "Safari"))
    }

    @Test("Purge turns itself down even from inside Applications")
    func purgeItself() {
        let app = applications.appendingPathComponent("Purge.app")
        #expect(resolve([app], info: info(name: "Purge", bundleID: "io.getpurge.app")) == .purgeItself)
    }

    @Test("A selection with no app bundle is turned down")
    func noApp() {
        let file = applications.appendingPathComponent("notes.txt")
        #expect(resolve([file]) == .noApp)
        #expect(resolve([]) == .noApp)
    }

    @Test("A stray file next to the app is ignored")
    func strayFileIsIgnored() {
        let app = applications.appendingPathComponent("Thing.app")
        let file = applications.appendingPathComponent("notes.txt")
        #expect(resolve([file, app], info: info(name: "Thing")) == .uninstall(appID: app.path, name: "Thing"))
    }

    @Test("Several apps are turned down with the count")
    func severalApps() {
        let apps = ["A", "B", "C"].map { applications.appendingPathComponent("\($0).app") }
        #expect(resolve(apps) == .severalApps(count: 3))
    }

    @Test("Every refusal has an alert; the uninstall outcome has none")
    func refusals() {
        let outcomes: [ExternalUninstallRequest.Outcome] = [
            .noApp, .severalApps(count: 2), .outsideApplications(name: "X"), .appleApp(name: "X"), .purgeItself,
        ]
        for outcome in outcomes {
            #expect(outcome.refusal != nil)
            #expect(outcome.refusal?.title.isEmpty == false)
            #expect(outcome.refusal?.detail.isEmpty == false)
        }
        #expect(ExternalUninstallRequest.Outcome.uninstall(appID: "/a", name: "A").refusal == nil)
    }

    @Test("The Services menu is refreshed once per build")
    func servicesRefreshOncePerBuild() {
        #expect(ServicesMenuRegistration.shouldRefresh(recorded: nil, current: "1.8.3 (31)"))
        #expect(ServicesMenuRegistration.shouldRefresh(recorded: "1.8.2 (30)", current: "1.8.3 (31)"))
        #expect(!ServicesMenuRegistration.shouldRefresh(recorded: "1.8.3 (31)", current: "1.8.3 (31)"))
    }
}
