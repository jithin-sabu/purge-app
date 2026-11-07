import Foundation
import Testing
@testable import Purge

/// The gate for Uninstall Purge (#330): the one place Purge moves its own files.
/// Only this copy of Purge, as a real writable bundle, and only Purge's own data
/// folders by exact path.
@Suite("Uninstall Purge gate")
struct SelfUninstallPolicyTests {
    private static let id = "io.getpurge.app"

    private static func facts(
        path: String = "/Applications/Purge.app",
        exists: Bool = true,
        isDirectory: Bool = true,
        isSymbolicLink: Bool = false,
        bundleIdentifier: String? = id,
        matchesRunningSignature: Bool = true,
        isOnReadOnlyVolume: Bool = false
    ) -> SelfUninstallPolicy.BundleFacts {
        .init(
            path: path,
            exists: exists,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            bundleIdentifier: bundleIdentifier,
            matchesRunningSignature: matchesRunningSignature,
            isOnReadOnlyVolume: isOnReadOnlyVolume
        )
    }

    private static func evaluate(_ facts: SelfUninstallPolicy.BundleFacts, running: String = id) -> SelfUninstallPolicy.Refusal? {
        SelfUninstallPolicy.evaluateApp(facts, runningBundleIdentifier: running)
    }

    // MARK: The app

    @Test func thisAppInApplicationsMayMove() {
        #expect(Self.evaluate(Self.facts()) == nil)
        #expect(Self.evaluate(Self.facts(path: "/Users/me/Applications/Purge.app")) == nil)
        #expect(Self.evaluate(Self.facts(path: "/Volumes/Work/Apps/Purge.app")) == nil)
    }

    @Test func missingBundleIsRefused() {
        #expect(Self.evaluate(Self.facts(exists: false)) == .missing)
    }

    @Test func somethingThatIsNotAnAppFolderIsRefused() {
        #expect(Self.evaluate(Self.facts(path: "/Applications/Purge")) == .notAnApp)
        #expect(Self.evaluate(Self.facts(isDirectory: false)) == .notAnApp)
        #expect(Self.evaluate(Self.facts(isSymbolicLink: true)) == .notAnApp)
    }

    @Test func anotherAppOrAnotherSignatureIsRefused() {
        #expect(Self.evaluate(Self.facts(bundleIdentifier: "com.example.other")) == .notThisApp)
        #expect(Self.evaluate(Self.facts(bundleIdentifier: nil)) == .notThisApp)
        #expect(Self.evaluate(Self.facts(matchesRunningSignature: false)) == .notThisApp)
        // A running copy without a bundle ID matches nothing.
        #expect(Self.evaluate(Self.facts(bundleIdentifier: ""), running: "") == .notThisApp)
    }

    @Test func translocatedCopyIsRefused() {
        let path = "/private/var/folders/x1/abc/T/AppTranslocation/6F1A-2B/d/Purge.app"
        #expect(Self.evaluate(Self.facts(path: path, isOnReadOnlyVolume: true)) == .translocated)
        #expect(SelfUninstallPolicy.isTranslocated(path: path))
        #expect(!SelfUninstallPolicy.isTranslocated(path: "/Applications/Purge.app"))
    }

    @Test func diskImageIsRefused() {
        #expect(Self.evaluate(Self.facts(path: "/Volumes/Purge/Purge.app", isOnReadOnlyVolume: true)) == .readOnlyVolume)
    }

    @Test func copyAlreadyInATrashIsReportedAsSuch() {
        #expect(Self.evaluate(Self.facts(path: "/Users/me/.Trash/Purge.app")) == .alreadyInTrash)
        #expect(Self.evaluate(Self.facts(path: "/Volumes/Work/.Trashes/501/Purge.app")) == .alreadyInTrash)
        #expect(Self.evaluate(Self.facts(path: "/Users/me/Library/Mobile Documents/.Trash/Purge.app")) == .alreadyInTrash)
        // A folder merely named like one is not a Trash.
        #expect(Self.evaluate(Self.facts(path: "/Applications/Trash Tools/Purge.app")) == nil)
    }

    @Test func refusalsComeInOrderSoTheMostUsefulReasonShows() {
        // Translocated and read-only: the translocation is the reason to show,
        // since moving the real copy is what the user can do.
        let translocated = Self.facts(
            path: "/private/var/folders/x/T/AppTranslocation/1/d/Purge.app",
            matchesRunningSignature: false,
            isOnReadOnlyVolume: true
        )
        #expect(Self.evaluate(translocated) == .translocated)
        // Another app on a disk image: not this app.
        #expect(Self.evaluate(Self.facts(bundleIdentifier: "com.example.other", isOnReadOnlyVolume: true)) == .notThisApp)
    }

    // MARK: Reading from disk

    @Test func readFactsRefusesAFolderWithoutBundleIdentity() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-self-uninstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Purge.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let facts = SelfUninstallPolicy.readFacts(of: app)
        #expect(facts.exists)
        #expect(facts.isDirectory)
        #expect(!facts.isSymbolicLink)
        #expect(facts.bundleIdentifier == nil)
        #expect(!facts.matchesRunningSignature)
        #expect(Self.evaluate(facts) == .notThisApp)
    }

    @Test func readFactsSeesALinkAsALink() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-self-uninstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("Real.app", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("Purge.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let facts = SelfUninstallPolicy.readFacts(of: link)
        #expect(facts.isSymbolicLink)
        #expect(Self.evaluate(facts) == .notAnApp)
    }

    @Test func readFactsReportsAMissingBundle() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-self-uninstall-\(UUID().uuidString)/Purge.app")
        #expect(Self.evaluate(SelfUninstallPolicy.readFacts(of: missing)) == .missing)
    }

    // MARK: Data folders

    private static let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    @Test func onlyPurgesOwnDataFoldersAreAccepted() {
        let folders = SelfUninstallPolicy.dataFolders(home: Self.home, bundleIdentifier: Self.id).map(\.path)
        #expect(folders == [
            "/Users/me/Library/Application Support/io.getpurge.app",
            "/Users/me/Library/Caches/io.getpurge.app",
            "/Users/me/Library/HTTPStorages/io.getpurge.app"
        ])
        for path in folders {
            #expect(SelfUninstallPolicy.isOwnDataFolder(URL(fileURLWithPath: path), home: Self.home, bundleIdentifier: Self.id))
        }
    }

    @Test func foldersInsideBesideOrAboveAreRefused() {
        let refused = [
            "/Users/me/Library/Application Support",
            "/Users/me/Library/Application Support/io.getpurge.app/ledger",
            "/Users/me/Library/Application Support/io.getpurge.app.other",
            "/Users/me/Library/Caches",
            "/Users/me/Library/Caches/com.example.other",
            "/Users/me/Library",
            "/Users/me",
            "/Users/other/Library/Caches/io.getpurge.app",
            "/Users/me/Library/Caches/io.getpurge.app/../com.apple.Safari"
        ]
        for path in refused {
            #expect(!SelfUninstallPolicy.isOwnDataFolder(URL(fileURLWithPath: path), home: Self.home, bundleIdentifier: Self.id), "\(path)")
        }
    }

    @Test func aBundleIdentifierThatCouldReachElsewhereIsRefused() {
        let caches = URL(fileURLWithPath: "/Users/me/Library/Caches", isDirectory: true)
        #expect(!SelfUninstallPolicy.isOwnDataFolder(caches, home: Self.home, bundleIdentifier: ""))
        let sneaky = URL(fileURLWithPath: "/Users/me/Library/Caches/x/../../Preferences")
        #expect(!SelfUninstallPolicy.isOwnDataFolder(sneaky, home: Self.home, bundleIdentifier: "x/../../Preferences"))
    }

    @Test func onlyReverseDNSBundleIdentifiersAreAccepted() {
        for good in ["io.getpurge.app", "io.getpurge.app.e2e190", "com.example-1.a"] {
            #expect(SelfUninstallPolicy.isValidBundleIdentifier(good), "\(good)")
        }
        for bad in ["", ".", "..", "io", "io..app", ".io.app", "io.app.", "io/app.x", "io.app/..", "io.ap p", "io.äpp"] {
            #expect(!SelfUninstallPolicy.isValidBundleIdentifier(bad), "\(bad)")
        }
    }

    /// `Caches/.` is the Caches folder itself and `Caches/..` is Library.
    @Test func dotIdentifiersNeverNameAFolder() {
        for id in [".", ".."] {
            #expect(SelfUninstallPolicy.dataFolders(home: Self.home, bundleIdentifier: id).isEmpty)
            #expect(!SelfUninstallPolicy.isOwnDataFolder(URL(fileURLWithPath: "/Users/me/Library/Caches"), home: Self.home, bundleIdentifier: id))
            #expect(!SelfUninstallPolicy.isOwnDataFolder(URL(fileURLWithPath: "/Users/me/Library"), home: Self.home, bundleIdentifier: id))
        }
    }

    @Test func aDevBuildLeavesTheSharedApplicationSupportFolderAlone() {
        let dev = "io.getpurge.app.shots"
        let folders = SelfUninstallPolicy.dataFolders(home: Self.home, bundleIdentifier: dev).map(\.path)
        #expect(folders == [
            "/Users/me/Library/Caches/io.getpurge.app.shots",
            "/Users/me/Library/HTTPStorages/io.getpurge.app.shots"
        ])
        let shared = URL(fileURLWithPath: "/Users/me/Library/Application Support/io.getpurge.app")
        #expect(!SelfUninstallPolicy.isOwnDataFolder(shared, home: Self.home, bundleIdentifier: dev))
    }

    @Test func preferencesFileIsNamedForTheBundle() {
        #expect(SelfUninstallPolicy.preferencesFile(home: Self.home, bundleIdentifier: Self.id).path
            == "/Users/me/Library/Preferences/io.getpurge.app.plist")
    }

    // MARK: Other copies

    @Test func otherCopiesLeaveOutThisOneTheTrashAndMissingOnes() {
        let running = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData/purge-x/Build/Products/Debug/Purge.app")
        let known = [
            running,
            URL(fileURLWithPath: "/Applications/Purge.app"),
            URL(fileURLWithPath: "/Applications/Purge.app/"),
            URL(fileURLWithPath: "/Users/me/.Trash/Purge.app"),
            URL(fileURLWithPath: "/Users/me/Downloads/Purge.app")
        ]
        let found = SelfUninstallPolicy.otherCopies(among: known, running: running) { $0.path != "/Users/me/Downloads/Purge.app" }
        #expect(found.map(\.path) == ["/Applications/Purge.app"])
        #expect(SelfUninstallPolicy.otherCopies(among: [running], running: running) { _ in true }.isEmpty)
    }

    // MARK: All or nothing

    private final class FakeBin {
        var trashed: [URL] = []
        var putBack: [URL] = []
        var failTrashing: Set<String> = []
        var failPutBack = false

        func trash(_ url: URL) throws -> URL? {
            if failTrashing.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
            trashed.append(url)
            return URL(fileURLWithPath: "/Trash").appendingPathComponent(url.lastPathComponent)
        }

        func copy(_ url: URL) throws -> URL {
            URL(fileURLWithPath: "/staging").appendingPathComponent(url.lastPathComponent)
        }

        func putBack(_ trashed: URL, _ original: URL) throws {
            if failPutBack { throw CocoaError(.fileWriteNoPermission) }
            putBack.append(original)
        }
    }

    private static func run(_ bin: FakeBin, _ items: [SelfUninstallPolicy.DataItem]) -> SelfUninstallDataMove {
        SelfUninstallPolicy.moveAllOrNothing(items, trash: bin.trash, copy: bin.copy, putBack: bin.putBack)
    }

    private static let support = URL(fileURLWithPath: "/Users/me/Library/Application Support/io.getpurge.app")
    private static let caches = URL(fileURLWithPath: "/Users/me/Library/Caches/io.getpurge.app.c")
    private static let prefs = URL(fileURLWithPath: "/Users/me/Library/Preferences/io.getpurge.app.plist")

    @Test func everythingMovesWhenNothingFails() {
        let bin = FakeBin()
        #expect(Self.run(bin, [.folder(Self.support), .folder(Self.caches), .copyOf(Self.prefs)]) == .moved)
        #expect(bin.trashed.map(\.lastPathComponent) == ["io.getpurge.app", "io.getpurge.app.c", "io.getpurge.app.plist"])
        // The preferences went as a copy; the original was never trashed.
        #expect(!bin.trashed.contains(Self.prefs))
        #expect(bin.putBack.isEmpty)
    }

    @Test func aLaterFailurePutsBackWhatAlreadyMoved() {
        let bin = FakeBin()
        bin.failTrashing = ["io.getpurge.app.c"]
        #expect(Self.run(bin, [.folder(Self.support), .folder(Self.caches), .copyOf(Self.prefs)]) == .failed)
        #expect(bin.putBack == [Self.support])
    }

    @Test func aFailedCopyPutsTheFoldersBack() {
        let bin = FakeBin()
        bin.failTrashing = ["io.getpurge.app.plist"]
        #expect(Self.run(bin, [.folder(Self.support), .folder(Self.caches), .copyOf(Self.prefs)]) == .failed)
        #expect(bin.putBack == [Self.caches, Self.support])
    }

    @Test func whatCannotBePutBackIsReportedAsSplit() {
        let bin = FakeBin()
        bin.failTrashing = ["io.getpurge.app.c"]
        bin.failPutBack = true
        #expect(Self.run(bin, [.folder(Self.support), .folder(Self.caches)]) == .failedPartly)
    }

    @Test func aFirstFailureMovesNothing() {
        let bin = FakeBin()
        bin.failTrashing = ["io.getpurge.app"]
        #expect(Self.run(bin, [.folder(Self.support), .folder(Self.caches)]) == .failed)
        #expect(bin.trashed.isEmpty)
        #expect(bin.putBack.isEmpty)
    }

    // MARK: Uninstaller search

    @Test func searchingForPurgeInTheUninstallerIsRecognised() {
        #expect(UninstallView.searchesForPurge("purge"))
        #expect(UninstallView.searchesForPurge("Pur"))
        #expect(UninstallView.searchesForPurge("  PU "))
        #expect(!UninstallView.searchesForPurge("p"))
        #expect(!UninstallView.searchesForPurge("purges"))
        #expect(!UninstallView.searchesForPurge("slack"))
        #expect(!UninstallView.searchesForPurge(""))
    }
}
