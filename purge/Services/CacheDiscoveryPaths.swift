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
            guard !protectedContainerBundleIDs.contains(bundleID) else { continue }
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
