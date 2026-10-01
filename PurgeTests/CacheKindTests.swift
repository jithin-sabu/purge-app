import AppKit
import Foundation
import Testing
@testable import Purge

@Suite("Row icons say what a cache is")
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
        let icon = BrandIconService.shared.rowIcon(forCacheItem: item(definitionKey: "claude-updater", folder: "claude-updater"))
        #expect(icon == .symbol(CacheKind.updater.symbolName))
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
