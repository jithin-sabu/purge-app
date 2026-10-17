import Foundation
import Testing
@testable import Purge

/// The owner ledger (#224) on a throwaway folder: what the installed-apps scan
/// recorded while an app was installed attributes its human-named folder once
/// the app is gone, and nothing here touches the real ledger.
@Suite("Leftover owner ledger")
struct LeftoverOwnerLedgerTests {
    private static let filler = ["one.two", "three.four", "five.six", "seven.eight", "nine.ten"]

    private func index(apps: [String], names: [String] = []) -> OrphanLeftoverScanPolicy.InstalledAppIndex {
        OrphanLeftoverScanPolicy.InstalledAppIndex(
            diskBundleIDs: Set((apps + Self.filler).map { $0.lowercased() }),
            diskAppNames: Set(names.map { $0.lowercased() }),
            evidence: InstalledCodeEvidence()
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeftoverOwnerLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Model

    @Test
    func recordingTwiceMergesIntoOneEntry() {
        var ledger = LeftoverOwnerLedger()
        ledger.record(bundleID: "com.google.antigravity", displayName: "Antigravity",
                      folders: ["~/Library/Application Support/Antigravity"])
        ledger.record(bundleID: "com.google.antigravity", displayName: "Antigravity",
                      folders: ["~/Library/Application Support/Antigravity", "~/Library/Logs/Antigravity"])
        #expect(ledger.entries.count == 1)
        #expect(ledger.entries.first?.folders == [
            "~/Library/Application Support/Antigravity", "~/Library/Logs/Antigravity"
        ])
    }

    @Test
    func emptyRecordsAreIgnored() {
        var ledger = LeftoverOwnerLedger()
        ledger.record(bundleID: "", displayName: "Nameless", folders: ["~/Library/Application Support/X"])
        ledger.record(bundleID: "com.vendor.App", displayName: "App", folders: [])
        #expect(ledger.entries.isEmpty)
    }

    /// An entry whose folder is gone expires; one whose folder is still there stays.
    @Test
    func pruneDropsFoldersThatAreGone() {
        var ledger = LeftoverOwnerLedger()
        ledger.record(bundleID: "com.gone.App", displayName: "Gone",
                      folders: ["~/Library/Application Support/Gone"])
        ledger.record(bundleID: "com.here.App", displayName: "Here",
                      folders: ["~/Library/Application Support/Here", "~/Library/Logs/Here"])
        ledger.prune { $0 != "~/Library/Application Support/Gone" && $0 != "~/Library/Logs/Here" }
        #expect(ledger.entries.map(\.bundleID) == ["com.here.App"])
        #expect(ledger.entries.first?.folders == ["~/Library/Application Support/Here"])
    }

    @Test
    func relativePathsStayInsideTheHome() {
        let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
        let folder = URL(fileURLWithPath: "/Users/alice/Library/Application Support/Antigravity", isDirectory: true)
        #expect(LeftoverOwnerLedger.relativePath(folder, home: home) == "~/Library/Application Support/Antigravity")
        #expect(LeftoverOwnerLedger.relativePath(URL(fileURLWithPath: "/Users/alice2/Library/X"), home: home) == nil)
        #expect(LeftoverOwnerLedger.relativePath(home, home: home) == nil)
        #expect(LeftoverOwnerLedger.url(forRelativePath: "~/Library/Logs/Here", home: home)?.path == "/Users/alice/Library/Logs/Here")
        #expect(LeftoverOwnerLedger.url(forRelativePath: "/etc", home: home) == nil)
    }

    // MARK: Store

    @Test
    func storeRoundTripsAndPrunesOnRead() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let kept = support.appendingPathComponent("Antigravity", isDirectory: true)
        let gone = support.appendingPathComponent("Vanished", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)

        let store = LeftoverOwnerLedgerStore(fileURL: root.appendingPathComponent("ledger/leftover-owners.json"))
        store.record(bundleID: "com.google.antigravity", displayName: "Antigravity", folders: [kept], home: home)
        store.record(bundleID: "com.vendor.Vanished", displayName: "Vanished", folders: [gone], home: home)
        // A folder outside the home is never recorded.
        store.record(bundleID: "com.vendor.Else", displayName: "Else", folders: [root], home: home)

        let fresh = LeftoverOwnerLedgerStore(fileURL: root.appendingPathComponent("ledger/leftover-owners.json"))
        #expect(fresh.load().entries.map(\.bundleID).sorted() == ["com.google.antigravity", "com.vendor.Vanished"])

        try FileManager.default.removeItem(at: gone)
        let current = fresh.current(home: home)
        #expect(current.entries.map(\.bundleID) == ["com.google.antigravity"])
        #expect(current.owners(ofFolder: "~/Library/Application Support/Antigravity").first?.displayName == "Antigravity")
        // The pruned ledger was written back.
        #expect(fresh.load().entries.count == 1)
    }

    @Test
    func unreadableFileReadsAsEmpty() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("leftover-owners.json")
        try Data("not json".utf8).write(to: file)
        #expect(LeftoverOwnerLedgerStore(fileURL: file).load().entries.isEmpty)
    }

    /// The tests run inside a hosted copy of the app. Its default file must sit in
    /// the run's scratch folder, never in the user's Application Support.
    @Test
    func defaultFileStaysOutOfTheRealApplicationSupportUnderTheTestHost() {
        #expect(TestHost.isActive())
        let url = LeftoverOwnerLedgerStore.defaultFileURL().standardizedFileURL.path
        #expect(url.hasPrefix(TestHost.supportDirectory().standardizedFileURL.path))
        let realSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .standardizedFileURL.path
        #expect(!url.hasPrefix(realSupport))
    }

    // MARK: Attribution

    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    private var folder: URL {
        home.appendingPathComponent("Library/Application Support/Antigravity", isDirectory: true)
    }
    private var recorded: LeftoverOwnerLedger {
        var ledger = LeftoverOwnerLedger()
        ledger.record(bundleID: "com.google.antigravity", displayName: "Antigravity",
                      folders: ["~/Library/Application Support/Antigravity"])
        return ledger
    }

    /// A match recorded while installed attributes the folder after the app is gone.
    @Test
    func recordedFolderIsAttributedOnceTheAppIsGone() {
        let owners = OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: folder, home: home, ledger: recorded, installed: index(apps: ["com.vendor.Other"])
        )
        #expect(owners.map(\.bundleID) == ["com.google.antigravity"])
        #expect(owners.first?.displayName == "Antigravity")
    }

    /// Two gone apps once matched the folder. Both come back as owners, newest
    /// first, so the confirm-time check sees either of them return.
    @Test
    func everyGoneOwnerIsReturned() {
        var ledger = recorded
        ledger.record(bundleID: "com.other.Antigravity", displayName: "Antigravity",
                      folders: ["~/Library/Application Support/Antigravity"],
                      seenAt: Date().addingTimeInterval(60))
        let owners = OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: folder, home: home, ledger: ledger, installed: index(apps: ["com.vendor.Other"])
        )
        #expect(owners.map(\.bundleID) == ["com.other.Antigravity", "com.google.antigravity"])
    }

    /// `Firefox Nightly` keeps `Application Support/Firefox` after Firefox is
    /// removed: an installed app whose name starts with the folder's name owns it.
    /// The ids are made up: `owns` asks Launch Services too, and the CI runner
    /// has the real Firefox installed, so `org.mozilla.firefox` never reads as
    /// gone there.
    @Test
    func installedSiblingAppWithTheFolderNameKeepsIt() {
        let firefox = home.appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
        var ledger = LeftoverOwnerLedger()
        ledger.record(bundleID: "org.example.firefox", displayName: "Firefox",
                      folders: ["~/Library/Application Support/Firefox"])
        #expect(OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: firefox, home: home, ledger: ledger,
            installed: index(apps: ["org.example.nightly"], names: ["Firefox Nightly"])
        ).isEmpty)
        // A name that merely starts with the same letters is not the app.
        #expect(!OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: firefox, home: home, ledger: ledger,
            installed: index(apps: ["com.vendor.Other"], names: ["Firefoxy"])
        ).isEmpty)
    }

    @Test
    func recordedFolderIsKeptWhileTheAppIsInstalled() {
        #expect(OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: folder, home: home, ledger: recorded, installed: index(apps: ["com.google.antigravity"])
        ).isEmpty)
    }

    /// Two apps once matched the folder by name. One is still installed, so the
    /// folder is its, whatever the other's state.
    @Test
    func folderSharedWithAnInstalledOwnerIsKept() {
        var ledger = recorded
        ledger.record(bundleID: "com.other.Antigravity", displayName: "Antigravity",
                      folders: ["~/Library/Application Support/Antigravity"])
        #expect(OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: folder, home: home, ledger: ledger, installed: index(apps: ["com.other.Antigravity"])
        ).isEmpty)
    }

    /// An installed app with the folder's name owns it, even when the ledger
    /// never saw that app match it.
    @Test
    func installedAppWithTheFolderNameKeepsIt() {
        #expect(OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: folder, home: home, ledger: recorded,
            installed: index(apps: ["com.vendor.Other"], names: ["Antigravity"])
        ).isEmpty)
    }

    @Test
    func unrecordedFolderIsNotAttributed() {
        let other = home.appendingPathComponent("Library/Application Support/Docker", isDirectory: true)
        #expect(OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: other, home: home, ledger: recorded, installed: index(apps: [])
        ).isEmpty)
        #expect(OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: folder, home: home, ledger: LeftoverOwnerLedger(), installed: index(apps: [])
        ).isEmpty)
    }

    /// Apple's and Purge's own identifiers never read as orphans, ledger or not.
    @Test
    func protectedOwnersAreNeverOrphans() {
        var ledger = LeftoverOwnerLedger()
        ledger.record(bundleID: "com.apple.Something", displayName: "Something",
                      folders: ["~/Library/Application Support/Antigravity"])
        #expect(OrphanLeftoverScanPolicy.ledgerOwners(
            ofFolderAt: folder, home: home, ledger: ledger, installed: index(apps: [])
        ).isEmpty)
    }

    /// The scan's decision for a human-named folder goes through the ledger and
    /// the age check, with the evidence on the result.
    @Test
    func orphanCandidateUsesTheLedgerForHumanNamedFolders() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root
        let folder = home.appendingPathComponent("Library/Application Support/Antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("state.db")
        try Data("x".utf8).write(to: file)
        let longAgo = Date().addingTimeInterval(-400 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: folder.path)
        let cutoff = OrphanLeftoverScanPolicy.staleCutoff(staleDays: 30)
        let gone = index(apps: ["com.vendor.Other"])

        // No ledger: a human name alone attributes nothing, as before #224.
        #expect(OrphanLeftoverScanPolicy.orphanCandidate(
            at: folder, category: .applicationSupport, installed: gone, cutoff: cutoff, home: home
        ) == nil)

        let found = OrphanLeftoverScanPolicy.orphanCandidate(
            at: folder, category: .applicationSupport, installed: gone, cutoff: cutoff, home: home, ledger: recorded
        )
        #expect(found?.owner == .bundleID("com.google.antigravity"))
        #expect(found?.evidence == .ownerLedger)
        #expect(found?.appName == "Antigravity")
        #expect(found?.ownerBundleIDs == ["com.google.antigravity"])

        // Installed again: kept.
        #expect(OrphanLeftoverScanPolicy.orphanCandidate(
            at: folder, category: .applicationSupport, installed: index(apps: ["com.google.antigravity"]),
            cutoff: cutoff, home: home, ledger: recorded
        ) == nil)

        // Written today: kept.
        try Data("today".utf8).write(to: file)
        #expect(OrphanLeftoverScanPolicy.orphanCandidate(
            at: folder, category: .applicationSupport, installed: gone, cutoff: cutoff, home: home, ledger: recorded
        ) == nil)
    }
}
