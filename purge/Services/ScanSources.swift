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
    /// Runs a Large Files, apps or leftovers step for the queue. Nil runs the real scan.
    var fullAccessStep: ((ScanStep, _ forced: Bool) async -> Void)?

    static func live(cacheScanner: CacheScanner, devScanner: DevScanner) -> ScanSources {
        ScanSources(
            fullDiskAccess: { PermissionChecker().hasFullDiskAccess() },
            general: { cacheScanner.scanGeneralStream(access: $0) },
            developer: { devScanner.scanDevToolsStream(access: $0) },
            projects: { devScanner.discoverProjectsStream(access: $0) },
            fullAccessStep: nil
        )
    }
}
