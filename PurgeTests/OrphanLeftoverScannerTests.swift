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

    private func scan(home: URL) async -> [String] {
        var paths: [String] = []
        let scanner = OrphanLeftoverScanner(home: home, defaults: settings.defaults, installedApps: { Self.installed })
        for await item in scanner.orphanStream() {
            paths.append(item.path.standardizedFileURL.path)
        }
        return paths
    }

    @Test
    func findsAnOldLeftoverInTheHomeItWasGiven() async throws {
        #expect(Self.installed.looksComplete)
        let (home, leftover) = try homeWithOldLeftover()
        defer { try? FileManager.default.removeItem(at: home) }
        settings.defaults.set(DevToolsStalenessOption.threeMonths.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)

        #expect(await scan(home: home) == [leftover.standardizedFileURL.path])
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
