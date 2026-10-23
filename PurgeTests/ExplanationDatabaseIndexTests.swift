import Foundation
import Testing
@testable import Purge

/// The lookup tables are built once and read by key (#190). These check that they
/// answer exactly as the old linear search over `explanations.json` did, since the
/// answer picks each row's safety level.
@Suite("Explanation database index")
struct ExplanationDatabaseIndexTests {
    private struct Entry {
        let key: String
        let aliases: [String]
        let bundleIDs: [String]
    }

    private static func entries() throws -> [Entry] {
        let url = try #require(Bundle.main.url(forResource: "explanations", withExtension: "json"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return json.map {
            Entry(
                key: $0["key"] as! String,
                aliases: $0["aliases"] as? [String] ?? [],
                bundleIDs: $0["bundle_ids"] as? [String] ?? []
            )
        }
    }

    /// The old search: a case-insensitive key, then an alias (a later entry wins a
    /// shared alias), then a bundle ID.
    private static func referenceKey(for name: String, in entries: [Entry]) -> String? {
        let lower = name.lowercased()
        if let entry = entries.first(where: { $0.key.lowercased() == lower }) { return entry.key }
        if let entry = entries.last(where: { $0.aliases.contains { $0.lowercased() == lower } }) { return entry.key }
        if let entry = entries.first(where: { $0.bundleIDs.contains { $0.lowercased() == lower } }) { return entry.key }
        return nil
    }

    @Test func everyNameResolvesAsTheLinearSearchDid() throws {
        let entries = try Self.entries()
        var names: [String] = []
        for entry in entries {
            for name in [entry.key] + entry.aliases + entry.bundleIDs {
                names += [name, name.uppercased(), name.lowercased()]
            }
        }
        names += ["", "not-a-cache-folder", "com.example.nothing"]

        for name in names {
            let expected = Self.referenceKey(for: name, in: entries)
            #expect(ExplanationDatabase.definitionKey(forFolderName: name) == expected, "\(name)")
            let record = ExplanationDatabase.matchBundledDatabase(folderName: name)
            #expect(record?.displayName == expected.flatMap { ExplanationDatabase.record(forKey: $0)?.displayName }, "\(name)")
            #expect(record?.tag == expected.flatMap { ExplanationDatabase.record(forKey: $0)?.tag }, "\(name)")
        }
    }

    @Test func bundleIDsByKeyMatchTheFile() throws {
        for entry in try Self.entries() {
            #expect(ExplanationDatabase.allBundleIDs(forKey: entry.key) == entry.bundleIDs)
        }
    }

    /// The scanners look names up from many threads at once.
    @Test func concurrentLookupsAgree() async throws {
        let names = try Self.entries().flatMap { [$0.key] + $0.aliases + $0.bundleIDs }
        let expected = names.map { ExplanationDatabase.definitionKey(forFolderName: $0) }
        let results = await withTaskGroup(of: [String?].self) { group in
            for _ in 0..<8 {
                group.addTask { names.map { ExplanationDatabase.definitionKey(forFolderName: $0) } }
            }
            return await group.reduce(into: [[String?]]()) { $0.append($1) }
        }
        #expect(results.count == 8)
        for result in results {
            #expect(result == expected)
        }
    }
}
