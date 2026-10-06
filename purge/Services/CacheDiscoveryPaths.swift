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

    /// Returns every cache candidate path under `~/Library/Application Support/<appRoot>/`.
    ///
    /// A limited scan checks each path with `ProtectedLocations.isReadable` before
    /// anything else reads it, since any of these folders can be a symlink into
    /// Documents and `fileExists` would follow it there.
    nonisolated static func applicationSupportCacheURLs(in appRoot: URL, access: ScanAccess = .full) -> [URL] {
        let fm = FileManager.default
        guard ProtectedLocations.isReadable(appRoot, access: access),
              fm.fileExists(atPath: appRoot.path) else { return [] }

        var results: [URL] = []
        var seen = Set<String>()

        func appendIfExists(_ url: URL) {
            guard ProtectedLocations.isReadable(url, access: access) else { return }
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
        if ProtectedLocations.isReadable(userData, access: access), fm.fileExists(atPath: userData.path) {
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
        home: URL,
        access: ScanAccess = .full
    ) -> [(url: URL, headline: String, key: String)] {
        let fm = FileManager.default
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        var results: [(url: URL, headline: String, key: String)] = []
        for entry in adobeMediaCacheEntries {
            let candidate = appSupport.appendingPathComponent(entry.relative, isDirectory: true)
            guard ProtectedLocations.isReadable(candidate, access: access) else { continue }
            let url = candidate.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            results.append((url, entry.headline, entry.key))
        }
        return results
    }

    /// Fixed-location caches outside `~/Library/Caches` that App Caches lists, each
    /// classified by `key` against `explanations.json`. `needsFullAccess` marks the
    /// ones inside folders a limited scan must not open (Messages, Mail's container).
    nonisolated static let knownCacheEntries: [(relative: String, key: String, needsFullAccess: Bool)] = [
        ("Library/iTunes/iPhone Software Updates", "Device Software Updates", false),
        ("Library/iTunes/iPad Software Updates", "Device Software Updates", false),
        ("Library/iTunes/iPod Software Updates", "Device Software Updates", false),
        ("Movies/CacheClip", "CacheClip", false),
        ("Library/Application Support/com.apple.wallpaper/aerials/videos", "Aerial Wallpaper Videos", false),
        ("Library/Messages/Caches/Previews", "Messages Previews", true),
        ("Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Mail Downloads", true)
    ]

    /// Classification name for every electron-updater download folder. They are
    /// named after the app (`t3code-updater`, `@opencode-aidesktop-updater`), so
    /// they share one entry and show as one row.
    nonisolated static let electronUpdaterKey = "Electron Updater Downloads"

    /// A `~/Library/Caches/<app>-updater` folder with electron-updater's `pending`
    /// download folder inside. The name alone is not enough to call it one.
    nonisolated static func isElectronUpdaterCache(_ directory: URL) -> Bool {
        guard directory.lastPathComponent.lowercased().hasSuffix("-updater") else { return false }
        var isDir: ObjCBool = false
        let pending = directory.appendingPathComponent("pending", isDirectory: true)
        return FileManager.default.fileExists(atPath: pending.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Unfinished downloads directly in ~/Downloads that have not changed for this
    /// long. A browser still downloading touches the file far more often.
    nonisolated static let unfinishedDownloadMinimumAge: TimeInterval = 7 * 24 * 60 * 60

    nonisolated static let unfinishedDownloadsKey = "Unfinished Downloads"

    nonisolated static func unfinishedDownloadURLs(home: URL, now: Date = Date()) -> [URL] {
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard DeletionSafetyPolicy.unfinishedDownloadExtensions.contains(url.pathExtension.lowercased()) else {
                return false
            }
            let modified = FolderSizing.contentModificationDate(at: url)
            return now.timeIntervalSince(modified) >= unfinishedDownloadMinimumAge
        }
        .map(\.standardizedFileURL)
        .sorted { $0.path < $1.path }
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

    /// Classification key and folder name for full macOS installer apps.
    nonisolated static let macOSInstallerKey = "macOS Installer"

    /// `/Applications/Install macOS <Name>.app` bundles whose bundle ID is Apple's
    /// InstallAssistant. The name alone is not enough: any app can be called that.
    nonisolated static func macOSInstallerURLs(applications: URL = URL(fileURLWithPath: "/Applications")) -> [URL] {
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return apps
            .filter { DeletionSafetyPolicy.isMacOSInstallerAppName($0.lastPathComponent) }
            .filter { DeletionSafetyPolicy.isMacOSInstallerBundle(at: $0) }
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
    }

    /// Chromium browsers whose bundles keep old framework versions after an update.
    /// The framework is `<Browser> Framework.framework` in each (Chrome, Brave, Edge
    /// and Chromium each use their own name), found by `chromiumFrameworkVersionsDir`.
    nonisolated static let chromiumBrowserAppNames: [String] = [
        "Google Chrome.app",
        "Google Chrome Beta.app",
        "Google Chrome Dev.app",
        "Google Chrome Canary.app",
        "Chromium.app",
        "Arc.app",
        "Brave Browser.app",
        "Microsoft Edge.app",
        "Vivaldi.app"
    ]

    /// `Contents/Frameworks/<Name> Framework.framework/Versions` inside a browser
    /// bundle: the one Chromium framework, whose versioned folders pile up.
    nonisolated static func chromiumFrameworkVersionsDir(in appURL: URL) -> URL? {
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else {
            return nil
        }
        guard let name = entries.sorted().first(where: { DeletionSafetyPolicy.isChromiumFrameworkName($0) }) else {
            return nil
        }
        return frameworks
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("Versions", isDirectory: true)
    }

    /// Stale Chromium framework versions inside `.app` bundles (not the `Current` symlink target).
    /// Versions a running browser is still executing from are dropped later by
    /// `DeletionSafetyPolicy.staleBrowserFrameworkRefusesDeletion`.
    nonisolated static func staleChromiumFrameworkVersionURLs() -> [URL] {
        let fm = FileManager.default

        var results: [URL] = []
        for appName in chromiumBrowserAppNames {
            let appURL = URL(fileURLWithPath: "/Applications/\(appName)", isDirectory: true)
            guard fm.fileExists(atPath: appURL.path) else { continue }
            guard let versionsDir = chromiumFrameworkVersionsDir(in: appURL),
                  fm.fileExists(atPath: versionsDir.path) else { continue }

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
