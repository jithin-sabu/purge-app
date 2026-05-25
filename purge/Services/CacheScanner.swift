import AppKit
import Foundation

@MainActor
final class CacheScanner {
    private var excludedFromGeneralScan: Set<String> {
        DeletionSafetyPolicy.protectedSystemCacheFolderNames.union([
            "com.docker.docker",
            "com.docker.helper",
            "com.docker.backend"
        ])
    }

    func scanCaches() async -> [CacheItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cachesURL = home.appendingPathComponent("Library/Caches", isDirectory: true)

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: cachesURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var items: [CacheItem] = []
        var collectedPaths = Set<String>()
        var keysNeedingContainers = Set<String>()

        for directory in contents {
            guard let item = cacheItem(
                at: directory,
                home: home,
                collectedPaths: &collectedPaths
            ) else { continue }
            items.append(item)
            if let key = item.definitionKey {
                keysNeedingContainers.insert(key)
            }
        }

        items.append(contentsOf: containerCacheItems(
            home: home,
            keys: keysNeedingContainers,
            collectedPaths: &collectedPaths
        ))

        return DefinitionCacheGrouper.group(items)
    }

    func scanSystemJunk() async -> [CacheItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var items: [CacheItem] = []

        let junkLocations: [(String, String, URL)] = [
            (
                "iPhone Backups",
                "iphone.gen3",
                home.appendingPathComponent(
                    "Library/Application Support/MobileSync/Backup",
                    isDirectory: true
                )
            ),
            (
                "Application Logs",
                "doc.text.fill",
                home.appendingPathComponent("Library/Logs", isDirectory: true)
            ),
            (
                "Crash Reports",
                "exclamationmark.triangle.fill",
                home.appendingPathComponent(
                    "Library/Logs/DiagnosticReports",
                    isDirectory: true
                )
            ),
            (
                "macOS Installers",
                "arrow.down.circle.fill",
                URL(fileURLWithPath: "/Applications/Install macOS", isDirectory: true)
            ),
            (
                "Font Cache",
                "textformat",
                home.appendingPathComponent("Library/Caches/com.apple.ATS", isDirectory: true)
            )
        ]

        for (displayName, _, url) in junkLocations {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = FolderSizing.directoryByteSize(at: url)
            guard size > 0 else { continue }

            let modified = FolderSizing.contentModificationDate(at: url)
            let folderName = url.lastPathComponent
            let safetyInfo = ExplanationResolver.initialSafetyForCacheFolder(
                folderName: folderName,
                friendlyHeadline: displayName,
                path: url
            )

            items.append(
                CacheItem(
                    definitionKey: ExplanationDatabase.definitionKey(forFolderName: folderName),
                    location: CacheLocation(
                        path: url,
                        sizeBytes: size,
                        lastModified: modified,
                        folderName: folderName
                    ),
                    appName: displayName,
                    safetyInfo: safetyInfo
                )
            )
        }

        return DefinitionCacheGrouper.group(items)
    }

    func calculateFolderSize(at url: URL) -> Int64 {
        FolderSizing.directoryByteSize(at: url)
    }

    private func cacheItem(
        at directory: URL,
        home: URL,
        collectedPaths: inout Set<String>
    ) -> CacheItem? {
        do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { return nil }

            let bundleID = directory.lastPathComponent
            guard !excludedFromGeneralScan.contains(bundleID) else { return nil }

            let pathKey = directory.standardizedFileURL.path
            guard !collectedPaths.contains(pathKey) else { return nil }
            collectedPaths.insert(pathKey)

            let size = FolderSizing.directoryByteSize(at: directory)
            let modified = values.contentModificationDate ?? .distantPast
            let fallbackAppName = appNameFromBundleID(bundleID) ?? bundleID
            let safetyInfo = ExplanationResolver.initialSafetyForCacheFolder(
                folderName: bundleID,
                friendlyHeadline: fallbackAppName,
                path: directory
            )

            return CacheItem(
                definitionKey: ExplanationDatabase.definitionKey(forFolderName: bundleID),
                location: CacheLocation(
                    path: directory,
                    sizeBytes: size,
                    lastModified: modified,
                    folderName: bundleID
                ),
                appName: safetyInfo.headline,
                safetyInfo: safetyInfo
            )
        } catch {
            return nil
        }
    }

    private func containerCacheItems(
        home: URL,
        keys: Set<String>,
        collectedPaths: inout Set<String>
    ) -> [CacheItem] {
        var items: [CacheItem] = []
        for key in keys {
            for bundleID in ExplanationDatabase.containerProbeBundleIDs(forKey: key) {
                guard let containerURL = ExplanationDatabase.containerCacheURL(forBundleID: bundleID, home: home) else {
                    continue
                }
                let pathKey = containerURL.standardizedFileURL.path
                guard !collectedPaths.contains(pathKey) else { continue }
                collectedPaths.insert(pathKey)

                let size = FolderSizing.directoryByteSize(at: containerURL)
                let modified = FolderSizing.contentModificationDate(at: containerURL)
                let fallbackAppName = appNameFromBundleID(bundleID) ?? bundleID
                let safetyInfo = ExplanationResolver.initialSafetyForCacheFolder(
                    folderName: bundleID,
                    friendlyHeadline: fallbackAppName,
                    path: containerURL
                )

                items.append(
                    CacheItem(
                        definitionKey: key,
                        location: CacheLocation(
                            path: containerURL,
                            sizeBytes: size,
                            lastModified: modified,
                            folderName: bundleID
                        ),
                        appName: safetyInfo.headline,
                        safetyInfo: safetyInfo
                    )
                )
            }
        }
        return items
    }

    private func appNameFromBundleID(_ bundleID: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: appURL.path)
    }
}
