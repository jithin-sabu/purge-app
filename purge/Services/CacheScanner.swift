import AppKit
import Foundation

enum CacheScanEvent {
    case status(String)
    case found(CacheItem)
    case sizeResolved(path: String, sizeBytes: Int64, lastModified: Date)
}

final class CacheScanner {
    private struct SizeJob {
        let path: URL
    }

    private var excludedFromGeneralScan: Set<String> {
        DeletionSafetyPolicy.protectedSystemCacheFolderNames.union([
            "com.docker.docker",
            "com.docker.helper",
            "com.docker.backend"
        ])
    }

    func scanCaches() async -> [CacheItem] {
        var items: [CacheItem] = []
        for await event in scanGeneralStream() {
            switch event {
            case .found(let item):
                items = DefinitionCacheGrouper.group(items + [item])
            case .sizeResolved(let path, let sizeBytes, let lastModified):
                items = Self.itemsByApplyingSize(path: path, sizeBytes: sizeBytes, lastModified: lastModified, to: items)
            case .status:
                break
            }
        }
        return items
    }

    func scanSystemJunk() async -> [CacheItem] {
        let all = await scanCaches()
        let junkPaths = Set(systemJunkLocations(home: FileManager.default.homeDirectoryForCurrentUser).map { $0.url.standardizedFileURL.path })
        return all.filter { item in
            item.locations.contains { junkPaths.contains($0.path.standardizedFileURL.path) }
        }
    }

    func scanGeneralStream() -> AsyncStream<CacheScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runGeneralScan(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func calculateFolderSize(at url: URL) -> Int64 {
        FolderSizing.directoryByteSize(at: url)
    }

    private func runGeneralScan(continuation: AsyncStream<CacheScanEvent>.Continuation) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cachesURL = home.appendingPathComponent("Library/Caches", isDirectory: true)
        var sizeJobs: [SizeJob] = []
        var collectedPaths = Set<String>()
        var keysNeedingContainers = Set<String>()

        continuation.yield(.status("Scanning App Caches..."))
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: cachesURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            continuation.finish()
            return
        }

        for directory in contents {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            guard let item = cacheItem(
                at: directory,
                home: home,
                collectedPaths: &collectedPaths
            ) else { continue }
            continuation.yield(.found(item))
            sizeJobs.append(SizeJob(path: directory.standardizedFileURL))
            if let key = item.definitionKey {
                keysNeedingContainers.insert(key)
            }
        }

        let containerItems = containerCacheItems(
            home: home,
            keys: keysNeedingContainers,
            collectedPaths: &collectedPaths
        )
        for item in containerItems {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.found(item))
            sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
        }

        continuation.yield(.status("Scanning System Junk..."))
        for location in systemJunkLocations(home: home) {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            let displayName = location.displayName
            let url = location.url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let folderName = url.lastPathComponent
            let safetyInfo = ExplanationResolver.initialSafetyForCacheFolder(
                folderName: folderName,
                friendlyHeadline: displayName,
                path: url
            )

            continuation.yield(.found(
                CacheItem(
                    definitionKey: ExplanationDatabase.definitionKey(forFolderName: folderName),
                    location: CacheLocation(
                        path: url,
                        sizeBytes: 0,
                        lastModified: .distantPast,
                        folderName: folderName
                    ),
                    appName: displayName,
                    safetyInfo: safetyInfo
                )
            ))
            sizeJobs.append(SizeJob(path: url))
        }

        continuation.yield(.status("Calculating sizes..."))
        await runSizeJobs(sizeJobs, continuation: continuation)
        continuation.finish()
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
                    sizeBytes: 0,
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
                guard !DeletionSafetyPolicy.protectedContainerBundleIDs.contains(bundleID) else {
                    continue
                }
                guard let containerURL = containerCacheURL(forBundleID: bundleID, home: home) else {
                    continue
                }
                let pathKey = containerURL.standardizedFileURL.path
                guard !collectedPaths.contains(pathKey) else { continue }
                collectedPaths.insert(pathKey)

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
                            sizeBytes: 0,
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

    private func runSizeJobs(
        _ jobs: [SizeJob],
        continuation: AsyncStream<CacheScanEvent>.Continuation,
        maxConcurrent: Int = 6
    ) async {
        guard !jobs.isEmpty else { return }
        await withTaskGroup(of: (String, Int64, Date)?.self) { group in
            var iterator = jobs.makeIterator()
            var running = 0

            func enqueueNext() {
                guard let job = iterator.next() else { return }
                running += 1
                group.addTask {
                    if Task.isCancelled { return nil }
                    let size = FolderSizing.directoryByteSize(at: job.path)
                    if Task.isCancelled { return nil }
                    let modified = FolderSizing.contentModificationDate(at: job.path)
                    return (job.path.standardizedFileURL.path, size, modified)
                }
            }

            for _ in 0..<min(maxConcurrent, jobs.count) {
                enqueueNext()
            }

            while running > 0 {
                guard let result = await group.next() else { break }
                running -= 1
                if let (path, size, modified) = result {
                    continuation.yield(.sizeResolved(path: path, sizeBytes: size, lastModified: modified))
                }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                enqueueNext()
            }
        }
    }

    private func systemJunkLocations(home: URL) -> [(displayName: String, url: URL)] {
        [
            (
                "iPhone Backups",
                home.appendingPathComponent(
                    "Library/Application Support/MobileSync/Backup",
                    isDirectory: true
                )
            ),
            (
                "Application Logs",
                home.appendingPathComponent("Library/Logs", isDirectory: true)
            ),
            (
                "Crash Reports",
                home.appendingPathComponent(
                    "Library/Logs/DiagnosticReports",
                    isDirectory: true
                )
            ),
            (
                "macOS Installers",
                URL(fileURLWithPath: "/Applications/Install macOS", isDirectory: true)
            ),
            (
                "Font Cache",
                home.appendingPathComponent("Library/Caches/com.apple.ATS", isDirectory: true)
            )
        ]
    }

    private func containerCacheURL(forBundleID bundleID: String, home: URL) -> URL? {
        let url = home
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Caches", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func itemsByApplyingSize(
        path: String,
        sizeBytes: Int64,
        lastModified: Date,
        to items: [CacheItem]
    ) -> [CacheItem] {
        var updated: [CacheItem] = []
        for item in items {
            let locations = item.locations.compactMap { location -> CacheLocation? in
                guard location.path.standardizedFileURL.path == path else { return location }
                guard sizeBytes > 0 else { return nil }
                return CacheLocation(
                    path: location.path,
                    sizeBytes: sizeBytes,
                    lastModified: lastModified,
                    folderName: location.folderName
                )
            }
            guard !locations.isEmpty else { continue }
            updated.append(item.withLocations(locations))
        }
        return DefinitionCacheGrouper.group(updated)
    }

    private func appNameFromBundleID(_ bundleID: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: appURL.path)
    }
}
