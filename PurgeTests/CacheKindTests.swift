import AppKit
import Foundation
import Testing
@testable import Purge

/// Main actor, like the service it drives. Swift Testing runs a suite's tests
/// in parallel, and without this the tests wrote the service's row icon cache
/// from several threads at once and crashed the host now and then (#236).
@Suite("Row icons say what a cache is")
@MainActor
struct CacheKindTests {
    private func allDefinitionKeys() throws -> [String] {
        let url = try #require(Bundle.main.url(forResource: "explanations", withExtension: "json"))
        let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        return try #require(entries).compactMap { $0["key"] as? String }
    }

    private func item(definitionKey: String?, folder: String) -> CacheItem {
        let info = SafetyInfo(level: .safe, headline: folder, explanation: "", recoverySteps: "", reinstallCommand: nil)
        let location = CacheLocation(
            path: URL(fileURLWithPath: "/tmp/\(folder)"),
            sizeBytes: 1,
            lastModified: Date(),
            folderName: folder
        )
        return CacheItem(definitionKey: definitionKey, location: location, appName: folder, safetyInfo: info)
    }

    @Test
    func everyDefinitionHasAKnownKind() throws {
        let keys = try allDefinitionKeys()
        #expect(keys.count > 200)
        for key in keys {
            #expect(ExplanationDatabase.kind(forKey: key) != nil, "\(key) has no valid kind")
        }
    }

    @Test
    func aDefinitionWithoutABrandShowsItsKindSymbol() {
        let icon = BrandIconService.shared.rowIcon(forCacheItem: item(definitionKey: "shipit-updater-cache", folder: "shipit-updater-cache"))
        #expect(icon == .symbol(CacheKind.updater.symbolName))
    }

    /// Every slug a definition maps to must be a bundled glyph, or the row
    /// quietly falls back to a symbol.
    @Test
    func everyMappedGlyphIsBundled() throws {
        for key in try allDefinitionKeys() {
            guard let slug = BrandIconMapping.slug(forDefinitionKey: key) else { continue }
            #expect(BrandIconService.shared.brandGlyph(slug: slug) != nil, "\(key) maps to \(slug), which is not bundled")
        }
    }

    /// Mail ships with every Mac, so its row borrows Mail's icon on any machine.
    @Test
    func aDefinitionNamingAnInstalledAppShowsTheAppsIcon() {
        let icon = BrandIconService.shared.rowIcon(forCacheItem: item(definitionKey: "apple-mail", folder: "com.apple.mail"))
        guard case .appIcon = icon else {
            Issue.record("Expected Mail's icon, got \(icon)")
            return
        }
    }

    @Test
    func aServiceRowBorrowsItsAppsIcon() {
        let icon = BrandIconService.shared.rowIcon(forCacheItem: item(definitionKey: "messages-previews", folder: "messages-previews"))
        guard case .appIcon = icon else {
            Issue.record("Expected Messages' icon, got \(icon)")
            return
        }
    }

    /// A cache Purge has no entry for, in a folder named after an installed app,
    /// shows that app's icon rather than the unknown folder. TextEdit ships with
    /// every Mac.
    @Test(arguments: ["com.apple.TextEdit", "TextEdit"])
    func anUnlistedCacheNamedAfterAnInstalledAppShowsItsIcon(folder: String) {
        let icon = BrandIconService.shared.rowIcon(forCacheItem: item(definitionKey: nil, folder: folder))
        guard case .appIcon = icon else {
            Issue.record("Expected TextEdit's icon, got \(icon)")
            return
        }
    }

    @Test
    func aKnownBrandShowsItsGlyph() {
        let icon = BrandIconService.shared.rowIcon(forCacheItem: item(definitionKey: "raycast", folder: "com.raycast.macos"))
        guard case .glyph(let image) = icon else {
            Issue.record("Expected a brand glyph, got \(icon)")
            return
        }
        #expect(image.isTemplate)
    }

    @Test
    func anUnrecognisedFolderIsMarkedUnknown() {
        let icon = BrandIconService.shared.rowIcon(forCacheItem: item(definitionKey: nil, folder: "com.example.not-a-real-helper"))
        #expect(icon == .symbol(BrandIconService.unknownSymbolName))
    }
}
