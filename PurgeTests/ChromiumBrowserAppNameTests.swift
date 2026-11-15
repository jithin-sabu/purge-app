import Foundation
import Testing
@testable import Purge

/// The Old Version row is titled after the browser. The version folder sits five
/// levels inside the `.app`, and counting four named every row "Contents".
@Suite("Old browser versions are named after their browser")
struct ChromiumBrowserAppNameTests {
    private func versionURL(_ app: String, framework: String, version: String) -> URL {
        URL(fileURLWithPath: "/Applications/\(app).app/Contents/Frameworks/\(framework).framework/Versions/\(version)",
            isDirectory: true)
    }

    @Test func namesTheBrowserNotItsContentsFolder() {
        let url = versionURL("Google Chrome", framework: "Google Chrome Framework", version: "155.0.8059.84")
        #expect(CacheDiscoveryPaths.chromiumBrowserAppName(forFrameworkVersion: url) == "Google Chrome")
    }

    @Test func keepsEveryWordOfTheBrowserName() {
        let edge = versionURL("Microsoft Edge", framework: "Microsoft Edge Framework", version: "141.0.1")
        #expect(CacheDiscoveryPaths.chromiumBrowserAppName(forFrameworkVersion: edge) == "Microsoft Edge")
        let brave = versionURL("Brave Browser", framework: "Brave Browser Framework", version: "1.80.1")
        #expect(CacheDiscoveryPaths.chromiumBrowserAppName(forFrameworkVersion: brave) == "Brave Browser")
    }

    @Test func namesTheFrameworkWhenThereIsNoBundle() {
        let url = URL(fileURLWithPath: "/tmp/Chromium Framework.framework/Versions/120.0", isDirectory: true)
        #expect(CacheDiscoveryPaths.chromiumBrowserAppName(forFrameworkVersion: url) == "Chromium")
    }
}
