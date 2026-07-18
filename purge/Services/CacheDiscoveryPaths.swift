import Foundation

/// Shared rules for locating cache directories outside `~/Library/Caches`.
enum CacheDiscoveryPaths {
    /// Direct cache folder names under an app’s Application Support root.
    nonisolated static let applicationSupportDirectCacheNames: Set<String> = [
        "Cache",
        "Code Cache",
        "GPUCache",
        "ShaderCache",
        "DawnWebGPUCache",
        "CachedData",
        "component_crx_cache"
    ]

    /// Relative paths (from an app’s Application Support root) always treated as caches.
    nonisolated static let applicationSupportRelativeCachePaths: [String] = [
        "Crashpad/completed"
    ]

    /// Cache folder names under Chromium `User Data/<profile>/`.
    nonisolated static let chromiumProfileCacheNames: Set<String> = [
        "GPUCache",
        "ShaderCache",
        "Code Cache",
        "Cache"
    ]

    /// Relative paths under a Chromium profile directory.
    nonisolated static let chromiumProfileRelativePaths: [String] = [
        "Service Worker/CacheStorage",
        "Service Worker/ScriptCache"
    ]

    /// Application Support roots that are not app caches (handled elsewhere or sensitive).
    nonisolated static let excludedApplicationSupportRoots: Set<String> = [
        "MobileSync",
        "CallHistoryDB",
        "AddressBook",
        "SyncServices",
        "Knowledge",
        "com.apple.TCC",
        "com.apple.sharedfilelist"
    ]

    /// Bundle IDs under `~/Library/Containers` whose caches must not be removed.
    nonisolated static var protectedContainerBundleIDs: Set<String> {
        DeletionSafetyPolicy.protectedContainerBundleIDs
    }

    /// Returns every cache candidate path under `~/Library/Application Support/<appRoot>/`.
    nonisolated static func applicationSupportCacheURLs(in appRoot: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appRoot.path) else { return [] }

        var results: [URL] = []
        var seen = Set<String>()

        func appendIfExists(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), fm.fileExists(atPath: url.path) else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            seen.insert(key)
            results.append(url.standardizedFileURL)
        }

        for name in applicationSupportDirectCacheNames {
            appendIfExists(appRoot.appendingPathComponent(name, isDirectory: true))
        }

        for relative in applicationSupportRelativeCachePaths {
            appendIfExists(appRoot.appendingPathComponent(relative, isDirectory: true))
        }

        let userData = appRoot.appendingPathComponent("User Data", isDirectory: true)
        if fm.fileExists(atPath: userData.path) {
            appendChromiumProfileCaches(userData: userData, appendIfExists: appendIfExists)
        }

        return results
    }

    private nonisolated static func appendChromiumProfileCaches(
        userData: URL,
        appendIfExists: (URL) -> Void
    ) {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(
            at: userData,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for profileDir in profiles {
            guard (try? profileDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            for name in chromiumProfileCacheNames {
                appendIfExists(profileDir.appendingPathComponent(name, isDirectory: true))
            }
            for relative in chromiumProfileRelativePaths {
                appendIfExists(profileDir.appendingPathComponent(relative, isDirectory: true))
            }
        }
    }

    /// Default Adobe media cache locations under Application Support.
    ///
    /// Premiere Pro and After Effects park large rendered previews, conformed
    /// audio, and the index that tracks them here — outside `~/Library/Caches`,
    /// so the general Caches sweep never sees them. Only the default `Common`
    /// locations are listed; a project-local or user-chosen scratch cache is
    /// never targeted. `key` doubles as the folder name used for classification
    /// (matched against `explanations.json`).
    nonisolated static let adobeMediaCacheEntries: [(relative: String, headline: String, key: String)] = [
        ("Adobe/Common/Media Cache Files", "Adobe Media Cache Files", "Adobe Media Cache Files"),
        ("Adobe/Common/Media Cache", "Adobe Media Cache Database", "Adobe Media Cache")
    ]

    /// Adobe media cache directories that actually exist on disk. Absent Adobe
    /// folders (app not installed) simply yield nothing — never an error row.
    nonisolated static func adobeMediaCacheURLs(
        home: URL
    ) -> [(url: URL, headline: String, key: String)] {
        let fm = FileManager.default
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        var results: [(url: URL, headline: String, key: String)] = []
        for entry in adobeMediaCacheEntries {
            let url = appSupport
                .appendingPathComponent(entry.relative, isDirectory: true)
                .standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            results.append((url, entry.headline, entry.key))
        }
        return results
    }

    /// Telegram's native macOS app parks auto-downloaded photos, videos, and
    /// files inside its Group Container rather than `~/Library/Caches`, so the
    /// broad Caches sweep never reaches them. Only the `postbox/media` directory
    /// is ever targeted — never `postbox` itself, which holds the account
    /// database whose removal would log the user out or lose local data. The
    /// optional leading segment covers the distribution channel (stable,
    /// appstore, and any future channel); `account-*` covers every signed-in
    /// account. The match still terminates at `postbox/media` exactly.
    nonisolated static let telegramGroupContainerRelative =
        "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"

    /// Folder name used for classification (matched against `explanations.json`)
    /// and the headline shown in the list.
    nonisolated static let telegramMediaCacheKey = "Telegram Media Cache"

    /// Existing `.../[channel/]account-*/postbox/media` directories across all
    /// distribution channels and signed-in accounts. Absent folders (Telegram
    /// not installed) simply yield nothing — never an error row.
    nonisolated static func telegramMediaCacheURLs(
        home: URL
    ) -> [(url: URL, headline: String, key: String)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent(telegramGroupContainerRelative, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return [] }

        func subdirectories(of dir: URL, namePrefix: String? = nil) -> [URL] {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return entries.filter { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return false
                }
                if let namePrefix { return url.lastPathComponent.hasPrefix(namePrefix) }
                return true
            }
        }

        // `account-*` — one directory per signed-in account. Accounts usually sit
        // under a distribution channel dir (stable, appstore, any future channel),
        // but some installs place them straight at the container root.
        var accountDirs = subdirectories(of: root, namePrefix: "account-")
        for channelDir in subdirectories(of: root)
        where !channelDir.lastPathComponent.hasPrefix("account-") {
            accountDirs.append(contentsOf: subdirectories(of: channelDir, namePrefix: "account-"))
        }

        var results: [(url: URL, headline: String, key: String)] = []
        for accountDir in accountDirs {
            let media = accountDir
                .appendingPathComponent("postbox", isDirectory: true)
                .appendingPathComponent("media", isDirectory: true)
                .standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: media.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            results.append((media, telegramMediaCacheKey, telegramMediaCacheKey))
        }
        return results
    }

    /// Enumerates cache paths under `~/Library/Containers/<bundleID>/Data/Library/Caches`.
    nonisolated static func containerCacheURLs(home: URL) -> [URL] {
        let containersRoot = home.appendingPathComponent("Library/Containers", isDirectory: true)
        let fm = FileManager.default
        guard let bundleDirs = try? fm.contentsOfDirectory(
            at: containersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for bundleDir in bundleDirs {
            let bundleID = bundleDir.lastPathComponent
            guard !DeletionSafetyPolicy.isProtectedContainerBundleID(bundleID) else { continue }
            let cachesRoot = bundleDir
                .appendingPathComponent("Data/Library/Caches", isDirectory: true)
            guard fm.fileExists(atPath: cachesRoot.path) else { continue }

            if let children = try? fm.contentsOfDirectory(
                at: cachesRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ), !children.isEmpty {
                let subdirs = children.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                if subdirs.isEmpty {
                    results.append(cachesRoot.standardizedFileURL)
                } else {
                    results.append(contentsOf: subdirs.map { $0.standardizedFileURL })
                }
            } else {
                results.append(cachesRoot.standardizedFileURL)
            }
        }
        return results
    }

    /// Stale Chromium framework versions inside `.app` bundles (not the `Current` symlink target).
    nonisolated static func staleChromiumFrameworkVersionURLs() -> [URL] {
        let fm = FileManager.default
        let appNames = [
            "Google Chrome.app",
            "Google Chrome Canary.app",
            "Chromium.app",
            "Arc.app",
            "Brave Browser.app",
            "Microsoft Edge.app"
        ]

        var results: [URL] = []
        for appName in appNames {
            let appURL = URL(fileURLWithPath: "/Applications/\(appName)", isDirectory: true)
            guard fm.fileExists(atPath: appURL.path) else { continue }
            let versionsDir = appURL
                .appendingPathComponent("Contents/Frameworks", isDirectory: true)
                .appendingPathComponent("Google Chrome Framework.framework/Versions", isDirectory: true)
            guard fm.fileExists(atPath: versionsDir.path) else { continue }

            let currentLink = versionsDir.appendingPathComponent("Current", isDirectory: false)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) else { continue }
            let currentResolved = URL(fileURLWithPath: dest, relativeTo: versionsDir).lastPathComponent

            guard let versionDirs = try? fm.contentsOfDirectory(
                at: versionsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for versionDir in versionDirs {
                let name = versionDir.lastPathComponent
                if name == "Current" { continue }
                if (try? versionDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { continue }
                if name == currentResolved { continue }
                results.append(versionDir.standardizedFileURL)
            }
        }
        return results
    }
}
