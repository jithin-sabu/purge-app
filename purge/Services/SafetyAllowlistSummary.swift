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
        let systemJunkCount = whitelistedPrefixes.filter {
            $0 == logsPrefix || $0.hasPrefix(logsPrefix + "/")
        }.count

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
                title: String(localized: "Logs and crash reports"),
                description: String(localized: "User logs and diagnostic reports under ~/Library/Logs"),
                backingCount: systemJunkCount
            )
        ]
    }

    static var boundaryLine: String {
        var parts: [String] = []

        if !DeletionSafetyPolicy.systemCacheDeletionPrefixes.isEmpty {
            parts.append(String(localized: "anything requiring admin privileges"))
        }

        let protectedContainerCount =
            DeletionSafetyPolicy.protectedContainerBundleIDs.count
            + DeletionSafetyPolicy.protectedSystemCacheFolderNames.count
            + DeletionSafetyPolicy.protectedLogFolderNames.count
        if protectedContainerCount > 0 {
            parts.append(String(localized: "protected containers"))
        }

        let personalLabels = personalFileBoundaryLabels
        if !personalLabels.isEmpty {
            parts.append(String(localized: "personal files (\(personalLabels.joined(separator: ", ")))") )
        }

        guard !parts.isEmpty else {
            return String(localized: "What Purge never touches: paths outside the allowlist")
        }

        return String(localized: "What Purge never touches: \(parts.joined(separator: ", "))")
    }

    /// Friendly labels for user-content roots pulled from never-delete policy paths.
    private static var personalFileBoundaryLabels: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        func label(for path: String) -> String? {
            guard path.hasPrefix(home + "/") else { return nil }
            let relative = String(path.dropFirst(home.count + 1))
            let top = relative.split(separator: "/").first.map(String.init) ?? relative
            switch top {
            case "Documents": return String(localized: "documents")
            case "Desktop": return String(localized: "desktop")
            case "Downloads": return String(localized: "downloads")
            case "Pictures": return String(localized: "pictures")
            case "Music": return String(localized: "music")
            case "Movies": return String(localized: "movies")
            case "Library":
                let sub = relative.split(separator: "/").dropFirst().first.map(String.init) ?? ""
                switch sub {
                case "Keychains": return String(localized: "keychains")
                case "Preferences": return String(localized: "preferences")
                case "Mail": return String(localized: "mail")
                case "Application Support": return String(localized: "application support")
                default: return nil
                }
            default:
                return top.lowercased()
            }
        }

        var seen = Set<String>()
        var labels: [String] = []

        for path in DeletionSafetyPolicy.neverDeleteExactPaths(home: home) + DeletionSafetyPolicy.neverDeletePrefixes(home: home) {
            guard path.hasPrefix(home) else { continue }
            guard let label = label(for: path), seen.insert(label).inserted else { continue }
            labels.append(label)
        }

        return labels
    }
}
