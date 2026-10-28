import Foundation
import Testing
@testable import Purge

@Suite("Chinese safety explanations reach dev-tool rows")
struct ChineseExplanationTests {
    /// The test host runs in English, so this reads the zh-Hans table directly. The
    /// Chinese text must replace the headline and the explanation, while the risk
    /// level and the reinstall command stay as they are.
    @Test
    func devToolRowsUseTheLocalizedSafetyRecordWithoutChangingRiskOrCommand() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let zh = try #require(Bundle(path: path))
        let record = try #require(ExplanationDatabase.matchBundledDatabase(folderName: "adobe-media-cache-files"))

        let info = SafetyInfo.fromExplanationDatabase(key: "adobe-media-cache-files", reinstallCommand: "npm ci", bundle: zh)

        #expect(info.headline == "Adobe 媒体缓存文件")
        #expect(info.explanation == "Premiere Pro 和 After Effects 的已渲染预览和已适配音频。应用下次启动时会重建，大型项目可能需要几分钟。")
        #expect(info.level == record.safetyLevel)
        #expect(info.level == .safe)
        #expect(info.reinstallCommand == "npm ci")
    }
}
