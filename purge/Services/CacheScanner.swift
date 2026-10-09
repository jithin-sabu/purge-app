import AppKit
import Foundation

enum CacheScanEvent {
    case status(String)
    case found(CacheItem)
    case sizeResolved(path: String, sizeBytes: Int64, lastModified: Date)
}

/// `nonisolated` is load-bearing — see the note on `LargeFileScanner`. Under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` this type would be implicitly
/// main-actor isolated, so the `Task.detached` in `scanGeneralStream` hopped straight
/// back and ran the whole cache discovery + sizing pass on the UI thread. A probe
/// confirmed `runGeneralScan` executing with `Thread.isMainThread == true`.
nonisolated final class CacheScanner {
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

    func scanGeneralStream(access: ScanAccess) -> AsyncStream<CacheScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runGeneralScan(access: access, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func calculateFolderSize(at url: URL) -> Int64 {
        FolderSizing.directoryByteSize(at: url)
    }

    private func runGeneralScan(
        access: ScanAccess,
        continuation: AsyncStream<CacheScanEvent>.Continuation
    ) async {
        let discoveryStart = Date()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cachesURL = home.appendingPathComponent("Library/Caches", isDirectory: true)
        var sizeJobs: [SizeJob] = []
        // Seed with paths the Dev Tools scan owns so they are skipped here instead of
        // appearing under App Caches and later being pulled out when the dev scan runs.
        var collectedPaths = DevScanner.claimedGlobalCachePaths()

        continuation.yield(.status(String(localized: "Scanning App Caches...")))
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
                access: access,
                collectedPaths: &collectedPaths
            ) else { continue }
            continuation.yield(.found(item))
            sizeJobs.append(SizeJob(path: directory.standardizedFileURL))
        }

        // Application Support is readable without Full Disk Access, and it is where
        // Chromium browsers, Electron apps and Adobe keep their biggest caches, so
        // it belongs in the limited scan. The sensitive roots under it are already
        // skipped by `excludedApplicationSupportRoots`.
        continuation.yield(.status(String(localized: "Scanning Application Support caches...")))
        let appSupportItems = applicationSupportCacheItems(home: home, access: access, collectedPaths: &collectedPaths)
        for item in appSupportItems {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.found(item))
            sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
        }

        let knownItems = knownCacheItems(home: home, access: access, collectedPaths: &collectedPaths)
        for item in knownItems {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.found(item))
            sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
        }

        let adobeItems = adobeMediaCacheItems(home: home, access: access, collectedPaths: &collectedPaths)
        for item in adobeItems {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.found(item))
            sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
        }

        // Everything below lives in other apps' containers. Without Full Disk Access
        // macOS asks the user about each one, so a limited scan leaves them alone.
        if access == .full {
            for url in CacheDiscoveryPaths.unfinishedDownloadURLs(home: home) {
                guard let item = cacheItemAtDiscoveredPath(
                    url,
                    headline: url.lastPathComponent,
                    folderName: CacheDiscoveryPaths.unfinishedDownloadsKey,
                    access: access,
                    collectedPaths: &collectedPaths
                ) else { continue }
                continuation.yield(.found(item))
                sizeJobs.append(SizeJob(path: url))
            }

            let telegramItems = telegramMediaCacheItems(home: home, access: access, collectedPaths: &collectedPaths)
            for item in telegramItems {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                continuation.yield(.found(item))
                sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
            }

            continuation.yield(.status(String(localized: "Scanning sandboxed app caches...")))
            let containerItems = allContainerCacheItems(home: home, access: access, collectedPaths: &collectedPaths)
            for item in containerItems {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                continuation.yield(.found(item))
                sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
            }
        }

        continuation.yield(.status(String(localized: "Scanning browser app bundles...")))
        let staleFrameworkItems = staleChromiumFrameworkItems(access: access, collectedPaths: &collectedPaths)
        for item in staleFrameworkItems {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.found(item))
            sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
        }

        continuation.yield(.status(String(localized: "Scanning System Junk...")))
        for item in applicationLogItems(home: home, access: access, collectedPaths: &collectedPaths) {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.found(item))
            sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
        }
        for item in macOSInstallerItems(access: access, collectedPaths: &collectedPaths) {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.found(item))
            sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
        }
        for location in systemJunkLocations(home: home) {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            let displayName = location.displayName
            guard ProtectedLocations.isReadable(location.url, access: access) else { continue }
            let url = location.url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard DeletionSafetyPolicy.isOfferedForCleanup(url) else { continue }
            guard !ExcludedPathsStore.isExcluded(url) else { continue }
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

        continuation.yield(.status(String(localized: "Calculating sizes...")))
        let sizingStart = Date()
        await runSizeJobs(sizeJobs, access: access, continuation: continuation)
        ScanPhaseTiming.finish(
            "app cache sizing",
            since: sizingStart,
            detail: "\(sizeJobs.count) du batch paths"
        )
        continuation.finish()
    }

    private func cacheItem(
        at directory: URL,
        access: ScanAccess,
        collectedPaths: inout Set<String>
    ) -> CacheItem? {
        // A cache folder can be a symlink into Documents. Checked on the link
        // alone, before the resource values and sizing that would follow it.
        guard ProtectedLocations.isReadable(directory, access: access) else { return nil }
        do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { return nil }

            let bundleID = directory.lastPathComponent
            guard !excludedFromGeneralScan.contains(bundleID) else { return nil }
            // The quick offline check runs in the policy; this is the thorough one.
            if bundleID == "com.spotify.client",
               DeletionSafetyPolicy.spotifyHasOfflineTrackFiles(home: DeletionSafetyPolicy.cachedHomePath) {
                return nil
            }

            let pathKey = directory.standardizedFileURL.path
            guard DeletionSafetyPolicy.isOfferedForCleanup(directory) else { return nil }
            guard !ExcludedPathsStore.isExcluded(directory) else { return nil }
            guard !collectedPaths.contains(pathKey) else { return nil }
            collectedPaths.insert(pathKey)

            let modified = values.contentModificationDate ?? .distantPast
            let fallbackAppName = appDisplayName(forBundleID: bundleID) ?? bundleID
            let classificationName = CacheDiscoveryPaths.isElectronUpdaterCache(directory)
                ? CacheDiscoveryPaths.electronUpdaterKey
                : bundleID
            let safetyInfo = ExplanationResolver.initialSafetyForCacheFolder(
                folderName: classificationName,
                friendlyHeadline: fallbackAppName,
                path: directory
            )

            return CacheItem(
                definitionKey: ExplanationDatabase.definitionKey(forFolderName: classificationName),
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
        access: ScanAccess,
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
            guard ProtectedLocations.isReadable(appDir, access: access) else { continue }
            guard (try? appDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let appFolderName = appDir.lastPathComponent
            guard !CacheDiscoveryPaths.excludedApplicationSupportRoots.contains(appFolderName) else {
                continue
            }

            for cacheURL in CacheDiscoveryPaths.applicationSupportCacheURLs(in: appDir, access: access) {
                guard let item = cacheItemAtDiscoveredPath(
                    cacheURL,
                    headline: applicationSupportHeadline(appFolderName: appFolderName, cacheURL: cacheURL),
                    folderName: appFolderName,
                    access: access,
                    collectedPaths: &collectedPaths
                ) else { continue }
                items.append(item)
            }
        }
        return items
    }

    private func knownCacheItems(
        home: URL,
        access: ScanAccess,
        collectedPaths: inout Set<String>
    ) -> [CacheItem] {
        var items: [CacheItem] = []
        for entry in CacheDiscoveryPaths.knownCacheEntries where access == .full || !entry.needsFullAccess {
            let url = home.appendingPathComponent(entry.relative, isDirectory: true)
            // Before `fileExists`, which follows a link into a locked folder.
            guard ProtectedLocations.isReadable(url, access: access) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let item = cacheItemAtDiscoveredPath(
                url,
                headline: entry.key,
                folderName: entry.key,
                access: access,
                collectedPaths: &collectedPaths
            ) else { continue }
            items.append(item)
        }
        return items
    }

    private func adobeMediaCacheItems(
        home: URL,
        access: ScanAccess,
        collectedPaths: inout Set<String>
    ) -> [CacheItem] {
        var items: [CacheItem] = []
        for entry in CacheDiscoveryPaths.adobeMediaCacheURLs(home: home, access: access) {
            guard let item = cacheItemAtDiscoveredPath(
                entry.url,
                headline: entry.headline,
                folderName: entry.key,
                access: access,
                collectedPaths: &collectedPaths
            ) else { continue }
            items.append(item)
        }
        return items
    }

    private func telegramMediaCacheItems(
        home: URL,
        access: ScanAccess,
        collectedPaths: inout Set<String>
    ) -> [CacheItem] {
        var items: [CacheItem] = []
        for entry in CacheDiscoveryPaths.telegramMediaCacheURLs(home: home) {
            guard let item = cacheItemAtDiscoveredPath(
                entry.url,
                headline: entry.headline,
                folderName: entry.key,
                access: access,
                collectedPaths: &collectedPaths
            ) else { continue }
            items.append(item)
        }
        return items
    }

    private func allContainerCacheItems(
        home: URL,
        access: ScanAccess,
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
                access: access,
                collectedPaths: &collectedPaths
            ) else { continue }
            items.append(item)
        }
        return items
    }

    private func staleChromiumFrameworkItems(access: ScanAccess, collectedPaths: inout Set<String>) -> [CacheItem] {
        var items: [CacheItem] = []
        for frameworkVersionURL in CacheDiscoveryPaths.staleChromiumFrameworkVersionURLs()
        where ProtectedLocations.isReadable(frameworkVersionURL, access: access) {
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
            guard !ExcludedPathsStore.isExcluded(frameworkVersionURL) else { continue }
            guard !collectedPaths.contains(pathKey) else { continue }
            collectedPaths.insert(pathKey)

            let safety = SafetyInfo(
                level: .medium,
                headline: headline,
                explanation: String(localized: "A leftover Chromium framework inside \(appName) that no running process is using. Quit and relaunch \(appName) before an older version still loaded by the running browser can be cleaned; those copies stay hidden until then. \(appName) also deletes leftover versions itself on relaunch."),
                recoverySteps: String(localized: "Quit and relaunch \(appName). If it still fails to open, reinstall it from the vendor."),
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
        access: ScanAccess,
        collectedPaths: inout Set<String>
    ) -> CacheItem? {
        // Before `standardizedFileURL` and the modification date, both of which
        // follow a symlink to its target.
        guard ProtectedLocations.isReadable(url, access: access) else { return nil }
        let pathKey = url.standardizedFileURL.path
        guard DeletionSafetyPolicy.isOfferedForCleanup(url) else { return nil }
        guard !ExcludedPathsStore.isExcluded(url) else { return nil }
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

    /// One row location per item in `~/Library/Logs`, except Crash Reports, which
    /// has its own row. Offering `~/Library/Logs` as one folder sized and cleaned
    /// `DiagnosticReports` twice: once here and once as Crash Reports. The items
    /// share the `Logs` definition, so they still show as one Application Logs row.
    private func applicationLogItems(
        home: URL,
        access: ScanAccess,
        collectedPaths: inout Set<String>
    ) -> [CacheItem] {
        let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)
        guard ProtectedLocations.isReadable(logs, access: access),
              let children = try? FileManager.default.contentsOfDirectory(
                at: logs,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return [] }
        var items: [CacheItem] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where child.lastPathComponent != Self.crashReportsFolderName {
            guard let item = cacheItemAtDiscoveredPath(
                child,
                headline: String(localized: "Application Logs"),
                folderName: "Logs",
                access: access,
                collectedPaths: &collectedPaths
            ) else { continue }
            items.append(item)
        }
        return items
    }

    static let crashReportsFolderName = "DiagnosticReports"

    /// Full macOS installers in /Applications (`Install macOS Sequoia.app` and so on),
    /// confirmed by bundle ID so an app that merely shares the name is never listed.
    private func macOSInstallerItems(access: ScanAccess, collectedPaths: inout Set<String>) -> [CacheItem] {
        CacheDiscoveryPaths.macOSInstallerURLs().compactMap { url in
            cacheItemAtDiscoveredPath(
                url,
                headline: url.deletingPathExtension().lastPathComponent,
                folderName: CacheDiscoveryPaths.macOSInstallerKey,
                access: access,
                collectedPaths: &collectedPaths
            )
        }
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
        access: ScanAccess,
        continuation: AsyncStream<CacheScanEvent>.Continuation
    ) async {
        // Discovery already dropped locked paths; this keeps `du` honest if a
        // new discovery path forgets to.
        let jobs = jobs.filter { ProtectedLocations.isReadable($0.path, access: access) }
        guard !jobs.isEmpty else { return }

        let chunkSize = FolderSizing.duChunkSize
        // Matches the process-wide `du` cap. Each task takes one limiter permit
        // inside `directorySizesForChunk`, so this is the fan-out, not a second
        // multiplier on top of `directorySizes` callers.
        let maxConcurrent = FolderSizing.maxConcurrentDuChunks
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
        // Application Logs is listed child by child in `applicationLogItems`, so that
        // the Crash Reports folder inside it is never sized or cleaned twice.
        [
            (
                "Crash Reports",
                home.appendingPathComponent(
                    "Library/Logs/DiagnosticReports",
                    isDirectory: true
                )
            ),
            (
                "Font Cache",
                home.appendingPathComponent("Library/Caches/com.apple.ATS", isDirectory: true)
            )
        ]
    }
}
