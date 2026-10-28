import Foundation

/// Read-only summary of what Purge may clean, derived from the live safety definitions.
/// Presentation only: no changes to deletion behavior.
enum SafetyAllowlistSummary {

    struct Category: Identifiable {
        let id: String
        let icon: String
        let title: String
        let description: String
        let backingCount: Int
    }

    private enum CategoryID {
        static let appCaches = "app-caches"
        static let browserCaches = "browser-caches"
        static let devCaches = "dev-caches"
        static let systemJunk = "system-junk"
    }

    static var allowedCategories: [Category] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let whitelistedPrefixes = DeletionSafetyPolicy.whitelistedAbsolutePrefixes(home: home)

        let appSupportCacheCount = CacheDiscoveryPaths.applicationSupportDirectCacheNames.count
        let libraryCachesIncluded = whitelistedPrefixes.contains { $0.hasSuffix("/Library/Caches") } ? 1 : 0

        let browserCacheCount =
            CacheDiscoveryPaths.chromiumProfileCacheNames.count
            + CacheDiscoveryPaths.chromiumProfileRelativePaths.count

        let devCacheCount = DeletionSafetyPolicy.whitelistedFolderNames.count

        let logsPrefix = "\(home)/Library/Logs"
        // Plus the one rule for leftover macOS update files (#127).
        let systemJunkCount = whitelistedPrefixes.filter {
            $0 == logsPrefix || $0.hasPrefix(logsPrefix + "/")
        }.count + 1

        return [
            Category(
                id: CategoryID.appCaches,
                icon: "app.badge",
                title: String(localized: "App caches"),
                description: String(localized: "Regenerable cache folders under ~/Library/Caches and Application Support"),
                backingCount: appSupportCacheCount + libraryCachesIncluded
            ),
            Category(
                id: CategoryID.browserCaches,
                icon: "globe",
                title: String(localized: "Browser caches per profile"),
                description: String(localized: "Chromium profile caches and service worker stores, per browser profile"),
                backingCount: browserCacheCount
            ),
            Category(
                id: CategoryID.devCaches,
                icon: "hammer",
                title: String(localized: "Common dev caches"),
                description: String(localized: "Rebuildable project artifacts like node_modules, DerivedData, and build output"),
                backingCount: devCacheCount
            ),
            Category(
                id: CategoryID.systemJunk,
                icon: "doc.text",
                title: String(localized: "Logs, crash reports, and update leftovers"),
                description: String(localized: "User logs and diagnostic reports under ~/Library/Logs, and files a finished macOS update left behind"),
                backingCount: systemJunkCount
            )
        ]
    }

    /// What cleaning never takes, then what it doesn't speak for: Large Files and
    /// the uninstaller have their own gate and remove whatever the user confirms,
    /// apps that need an admin password included (#191).
    static var boundaryLine: String {
        var parts = neverCleanedFolderLabels

        let protectedContainerCount =
            DeletionSafetyPolicy.protectedContainerBundleIDs.count
            + DeletionSafetyPolicy.protectedSystemCacheFolderNames.count
            + DeletionSafetyPolicy.protectedLogFolderNames.count
        if protectedContainerCount > 0 {
            parts.append(String(localized: "protected containers"))
        }

        if !DeletionSafetyPolicy.systemCacheDeletionPrefixes.isEmpty {
            // Leftover macOS update files are the one exception, moved by the helper
            // only after the user turns secure removal on (#127).
            parts.append(String(localized: "system folders that need an admin password, except leftover macOS update files"))
        }

        let userPicked = String(localized: "Large Files and the uninstaller remove only what you confirm, which can include your own files and apps that need an admin password.")
        guard !parts.isEmpty else { return userPicked }
        let list = ListFormatter.localizedString(byJoining: parts)
        return String(localized: "Cleaning never touches \(list).") + " " + userPicked
    }

    /// Folders `evaluate` refuses along with everything inside them. Documents,
    /// Desktop, Downloads and Application Support are refused as folders only,
    /// because the caches and build folders inside them are cleaned, so they are
    /// never named here. Nor is a never-delete folder with an allowlisted path
    /// inside it: the allowlist is checked first, so `~/Movies/CacheClip` is
    /// cleaned although `~/Movies` is protected.
    static var neverCleanedFolderLabels: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let allowlisted = DeletionSafetyPolicy.whitelistedAbsolutePrefixes(home: home)

        func label(for path: String) -> String? {
            guard path.hasPrefix(home + "/") else { return nil }
            switch String(path.dropFirst(home.count + 1)) {
            case "Library/Keychains": return String(localized: "keychains")
            case "Library/Preferences": return String(localized: "preferences")
            // Only the mailboxes. Mail's attachment copies in its container are
            // allowlisted.
            case "Library/Mail": return String(localized: "Mail mailboxes")
            case "Pictures": return String(localized: "pictures")
            case "Music": return String(localized: "music")
            case "Movies": return String(localized: "movies")
            default: return nil
            }
        }

        var seen = Set<String>()
        return DeletionSafetyPolicy.neverDeletePrefixes(home: home).compactMap { path in
            guard !allowlisted.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else { return nil }
            guard let label = label(for: path), seen.insert(label).inserted else { return nil }
            return label
        }
    }
}
