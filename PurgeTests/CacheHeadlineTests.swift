import Foundation
import Testing
@testable import Purge

/// Fallback cache titles stay English in the model and are only translated on
/// screen. These pin how a title splits into the app name and the generic words,
/// so the app name is never translated or cut short.
@Suite("Cache row titles translate only the generic words")
struct CacheHeadlineTests {
    @Test func plainCacheKeepsTheWholeAppName() {
        #expect(CacheHeadline.pattern(of: "Slack Cache", cacheFolder: "Cache") == .cache(app: "Slack"))
        // A container's Caches root for an app whose name ends in "Code".
        #expect(CacheHeadline.pattern(of: "Visual Studio Code Cache", cacheFolder: "Caches")
            == .cache(app: "Visual Studio Code"))
    }

    @Test func codeCacheNeedsTheCodeCacheFolder() {
        #expect(CacheHeadline.pattern(of: "Arc Code Cache", cacheFolder: "Code Cache") == .codeCache(app: "Arc"))
        #expect(CacheHeadline.pattern(of: "Visual Studio Code Cache", cacheFolder: "Code Cache")
            == .codeCache(app: "Visual Studio"))
    }

    @Test func longerSuffixesWinOverPlainCache() {
        #expect(CacheHeadline.pattern(of: "Chrome Service Worker Cache", cacheFolder: "CacheStorage")
            == .serviceWorkerCache(app: "Chrome"))
        #expect(CacheHeadline.pattern(of: "Chrome Service Worker Script Cache", cacheFolder: "ScriptCache")
            == .serviceWorkerScriptCache(app: "Chrome"))
    }

    @Test func oldVersionSplitsAppAndVersion() {
        #expect(CacheHeadline.pattern(of: "Google Chrome Old Version 120.0.6099.71", cacheFolder: "120.0.6099.71")
            == .oldVersion(app: "Google Chrome", version: "120.0.6099.71"))
    }

    @Test func otherTitlesAreLeftAlone() {
        #expect(CacheHeadline.pattern(of: "Slack GPUCache", cacheFolder: "GPUCache") == nil)
        #expect(CacheHeadline.pattern(of: "Cache", cacheFolder: "Cache") == nil)
        #expect(CacheHeadline.pattern(of: " Cache", cacheFolder: "Cache") == nil)
        #expect(CacheHeadline.pattern(of: "Application Logs", cacheFolder: "Logs") == nil)
        #expect(CacheHeadline.localized("Application Logs", cacheFolder: "Logs") == "Application Logs")
    }
}
