import Foundation
import Testing
@testable import Purge

/// Fallback cache titles stay English in the model and are only translated on
/// screen. These pin how a title splits into the app name and the generic words,
/// so the app name is never translated or cut short.
@Suite("Cache row titles translate only the generic words")
struct CacheHeadlineTests {
    @Test func plainCacheKeepsTheWholeAppName() {
        #expect(CacheHeadline.pattern(of: "Slack Cache") == .cache(app: "Slack"))
        #expect(CacheHeadline.pattern(of: "Visual Studio Code Cache") == .cache(app: "Visual Studio Code"))
    }

    @Test func longerSuffixesWinOverPlainCache() {
        #expect(CacheHeadline.pattern(of: "Arc Code Cache") == .codeCache(app: "Arc"))
        #expect(CacheHeadline.pattern(of: "Chrome Service Worker Cache") == .serviceWorkerCache(app: "Chrome"))
        #expect(CacheHeadline.pattern(of: "Chrome Service Worker Script Cache") == .serviceWorkerScriptCache(app: "Chrome"))
    }

    @Test func oldVersionSplitsAppAndVersion() {
        #expect(CacheHeadline.pattern(of: "Google Chrome Old Version 120.0.6099.71")
            == .oldVersion(app: "Google Chrome", version: "120.0.6099.71"))
    }

    @Test func otherTitlesAreLeftAlone() {
        #expect(CacheHeadline.pattern(of: "Slack GPUCache") == nil)
        #expect(CacheHeadline.pattern(of: "Cache") == nil)
        #expect(CacheHeadline.pattern(of: " Cache") == nil)
        #expect(CacheHeadline.pattern(of: "Application Logs") == nil)
        #expect(CacheHeadline.localized("Application Logs") == "Application Logs")
    }
}
