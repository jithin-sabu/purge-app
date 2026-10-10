import Foundation
import Testing
@testable import Purge

@Suite("Chinese safety explanations reach dev-tool rows")
struct ChineseExplanationTests {
    @Test
    func devToolRowsUseTheLocalizedSafetyRecordWithoutChangingRiskOrCommand() throws {
        let record = try #require(ExplanationDatabase.matchBundledDatabase(folderName: "adobe-media-cache-files"))
        let expected = ExplanationDatabase.safetyInfo(from: record, reinstallCommand: "npm ci")
        let actual = SafetyInfo.fromExplanationDatabase(key: "adobe-media-cache-files", reinstallCommand: "npm ci")
        #expect(actual.explanation == expected.explanation)
        #expect(actual.headline == expected.headline)
        #expect(actual.level == record.safetyLevel)
        #expect(actual.reinstallCommand == "npm ci")
    }
}
