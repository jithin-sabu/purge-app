import Foundation
import Testing
@testable import Purge

/// Runs the orphan scan on a temporary home with throwaway settings and a fixed
/// list of installed apps, so it never reads the user's Library, their Dev Tools
/// staleness setting, or this Mac's app folders (#171).
@Suite("Orphan leftover scanning")
struct OrphanLeftoverScannerTests {
    private let settings = ThrowawayDefaults()

    /// Enough apps for the scan to trust the list, none of them the leftover's owner.
    /// Walking the real app folders takes seconds per call and blocks a thread,
    /// which stalled every other test on CI's smaller runners.
    private static let installed = OrphanLeftoverScanPolicy.InstalledAppIndex(
        diskBundleIDs: ["com.vendor.one", "com.vendor.two", "org.example.three", "net.example.four", "io.example.five"],
        evidence: InstalledCodeEvidence()
    )

    /// A home holding one Application Support folder no installed app claims,
    /// with nothing inside changed for 200 days.
    private func homeWithOldLeftover() throws -> (home: URL, leftover: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("purgetest-\(UUID().uuidString)", isDirectory: true)
        let leftover = home.appendingPathComponent(
            "Library/Application Support/com.purgetest.\(UUID().uuidString.prefix(8).lowercased())",
            isDirectory: true
        )
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        let file = leftover.appendingPathComponent("data.db")
        try Data([0x00]).write(to: file)
        let longAgo = Date().addingTimeInterval(-200 * 86_400)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: file.path)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: leftover.path)
        return (home, leftover)
    }

    private func scan(home: URL, ledger: LeftoverOwnerLedger = LeftoverOwnerLedger()) async -> [String] {
        await scanItems(home: home, ledger: ledger).map { $0.path.standardizedFileURL.path }
    }

    private func scanItems(
        home: URL,
        ledger: LeftoverOwnerLedger = LeftoverOwnerLedger(),
        catalog: AppDotFolderCatalog = .empty
    ) async -> [UninstallItem] {
        var items: [UninstallItem] = []
        let scanner = OrphanLeftoverScanner(
            home: home,
            defaults: settings.defaults,
            installedApps: { Self.installed },
            ledger: { _ in ledger },
            catalog: catalog
        )
        for await item in scanner.orphanStream() {
            items.append(item)
        }
        return items
    }

    /// A human-named Application Support folder, untouched for 200 days.
    private func addHumanNamedLeftover(named name: String, to home: URL) throws -> URL {
        let fm = FileManager.default
        let folder = home.appendingPathComponent("Library/Application Support/\(name)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("state.db")
        try Data([0x01]).write(to: file)
        let longAgo = Date().addingTimeInterval(-200 * 86_400)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: file.path)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: folder.path)
        return folder
    }

    @Test
    func findsAnOldLeftoverInTheHomeItWasGiven() async throws {
        #expect(Self.installed.looksComplete)
        let (home, leftover) = try homeWithOldLeftover()
        defer { try? FileManager.default.removeItem(at: home) }
        settings.defaults.set(DevToolsStalenessOption.threeMonths.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)

        #expect(await scan(home: home) == [leftover.standardizedFileURL.path])
    }

    /// The ledger saw Antigravity match its folder while installed (#224). With
    /// the app gone the folder is offered, with the ledger as its evidence and the
    /// app's id on it for the confirm-time check. Without the ledger a human name
    /// attributes nothing.
    @Test
    func humanNamedFolderIsOfferedOnlyWithTheLedger() async throws {
        let (home, bundleIDLeftover) = try homeWithOldLeftover()
        defer { try? FileManager.default.removeItem(at: home) }
        settings.defaults.set(DevToolsStalenessOption.threeMonths.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)
        let folder = try addHumanNamedLeftover(named: "Antigravity", to: home)

        #expect(await scan(home: home) == [bundleIDLeftover.standardizedFileURL.path])

        var ledger = LeftoverOwnerLedger()
        ledger.record(bundleID: "com.google.antigravity", displayName: "Antigravity",
                      folders: ["~/Library/Application Support/Antigravity"])
        let items = await scanItems(home: home, ledger: ledger)
        let found = items.first { $0.path.standardizedFileURL.path == folder.standardizedFileURL.path }
        #expect(found?.matchReason == .ownerLedger)
        #expect(found?.ownerBundleID == "com.google.antigravity")
        #expect(found?.safetyInfo.headline == "Antigravity")
        #expect(found?.safetyInfo.level == .medium)
        #expect(found?.isSelected == false)
        #expect(items.count == 2)
    }

    /// `Application Support/Antigravity` with `Preferences/com.google.antigravity.plist`
    /// and the app gone is offered on the plist's evidence (#224). The plist
    /// itself is not offered: Preferences is left out of the scan by design.
    @Test
    func humanNamedFolderIsOfferedOnAPreferencesIdentifier() async throws {
        let (home, bundleIDLeftover) = try homeWithOldLeftover()
        defer { try? FileManager.default.removeItem(at: home) }
        settings.defaults.set(DevToolsStalenessOption.threeMonths.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)
        let folder = try addHumanNamedLeftover(named: "Antigravity", to: home)
        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try Data().write(to: preferences.appendingPathComponent("com.google.antigravity.plist"))

        let items = await scanItems(home: home)
        #expect(items.map { $0.path.standardizedFileURL.path }.sorted()
            == [bundleIDLeftover.standardizedFileURL.path, folder.standardizedFileURL.path].sorted())
        let found = items.first { $0.path.standardizedFileURL.path == folder.standardizedFileURL.path }
        #expect(found?.matchReason == .libraryCrossEvidence)
        #expect(found?.ownerBundleID == "com.google.antigravity")
        #expect(found?.safetyInfo.headline == "Antigravity")
        #expect(found?.safetyInfo.level == .medium)
    }

    /// A catalog dot folder of a removed app is offered as home folder data, with
    /// the catalog as its evidence. Its shared parent is not (#224).
    @Test
    func catalogDotFolderIsOfferedAsHomeFolderData() async throws {
        let (home, bundleIDLeftover) = try homeWithOldLeftover()
        defer { try? FileManager.default.removeItem(at: home) }
        settings.defaults.set(DevToolsStalenessOption.threeMonths.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)
        let fm = FileManager.default
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        let antigravity = gemini.appendingPathComponent("antigravity", isDirectory: true)
        try fm.createDirectory(at: antigravity, withIntermediateDirectories: true)
        let file = antigravity.appendingPathComponent("brain.db")
        try Data([0x02]).write(to: file)
        let longAgo = Date().addingTimeInterval(-200 * 86_400)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: file.path)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: antigravity.path)
        try Data("cli".utf8).write(to: gemini.appendingPathComponent("settings.json"))
        let catalog = try AppDotFolderCatalog.parse(Data("""
        {"apps": [{"bundle_id": "com.google.antigravity", "display_name": "Antigravity",
                   "folders": ["~/.gemini/antigravity", "~/.antigravity"]}]}
        """.utf8))

        #expect(await scan(home: home) == [bundleIDLeftover.standardizedFileURL.path])

        let items = await scanItems(home: home, catalog: catalog)
        #expect(items.map { $0.path.standardizedFileURL.path }.sorted()
            == [bundleIDLeftover.standardizedFileURL.path, antigravity.standardizedFileURL.path].sorted())
        let found = items.first { $0.path.standardizedFileURL.path == antigravity.standardizedFileURL.path }
        #expect(found?.category == .homeFolderData)
        #expect(found?.matchReason == .dotFolderCatalog)
        #expect(found?.ownerBundleID == "com.google.antigravity")
        #expect(found?.safetyInfo.headline == "Antigravity")
        #expect(found?.safetyInfo.level == .medium)
        #expect(found?.isSelected == false)
    }

    /// Two years is longer than the leftover has sat untouched, so the scan keeps it.
    @Test
    func readsTheStalenessSettingFromTheDefaultsItWasGiven() async throws {
        let (home, _) = try homeWithOldLeftover()
        defer { try? FileManager.default.removeItem(at: home) }
        settings.defaults.set(DevToolsStalenessOption.twoYears.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)

        #expect(await scan(home: home).isEmpty)
    }
}
