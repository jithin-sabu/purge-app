import AppKit
import Foundation

@MainActor
final class CacheScanner {
    func scanCaches() async -> [CacheItem] {
        let cachesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)

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
        for directory in contents {
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values.isDirectory == true else { continue }

                let size = FolderSizing.directoryByteSize(at: directory)
                let bundleID = directory.lastPathComponent
                let modified = values.contentModificationDate ?? .distantPast
                let fallbackAppName = appNameFromBundleID(bundleID) ?? bundleID
                let safetyInfo = ExplanationResolver.initialSafetyForCacheFolder(
                    folderName: bundleID,
                    friendlyHeadline: fallbackAppName,
                    path: directory
                )

                items.append(
                    CacheItem(
                        appName: safetyInfo.headline,
                        bundleID: bundleID,
                        path: directory,
                        sizeBytes: size,
                        lastModified: modified,
                        isSelected: false,
                        safetyInfo: safetyInfo,
                        reinstallSafety: .notApplicable,
                        gitStatus: .unknown
                    )
                )
            } catch {
                continue
            }
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    func calculateFolderSize(at url: URL) -> Int64 {
        FolderSizing.directoryByteSize(at: url)
    }

    private func appNameFromBundleID(_ bundleID: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: appURL.path)
    }
}
