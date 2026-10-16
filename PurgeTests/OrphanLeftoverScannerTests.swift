import Foundation
import Testing
@testable import Purge

/// Runs the orphan scan on a temporary home with throwaway settings, so it never
/// reads the user's Library or their Dev Tools staleness setting (#171). Which
/// apps are installed still comes from this Mac's app folders, read only.
@Suite("Orphan leftover scanning")
struct OrphanLeftoverScannerTests {
    private let settings = ThrowawayDefaults()

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

    private func scan(home: URL) async -> [String] {
        var paths: [String] = []
        for await item in OrphanLeftoverScanner(home: home, defaults: settings.defaults).orphanStream() {
            paths.append(item.path.standardizedFileURL.path)
        }
        return paths
    }

    @Test
    func findsAnOldLeftoverInTheHomeItWasGiven() async throws {
        // With too few apps installed the scan refuses to run at all.
        try #require(OrphanLeftoverScanPolicy.makeInstalledAppIndex().looksComplete)
        let (home, leftover) = try homeWithOldLeftover()
        defer { try? FileManager.default.removeItem(at: home) }
        settings.defaults.set(DevToolsStalenessOption.threeMonths.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)

        #expect(await scan(home: home) == [leftover.standardizedFileURL.path])
    }

    /// Two years is longer than the leftover has sat untouched, so the scan keeps it.
    @Test
    func readsTheStalenessSettingFromTheDefaultsItWasGiven() async throws {
        try #require(OrphanLeftoverScanPolicy.makeInstalledAppIndex().looksComplete)
        let (home, _) = try homeWithOldLeftover()
        defer { try? FileManager.default.removeItem(at: home) }
        settings.defaults.set(DevToolsStalenessOption.twoYears.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)

        #expect(await scan(home: home).isEmpty)
    }
}
