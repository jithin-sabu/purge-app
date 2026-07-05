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
                title: "App caches",
                description: "Regenerable cache folders under ~/Library/Caches and Application Support",
                backingCount: appSupportCacheCount + libraryCachesIncluded
            ),
            Category(
                id: CategoryID.browserCaches,
                icon: "globe",
                title: "Browser caches per profile",
                description: "Chromium profile caches and service worker stores, per browser profile",
                backingCount: browserCacheCount
            ),
            Category(
                id: CategoryID.devCaches,
                icon: "hammer",
                title: "Common dev caches",
                description: "Rebuildable project artifacts like node_modules, DerivedData, and build output",
                backingCount: devCacheCount
            ),
            Category(
                id: CategoryID.systemJunk,
                icon: "doc.text",
                title: "Logs and crash reports",
                description: "User logs and diagnostic reports under ~/Library/Logs",
                backingCount: systemJunkCount
            )
        ]
    }

    static var boundaryLine: String {
        var parts: [String] = []

        if !DeletionSafetyPolicy.systemCacheDeletionPrefixes.isEmpty {
            parts.append("anything requiring admin privileges")
        }

        let protectedContainerCount =
            DeletionSafetyPolicy.protectedContainerBundleIDs.count
            + DeletionSafetyPolicy.protectedSystemCacheFolderNames.count
            + DeletionSafetyPolicy.protectedLogFolderNames.count
        if protectedContainerCount > 0 {
            parts.append("protected containers")
        }

        let personalLabels = personalFileBoundaryLabels
        if !personalLabels.isEmpty {
            parts.append("personal files (\(personalLabels.joined(separator: ", ")))")
        }

        guard !parts.isEmpty else {
            return "What Purge never touches: paths outside the allowlist"
        }

        return "What Purge never touches: \(parts.joined(separator: ", "))"
    }

    /// Friendly labels for user-content roots pulled from never-delete policy paths.
    private static var personalFileBoundaryLabels: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        func label(for path: String) -> String? {
            guard path.hasPrefix(home + "/") else { return nil }
            let relative = String(path.dropFirst(home.count + 1))
            let top = relative.split(separator: "/").first.map(String.init) ?? relative
            switch top {
            case "Documents": return "documents"
            case "Desktop": return "desktop"
            case "Downloads": return "downloads"
            case "Pictures": return "pictures"
            case "Music": return "music"
            case "Movies": return "movies"
            case "Library":
                let sub = relative.split(separator: "/").dropFirst().first.map(String.init) ?? ""
                switch sub {
                case "Keychains": return "keychains"
                case "Preferences": return "preferences"
                case "Mail": return "mail"
                case "Application Support": return "application support"
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
