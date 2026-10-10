import Foundation

/// The on-screen title for a cache row Purge could not match to a bundled
/// explanation.
///
/// Those rows get a title built in English from the app's name, like "Slack Cache"
/// or "Arc Old Version 120.0". The same text is stored and matched on (exclusions,
/// row icons), so the model keeps it in English and only the generic words are
/// translated here, at display time. The app name stays as macOS shows it: brand
/// names are not translated.
///
/// The title alone is ambiguous: "Visual Studio Code Cache" is the plain cache of an
/// app called "Visual Studio Code", while "Slack Code Cache" is Slack's `Code Cache`
/// folder. So the caller also passes the cache folder's own name, and only a folder
/// literally named `Code Cache` reads as a code cache.
nonisolated enum CacheHeadline {
    enum Pattern: Equatable {
        case cache(app: String)
        case codeCache(app: String)
        case serviceWorkerCache(app: String)
        case serviceWorkerScriptCache(app: String)
        case oldVersion(app: String, version: String)
    }

    static func pattern(of headline: String, cacheFolder: String) -> Pattern? {
        if let range = headline.range(of: " Old Version ", options: .backwards),
           range.lowerBound > headline.startIndex,
           range.upperBound < headline.endIndex {
            return .oldVersion(
                app: String(headline[..<range.lowerBound]),
                version: String(headline[range.upperBound...])
            )
        }
        // Longest suffix first, so "X Service Worker Cache" never reads as a plain cache.
        if let app = app(in: headline, before: " Service Worker Script Cache") {
            return .serviceWorkerScriptCache(app: app)
        }
        if let app = app(in: headline, before: " Service Worker Cache") {
            return .serviceWorkerCache(app: app)
        }
        if cacheFolder == "Code Cache", let app = app(in: headline, before: " Code Cache") {
            return .codeCache(app: app)
        }
        if let app = app(in: headline, before: " Cache") {
            return .cache(app: app)
        }
        return nil
    }

    private static func app(in headline: String, before suffix: String) -> String? {
        guard headline.hasSuffix(suffix), headline.count > suffix.count else { return nil }
        return String(headline.dropLast(suffix.count))
    }

    /// `cacheFolder` is the last path component of the row's cache folder.
    static func localized(_ headline: String, cacheFolder: String) -> String {
        switch pattern(of: headline, cacheFolder: cacheFolder) {
        case .cache(let app): return String(localized: "\(app) Cache")
        case .codeCache(let app): return String(localized: "\(app) Code Cache")
        case .serviceWorkerCache(let app): return String(localized: "\(app) Service Worker Cache")
        case .serviceWorkerScriptCache(let app): return String(localized: "\(app) Service Worker Script Cache")
        case .oldVersion(let app, let version): return String(localized: "\(app) Old Version \(version)")
        case nil: return headline
        }
    }
}
