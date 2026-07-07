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
        let discoveryStart = Date()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cachesURL = home.appendingPathComponent("Library/Caches", isDirectory: true)
        var sizeJobs: [SizeJob] = []
        // Seed with paths the Dev Tools scan owns so they are skipped here instead of
        // appearing under App Caches and later being pulled out when the dev scan runs.
        var collectedPaths = DevScanner.claimedGlobalCachePaths()
        let hasFullDiskAccess = PermissionChecker().hasFullDiskAccess()

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
        }

        if hasFullDiskAccess {
            continuation.yield(.status("Scanning Application Support caches..."))
            let appSupportItems = applicationSupportCacheItems(home: home, collectedPaths: &collectedPaths)
            for item in appSupportItems {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                continuation.yield(.found(item))
                sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
            }

            continuation.yield(.status("Scanning sandboxed app caches..."))
            let containerItems = allContainerCacheItems(home: home, collectedPaths: &collectedPaths)
            for item in containerItems {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                continuation.yield(.found(item))
                sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
            }
        }

        continuation.yield(.status("Scanning browser app bundles..."))
        let staleFrameworkItems = staleChromiumFrameworkItems(collectedPaths: &collectedPaths)
        for item in staleFrameworkItems {
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
            guard DeletionSafetyPolicy.isOfferedForCleanup(url) else { continue }
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

        ScanPhaseTiming.finish(
            "app cache discovery",
            since: discoveryStart,
            detail: "\(sizeJobs.count) cache locations queued, \(collectedPaths.count) unique paths"
        )

        continuation.yield(.status("Calculating sizes..."))
        let sizingStart = Date()
        await runSizeJobs(sizeJobs, continuation: continuation)
        ScanPhaseTiming.finish(
            "app cache sizing",
            since: sizingStart,
            detail: "\(sizeJobs.count) du batch paths"
        )
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
            guard DeletionSafetyPolicy.isOfferedForCleanup(directory) else { return nil }
            guard !collectedPaths.contains(pathKey) else { return nil }
            collectedPaths.insert(pathKey)

            let modified = values.contentModificationDate ?? .distantPast
            let fallbackAppName = appDisplayName(forBundleID: bundleID) ?? bundleID
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

    private func applicationSupportCacheItems(
        home: URL,
        collectedPaths: inout Set<String>
    ) -> [CacheItem] {
        let appSupportRoot = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        guard let appDirs = try? FileManager.default.contentsOfDirectory(
            at: appSupportRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [CacheItem] = []
        for appDir in appDirs {
            guard (try? appDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let appFolderName = appDir.lastPathComponent
            guard !CacheDiscoveryPaths.excludedApplicationSupportRoots.contains(appFolderName) else {
                continue
            }

            for cacheURL in CacheDiscoveryPaths.applicationSupportCacheURLs(in: appDir) {
                guard let item = cacheItemAtDiscoveredPath(
                    cacheURL,
                    headline: applicationSupportHeadline(appFolderName: appFolderName, cacheURL: cacheURL),
                    folderName: appFolderName,
                    collectedPaths: &collectedPaths
                ) else { continue }
                items.append(item)
            }
        }
        return items
    }

    private func allContainerCacheItems(
        home: URL,
        collectedPaths: inout Set<String>
    ) -> [CacheItem] {
        var items: [CacheItem] = []
        for cacheURL in CacheDiscoveryPaths.containerCacheURLs(home: home) {
            let bundleID = containerBundleID(from: cacheURL) ?? cacheURL.lastPathComponent
            let appName = appDisplayName(forBundleID: bundleID) ?? bundleID
            let subfolderName = cacheURL.lastPathComponent
            let isCachesRoot = subfolderName == "Caches"
            let folderName = isCachesRoot ? bundleID : subfolderName
            let headline = isCachesRoot ? "\(appName) Cache" : "\(appName) \(subfolderName)"
            guard let item = cacheItemAtDiscoveredPath(
                cacheURL,
                headline: headline,
                folderName: folderName,
                collectedPaths: &collectedPaths
            ) else { continue }
            items.append(item)
        }
        return items
    }

    private func staleChromiumFrameworkItems(collectedPaths: inout Set<String>) -> [CacheItem] {
        var items: [CacheItem] = []
        for frameworkVersionURL in CacheDiscoveryPaths.staleChromiumFrameworkVersionURLs() {
            let appName = frameworkVersionURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
            let version = frameworkVersionURL.lastPathComponent
            let headline = "\(appName) Old Version \(version)"
            let pathKey = frameworkVersionURL.standardizedFileURL.path
            guard DeletionSafetyPolicy.isOfferedForCleanup(frameworkVersionURL) else { continue }
            guard !collectedPaths.contains(pathKey) else { continue }
            collectedPaths.insert(pathKey)

            let safety = SafetyInfo(
                level: .medium,
                headline: headline,
                explanation: "An older Chromium framework bundled inside \(appName). Removing it frees space; the app should keep using the current version.",
                recoverySteps: "Reinstall \(appName) from the vendor if the app fails to launch after cleanup.",
                reinstallCommand: nil
            )
            items.append(
                CacheItem(
                    definitionKey: nil,
                    location: CacheLocation(
                        path: frameworkVersionURL,
                        sizeBytes: 0,
                        lastModified: FolderSizing.contentModificationDate(at: frameworkVersionURL),
                        folderName: "stale-browser-framework"
                    ),
                    appName: headline,
                    safetyInfo: safety
                )
            )
        }
        return items
    }

    private func cacheItemAtDiscoveredPath(
        _ url: URL,
        headline: String,
        folderName: String,
        collectedPaths: inout Set<String>
    ) -> CacheItem? {
        let pathKey = url.standardizedFileURL.path
        guard DeletionSafetyPolicy.isOfferedForCleanup(url) else { return nil }
        guard !collectedPaths.contains(pathKey) else { return nil }
        collectedPaths.insert(pathKey)

        let modified = FolderSizing.contentModificationDate(at: url)
        let safetyInfo = ExplanationResolver.initialSafetyForCacheFolder(
            folderName: folderName,
            friendlyHeadline: headline,
            path: url
        )
        return CacheItem(
            definitionKey: ExplanationDatabase.definitionKey(forFolderName: folderName),
            location: CacheLocation(
                path: url,
                sizeBytes: 0,
                lastModified: modified,
                folderName: folderName
            ),
            appName: safetyInfo.headline,
            safetyInfo: safetyInfo
        )
    }

    private func applicationSupportHeadline(appFolderName: String, cacheURL: URL) -> String {
        let cacheLeaf = cacheURL.lastPathComponent
        let displayApp = appFolderName
            .replacingOccurrences(of: "company.thebrowser.", with: "")
            .replacingOccurrences(of: "com.google.", with: "")
            .replacingOccurrences(of: "com.apple.", with: "")
        if cacheLeaf == "Cache" || cacheLeaf == "CachedData" {
            return "\(displayApp) Cache"
        }
        if cacheURL.path.contains("Service Worker/CacheStorage") {
            return "\(displayApp) Service Worker Cache"
        }
        if cacheURL.path.contains("Service Worker/ScriptCache") {
            return "\(displayApp) Service Worker Script Cache"
        }
        return "\(displayApp) \(cacheLeaf)"
    }

    private func containerBundleID(from cacheURL: URL) -> String? {
        let components = cacheURL.standardizedFileURL.pathComponents
        guard let containersIndex = components.firstIndex(of: "Containers"),
              containersIndex + 1 < components.count else { return nil }
        return components[containersIndex + 1]
    }

    private func runSizeJobs(
        _ jobs: [SizeJob],
        continuation: AsyncStream<CacheScanEvent>.Continuation
    ) async {
        guard !jobs.isEmpty else { return }

        let chunkSize = FolderSizing.duChunkSize
        let maxConcurrent = 10
        var chunks: [[SizeJob]] = []
        var index = 0
        while index < jobs.count {
            chunks.append(Array(jobs[index..<min(index + chunkSize, jobs.count)]))
            index += chunkSize
        }

        await withTaskGroup(of: ([SizeJob], [String: Int64])?.self) { group in
            var iterator = chunks.makeIterator()
            var running = 0

            func enqueueNext() {
                guard let chunk = iterator.next() else { return }
                running += 1
                group.addTask {
                    if Task.isCancelled { return nil }
                    let paths = chunk.map(\.path)
                    let sizesByPath = FolderSizing.directorySizesForChunk(paths)
                    if Task.isCancelled { return nil }
                    return (chunk, sizesByPath)
                }
            }

            for _ in 0..<min(maxConcurrent, chunks.count) {
                enqueueNext()
            }

            while running > 0 {
                guard let result = await group.next() else { break }
                running -= 1

                if let (chunk, sizesByPath) = result {
                    for job in chunk {
                        if Task.isCancelled {
                            group.cancelAll()
                            return
                        }
                        let pathKey = job.path.standardizedFileURL.path
                        let size = sizesByPath[pathKey] ?? 0
                        let modified = FolderSizing.contentModificationDate(at: job.path)
                        continuation.yield(.sizeResolved(path: pathKey, sizeBytes: size, lastModified: modified))
                    }
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
        // iPhone/iPad backups (`MobileSync/Backup`) are intentionally excluded:
        // they are non-recoverable user data and must never be offered for
        // cleanup. They are also absent from the DeletionSafetyPolicy allowlist.
        [
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
}
