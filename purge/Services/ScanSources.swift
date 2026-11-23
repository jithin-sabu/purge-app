import Foundation

/// Where the store's scans get their access and their results.
///
/// The app always uses `live`. Tests pass their own so the scan queue can be driven
/// end to end, with scans that stay open until the test lets them finish, without
/// walking this Mac's disk or asking macOS about access.
struct ScanSources {
    /// Whether Purge has Full Disk Access right now.
    var fullDiskAccess: () -> Bool
    /// The App Caches scan.
    var general: (ScanAccess) -> AsyncStream<CacheScanEvent>
    /// The Dev Tools scan, before project discovery.
    var developer: (ScanAccess) -> AsyncStream<DeveloperScanEvent>
    /// Project discovery, which carries Dev Tools on after `developer` ends.
    var projects: (ScanAccess) -> AsyncStream<DeveloperScanEvent>
    /// The Large Files walk, with its size and age thresholds. Ends with `.finished`.
    var largeFiles: (_ minBytes: Int64, _ staleDays: Int) -> AsyncStream<LargeFileScanEvent>
    /// The AI model rows Large Files lists ahead of and beside the walk (#157).
    var aiModels: (_ minBytes: Int64, _ staleDays: Int, ScanAccess, AIModelScanner.Pass) -> AsyncStream<LargeFile>
    /// Runs a Large Files, apps or leftovers step for the queue. Nil runs the real scan.
    var fullAccessStep: ((ScanStep, _ forced: Bool) async -> Void)?
    /// The Everything else walk (#220), with the access it may read with.
    var everythingElse: (ScanAccess) -> AsyncStream<EverythingElseMeasureEvent>
    /// One folder opened on the Everything else map (#437): the folders inside
    /// it, sized. Nil when it can't be read or the caller was cancelled.
    var everythingElseFolder: (URL, EverythingElseGroup, ScanAccess, @escaping @Sendable (Double) -> Void) async -> EverythingElseFolderContents?
    /// The uninstaller's Command-line tools scan (#225).
    var commandLineTools: () async -> CommandLineToolScanResult
    /// Git status for the rows a scan found, keyed by standardized path. A clean
    /// asks `GitStatusChecker` again for each path before it moves anything, and
    /// never reads this.
    var gitStatuses: ([URL]) async -> [String: GitWorktreeStatus]
    /// Runs before a full scan starts its parts side by side. The live one
    /// lists every app container's caches folder alone first (see
    /// `PurgeStore.runFullScan`); tests leave it nil or pass a hook, and read
    /// none of the user's folders.
    var prepareFullScan: ((ScanAccess) async -> Void)? = nil

    static func live(
        cacheScanner: CacheScanner,
        devScanner: DevScanner,
        gitChecker: GitStatusChecker,
        largeFileScanner: LargeFileScanner,
        aiModelScanner: AIModelScanner,
        everythingElseMeasurer: EverythingElseMeasurer
    ) -> ScanSources {
        ScanSources(
            fullDiskAccess: { PermissionChecker().hasFullDiskAccess() },
            general: { cacheScanner.scanGeneralStream(access: $0) },
            developer: { devScanner.scanDevToolsStream(access: $0) },
            projects: { devScanner.discoverProjectsStream(access: $0) },
            largeFiles: { largeFileScanner.scanEvents(minBytes: $0, staleDays: $1) },
            aiModels: { aiModelScanner.scanStream(minBytes: $0, staleDays: $1, access: $2, pass: $3) },
            fullAccessStep: nil,
            everythingElse: { everythingElseMeasurer.measureStream(access: $0) },
            everythingElseFolder: { url, group, access, progress in
                let home = FileManager.default.homeDirectoryForCurrentUser
                let task = Task.detached(priority: .userInitiated) {
                    EverythingElseFolderSizer.contents(of: url, group: group, access: access, home: home, progress: progress)
                }
                return await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            },
            commandLineTools: { await CommandLineToolScanner().scan() },
            gitStatuses: { await gitChecker.cleanupStatuses(for: $0) },
            prepareFullScan: { access in
                guard access == .full else { return }
                await Task.detached(priority: .userInitiated) {
                    CacheDiscoveryPaths.touchContainerCaches(home: FileManager.default.homeDirectoryForCurrentUser)
                }.value
            }
        )
    }
}
