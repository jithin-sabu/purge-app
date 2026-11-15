import AppKit
import Foundation

enum CacheScanEvent {
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

    private func runGeneralScan(
        access: ScanAccess,
        continuation: AsyncStream<CacheScanEvent>.Continuation
    ) async {
        let discoveryStart = Date()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cachesURL = home.appendingPathComponent("Library/Caches", isDirectory: true)
        // Seed with paths the Dev Tools scan owns so they are skipped here instead of
        // appearing under App Caches and later being pulled out when the dev scan runs.
        var collectedPaths = DevScanner.claimedGlobalCachePaths()

        // Listed before the passes and the sizing below start reading, one
        // container at a time (see `ContainerAccessGate`).
        let containerCacheURLs = access == .full ? CacheDiscoveryPaths.containerCacheURLs(home: home) : []

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

        var cachesFolderJobs: [SizeJob] = []
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
            cachesFolderJobs.append(SizeJob(path: directory.standardizedFileURL))
        }

        // `~/Library/Caches` holds most rows, so its folders are sized while the
        // passes below run. Their sizes go out only after every pass has sent
        // its rows: a row is published once it has a size, and its safety
        // level is then pinned, so a row from a later pass that joins it under
        // the same key, at a more cautious level, must be there first.
        let heldSizes = HeldScanEvents(continuation)
        async let cachesFolderSizing: Void = runSizeJobs(cachesFolderJobs, access: access, send: heldSizes.send)

        // Each pass reads its own folders, so they run side by side. A path two
        // passes find stays with the earlier pass, as when they ran one after
        // another: each pass starts from the paths claimed so far, and the merge
        // below drops what an earlier pass already took.
        let claimedBeforePasses = collectedPaths
        let passes = discoveryPasses(home: home, access: access, containerCacheURLs: containerCacheURLs)
        let passItems = ConcurrentMap.values(passes, width: passes.count, outer: true) { pass -> [CacheItem] in
            var claimed = claimedBeforePasses
            return pass.find(&claimed)
        }
        var sizeJobs: [SizeJob] = []
        for (pass, items) in zip(passes, passItems) {
            for item in items {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                if pass.claimsPaths {
                    guard collectedPaths.insert(item.path.standardizedFileURL.path).inserted else { continue }
                }
                continuation.yield(.found(item))
                sizeJobs.append(contentsOf: item.locations.map { SizeJob(path: $0.path.standardizedFileURL) })
            }
        }
        heldSizes.release()

        ScanPhaseTiming.finish(
            "app cache discovery",
            since: discoveryStart,
            detail: "\(cachesFolderJobs.count + sizeJobs.count) cache locations queued, \(collectedPaths.count) unique paths"
        )

        let sizingStart = Date()
        await runSizeJobs(sizeJobs, access: access, send: { continuation.yield($0) })
        await cachesFolderSizing
        ScanPhaseTiming.finish(
            "app cache sizing",
            since: sizingStart,
            detail: "\(cachesFolderJobs.count + sizeJobs.count) folders"
        )
        continuation.finish()
    }

    /// One discovery pass after `~/Library/Caches`. `claimsPaths` is false only
    /// for the system junk folders, which never took part in the dedupe.
    private struct DiscoveryPass {
        let claimsPaths: Bool
        let find: (inout Set<String>) -> [CacheItem]
    }

    /// The passes in the order they claim paths.
    private func discoveryPasses(home: URL, access: ScanAccess, containerCacheURLs: [URL]) -> [DiscoveryPass] {
        var passes: [DiscoveryPass] = [
            // Application Support is readable without Full Disk Access, and it is where
            // Chromium browsers, Electron apps and Adobe keep their biggest caches, so
            // it belongs in the limited scan. The sensitive roots under it are already
            // skipped by `excludedApplicationSupportRoots`.
            DiscoveryPass(claimsPaths: true) { self.applicationSupportCacheItems(home: home, access: access, collectedPaths: &$0) },
            DiscoveryPass(claimsPaths: true) { self.knownCacheItems(home: home, access: access, collectedPaths: &$0) },
            DiscoveryPass(claimsPaths: true) { self.adobeMediaCacheItems(home: home, access: access, collectedPaths: &$0) },
        ]
        // Everything in these lives in other apps' containers. Without Full Disk
        // Access macOS asks the user about each one, so a limited scan leaves them alone.
        if access == .full {
            passes += [
                DiscoveryPass(claimsPaths: true) { self.unfinishedDownloadItems(home: home, access: access, collectedPaths: &$0) },
                DiscoveryPass(claimsPaths: true) { self.telegramMediaCacheItems(home: home, access: access, collectedPaths: &$0) },
                DiscoveryPass(claimsPaths: true) { self.allContainerCacheItems(containerCacheURLs, access: access, collectedPaths: &$0) },
            ]
        }
        passes += [
            DiscoveryPass(claimsPaths: true) { self.staleChromiumFrameworkItems(access: access, collectedPaths: &$0) },
            DiscoveryPass(claimsPaths: true) { self.applicationLogItems(home: home, access: access, collectedPaths: &$0) },
            DiscoveryPass(claimsPaths: true) { self.macOSInstallerItems(access: access, collectedPaths: &$0) },
            DiscoveryPass(claimsPaths: true) { self.macOSInstallLeftoverItems(access: access, collectedPaths: &$0) },
            DiscoveryPass(claimsPaths: false) { _ in self.systemJunkItems(home: home, access: access) },
        ]
        return passes
    }

    private func unfinishedDownloadItems(home: URL, access: ScanAccess, collectedPaths: inout Set<String>) -> [CacheItem] {
        CacheDiscoveryPaths.unfinishedDownloadURLs(home: home).compactMap { url in
            cacheItemAtDiscoveredPath(
                url,
                headline: url.lastPathComponent,
                folderName: CacheDiscoveryPaths.unfinishedDownloadsKey,
                access: access,
                collectedPaths: &collectedPaths
            )
        }
    }

    private func systemJunkItems(home: URL, access: ScanAccess) -> [CacheItem] {
        systemJunkLocations(home: home).compactMap { location in
            let displayName = location.displayName
            guard ProtectedLocations.isReadable(location.url, access: access) else { return nil }
            let url = location.url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard DeletionSafetyPolicy.isOfferedForCleanup(url) else { return nil }
            guard !ExcludedPathsStore.isExcluded(url) else { return nil }
            let folderName = url.lastPathComponent
            let safetyInfo = ExplanationResolver.initialSafetyForCacheFolder(
                folderName: folderName,
                friendlyHeadline: displayName,
                path: url
            )
            return CacheItem(
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
        }
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

        // Each app's folder is read on its own, side by side; the paths are then
        // claimed in the order one pass after another would have claimed them.
        let prepared = ConcurrentMap.values(appDirs) { appDir -> [CacheItem?] in
            guard ProtectedLocations.isReadable(appDir, access: access) else { return [] }
            guard (try? appDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return []
            }
            let appFolderName = appDir.lastPathComponent
            guard !CacheDiscoveryPaths.excludedApplicationSupportRoots.contains(appFolderName) else {
                return []
            }

            // An app with an `explanations.json` entry groups under that entry. Any
            // other app gets a key of its own, so its cache folders share one row.
            let groupKey = ExplanationDatabase.definitionKey(forFolderName: appFolderName) == nil
                ? CacheDiscoveryPaths.applicationSupportGroupKey(appFolderName: appFolderName)
                : nil
            return CacheDiscoveryPaths.applicationSupportCacheURLs(in: appDir, access: access).map { cacheURL in
                let row = Self.applicationSupportRow(for: cacheURL, appFolderName: appFolderName, groupKey: groupKey)
                return discoveredItem(
                    cacheURL,
                    headline: row.headline,
                    folderName: appFolderName,
                    classificationName: row.classificationName,
                    groupKey: row.groupKey,
                    access: access
                )
            }
        }
        return claimInOrder(prepared.flatMap { $0 }, collectedPaths: &collectedPaths)
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
        _ containerCacheURLs: [URL],
        access: ScanAccess,
        collectedPaths: inout Set<String>
    ) -> [CacheItem] {
        // Built side by side, since naming each app asks Launch Services; the
        // folder checks go through `ContainerAccessGate`. Claimed in order.
        let prepared = ConcurrentMap.values(containerCacheURLs) { cacheURL -> CacheItem? in
            let bundleID = containerBundleID(from: cacheURL) ?? cacheURL.lastPathComponent
            let appName = appDisplayName(forBundleID: bundleID) ?? bundleID
            let subfolderName = cacheURL.lastPathComponent
            let isCachesRoot = subfolderName == "Caches"
            let folderName = isCachesRoot ? bundleID : subfolderName
            let headline = isCachesRoot ? "\(appName) Cache" : "\(appName) \(subfolderName)"
            // The checks read the folder, so one container at a time.
            return ContainerAccessGate.access(cacheURL.path) {
                discoveredItem(
                    cacheURL,
                    headline: headline,
                    folderName: folderName,
                    access: access
                )
            }
        }
        return claimInOrder(prepared, collectedPaths: &collectedPaths)
    }

    private func staleChromiumFrameworkItems(access: ScanAccess, collectedPaths: inout Set<String>) -> [CacheItem] {
        var items: [CacheItem] = []
        for frameworkVersionURL in CacheDiscoveryPaths.staleChromiumFrameworkVersionURLs()
        where ProtectedLocations.isReadable(frameworkVersionURL, access: access) {
            let appName = CacheDiscoveryPaths.chromiumBrowserAppName(forFrameworkVersion: frameworkVersionURL)
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
                explanation: String(localized: "An unused leftover Chromium framework in \(appName). Relaunch the browser to clean versions still loaded; relaunching also removes old ones."),
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
        classificationName: String? = nil,
        groupKey: String? = nil,
        access: ScanAccess,
        collectedPaths: inout Set<String>
    ) -> CacheItem? {
        claimInOrder(
            [discoveredItem(
                url,
                headline: headline,
                folderName: folderName,
                classificationName: classificationName,
                groupKey: groupKey,
                access: access
            )],
            collectedPaths: &collectedPaths
        ).first
    }

    /// The row for a discovered cache folder, or nil when it is not offered.
    /// Reads only, so passes can build rows side by side; `claimInOrder` then
    /// keeps the first row for each path.
    private func discoveredItem(
        _ url: URL,
        headline: String,
        folderName: String,
        classificationName: String? = nil,
        groupKey: String? = nil,
        access: ScanAccess
    ) -> CacheItem? {
        // The name the tier and row come from. The location keeps `folderName`,
        // which its label in the confirm sheets is read from.
        let classificationName = classificationName ?? folderName
        // Before `standardizedFileURL` and the modification date, both of which
        // follow a symlink to its target.
        guard ProtectedLocations.isReadable(url, access: access) else { return nil }
        guard DeletionSafetyPolicy.isOfferedForCleanup(url) else { return nil }
        guard !ExcludedPathsStore.isExcluded(url) else { return nil }

        let modified = FolderSizing.contentModificationDate(at: url)
        let safetyInfo = ExplanationResolver.initialSafetyForCacheFolder(
            folderName: classificationName,
            friendlyHeadline: headline,
            path: url
        )
        return CacheItem(
            definitionKey: groupKey ?? ExplanationDatabase.definitionKey(forFolderName: classificationName),
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

    /// Keeps each item whose path no earlier item claimed, in order, and claims it.
    private func claimInOrder(_ items: [CacheItem?], collectedPaths: inout Set<String>) -> [CacheItem] {
        items.compactMap { item in
            guard let item, collectedPaths.insert(item.path.standardizedFileURL.path).inserted else { return nil }
            return item
        }
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

    /// What a finished macOS update left in `macOS Install Data` (#127), one location
    /// per entry, shown as one row. Nothing is listed unless the folder and every
    /// entry are older than the installed system, so a waiting update never shows.
    /// Cleaning goes through the root helper; see `FileDeleter.deleteItems`.
    private func macOSInstallLeftoverItems(access: ScanAccess, collectedPaths: inout Set<String>) -> [CacheItem] {
        guard MacOSInstallLeftovers.isLeftover() else { return [] }
        return MacOSInstallLeftovers.entries().compactMap { url in
            cacheItemAtDiscoveredPath(
                url,
                headline: String(localized: "Leftover macOS update files"),
                folderName: CacheDiscoveryPaths.macOSInstallDataKey,
                access: access,
                collectedPaths: &collectedPaths
            )
        }
    }

    /// One name for every cache folder of an app, since they share a row.
    /// The row an Application Support cache folder is shown on.
    struct ApplicationSupportRow: Equatable {
        let headline: String
        /// The name the tier and row come from, when it is not the app folder.
        let classificationName: String?
        let groupKey: String?
    }

    /// Unsent crash reports from every app share one Check First row (#367),
    /// never the app's own row, whatever tier the app's entry has. Every other
    /// folder goes on its app's row.
    static func applicationSupportRow(for cacheURL: URL, appFolderName: String, groupKey: String?) -> ApplicationSupportRow {
        if CacheDiscoveryPaths.isCrashpadPendingFolder(cacheURL) {
            return ApplicationSupportRow(
                headline: CacheDiscoveryPaths.crashpadPendingKey,
                classificationName: CacheDiscoveryPaths.crashpadPendingKey,
                groupKey: nil
            )
        }
        return ApplicationSupportRow(
            headline: applicationSupportHeadline(appFolderName: appFolderName),
            classificationName: nil,
            groupKey: groupKey
        )
    }

    private static func applicationSupportHeadline(appFolderName: String) -> String {
        let displayApp = appFolderName
            .replacingOccurrences(of: "company.thebrowser.", with: "")
            .replacingOccurrences(of: "com.google.", with: "")
            .replacingOccurrences(of: "com.apple.", with: "")
        return "\(displayApp) Cache"
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
        send: @escaping (CacheScanEvent) -> Void
    ) async {
        // Discovery already dropped locked paths; this keeps `du` honest if a
        // new discovery path forgets to.
        let jobs = jobs.filter { ProtectedLocations.isReadable($0.path, access: access) }
        guard !jobs.isEmpty else { return }

        // Each folder is reported as soon as it is sized, so one big cache
        // folder holds up nothing else.
        let jobsByPath = Dictionary(jobs.map { ($0.path.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        _ = FolderSizing.walkedSizes(at: jobs.map(\.path)) { path, bytes in
            guard let job = jobsByPath[path] else { return }
            let modified = FolderSizing.contentModificationDate(at: job.path)
            send(.sizeResolved(path: path, sizeBytes: bytes ?? 0, lastModified: modified))
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
                String(localized: "Crash Reports"),
                home.appendingPathComponent(
                    "Library/Logs/DiagnosticReports",
                    isDirectory: true
                )
            )
        ]
    }
}

/// Scan events held back until `release()`, then sent in the order they came,
/// and every later one sent at once. `send` may be called from any thread.
nonisolated final class HeldScanEvents<Event>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Event]? = []
    private let deliver: (Event) -> Void

    init(_ continuation: AsyncStream<Event>.Continuation) {
        deliver = { continuation.yield($0) }
    }

    init(deliver: @escaping (Event) -> Void) {
        self.deliver = deliver
    }

    func send(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        if held != nil {
            held?.append(event)
        } else {
            deliver(event)
        }
    }

    /// Sends what was held, with the lock held so nothing sent meanwhile
    /// overtakes it.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        let events = held ?? []
        held = nil
        events.forEach(deliver)
    }
}

