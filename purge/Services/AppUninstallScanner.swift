import AppKit
import CoreServices
import Foundation

/// Discovers installed apps and, for a chosen app, every file it left behind.
///
/// `nonisolated` is load-bearing for the same reason as the other scanners (see
/// the note on `CacheScanner`): under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// this type would be implicitly main-actor isolated and the `Task.detached`
/// below would hop straight back to the UI thread, running the directory walks
/// and `du` sizing there.
nonisolated final class AppUninstallScanner {

    /// Where the leftover scan looks for the user's Library. Tests hand in a
    /// temporary home so they never write to the user's own (#171).
    private let home: URL
    /// The hidden home folders an app is known to write (#228). The shipped
    /// catalog in the app; tests hand in a small one.
    private let catalog: AppDotFolderCatalog

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        catalog: AppDotFolderCatalog = .shared
    ) {
        self.home = home
        self.catalog = catalog
    }

    // MARK: Installed apps

    /// Streams the apps the uninstaller can act on. Bundles under `/System` and
    /// Purge itself are never emitted.
    func installedAppsStream() -> AsyncStream<InstalledApp> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                Self.runInstalledAppsScan(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func runInstalledAppsScan(continuation: AsyncStream<InstalledApp>.Continuation) {
        let apps = discoverInstalledApps()
        let runningIDs = runningBundleIDs()

        // Yield as soon as the bundle is identified. Spotlight's indexed size is
        // a cheap first figure so the list can paint without waiting on `du`;
        // `PurgeStore` walks each bundle afterwards and replaces the number.
        for app in apps {
            if Task.isCancelled { break }
            let size = InstalledAppBundleSizing.spotlightLogicalSize(at: app.bundleURL) ?? 0
            let isRunning = app.bundleID.map { runningIDs.contains($0) } ?? false
            continuation.yield(
                InstalledApp(
                    name: app.name,
                    bundleURL: app.bundleURL,
                    bundleID: app.bundleID,
                    bundleSizeBytes: size,
                    isRunning: isRunning,
                    lastOpened: InstalledAppBundleSizing.spotlightLastOpened(at: app.bundleURL)
                )
            )
        }
        continuation.finish()
    }

    /// An app the uninstaller can act on, found but not yet measured.
    struct DiscoveredApp: Sendable {
        let name: String
        let bundleURL: URL
        let bundleID: String?
    }

    /// The uninstaller's app index: every app it can act on, with no sizing.
    /// Shared with the App Intents app picker, so Spotlight offers exactly the
    /// apps the uninstaller lists. Reading the app folders needs no Full Disk
    /// Access.
    static func discoverInstalledApps() -> [DiscoveredApp] {
        discoverAppBundleURLs().compactMap { bundleURL in
            let bundle = Bundle(url: bundleURL)
            let bundleID = bundle?.bundleIdentifier
            guard !AppUninstallScanPolicy.isProtectedApp(bundleURL: bundleURL, bundleID: bundleID) else {
                return nil
            }
            return DiscoveredApp(
                name: displayName(for: bundleURL, bundle: bundle),
                bundleURL: bundleURL,
                bundleID: bundleID
            )
        }
    }

    /// `.app` bundles in each app root at any depth (vendors that group their
    /// apps, e.g. `/Applications/Utilities/…` or
    /// `/Applications/Autodesk/AutoCAD 2026/…`). `AppBundleReach` owns the
    /// reach, so the delete gate accepts exactly what is listed here.
    private static func discoverAppBundleURLs() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for root in AppUninstallScanPolicy.installedAppRoots() {
            for url in AppBundleReach.appBundleURLs(in: root) ?? [] {
                let key = url.standardizedFileURL.path
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(url)
            }
        }
        return result
    }

    /// Also read by `OrphanLeftoverScanPolicy.makeInstalledAppIndex`, so the
    /// Leftovers scan knows installed apps by the same names the uninstaller
    /// matches with.
    static func displayName(for bundleURL: URL, bundle: Bundle?) -> String {
        if let display = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !display.isEmpty {
            return display
        }
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        // `.deletingPathExtension().lastPathComponent` rather than
        // `FileManager.displayName`, which localizes and can append " (Deutsch)".
        return bundleURL.deletingPathExtension().lastPathComponent
    }

    private static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }

    // MARK: Leftovers for a chosen app

    /// Streams the chosen app's bundle plus every leftover matched to it. Sizes
    /// are resolved in one pass before emitting, so the review list is complete
    /// and sortable when it appears.
    func leftoverStream(for app: InstalledApp) -> AsyncStream<UninstallItem> {
        AsyncStream { [home, catalog] continuation in
            let task = Task.detached(priority: .userInitiated) {
                Self.runLeftoverScan(for: app, home: home, catalog: catalog, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Match {
        let url: URL
        let category: UninstallCategory
        let reason: MatchReason
    }

    private static func runLeftoverScan(
        for app: InstalledApp,
        home: URL,
        catalog: AppDotFolderCatalog,
        continuation: AsyncStream<UninstallItem>.Continuation
    ) {
        let fm = FileManager.default
        var matches: [Match] = []
        var seen = Set<String>()

        // The bundle itself, first.
        let bundleKey = app.bundleURL.standardizedFileURL.path
        seen.insert(bundleKey)
        matches.append(Match(url: app.bundleURL, category: .bundle, reason: .appBundle))

        for root in AppUninstallScanPolicy.leftoverSearchRoots(home: home) {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            guard let entries = try? fm.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let name = entry.lastPathComponent
                guard let reason = AppUninstallScanPolicy.matchReason(
                    forLeftoverName: name,
                    category: root.category,
                    app: app
                ) else { continue }
                let key = entry.standardizedFileURL.path
                guard !seen.contains(key) else { continue }
                // Defend in depth: only offer what the delete gate would accept.
                guard AppUninstallScanPolicy.isEligibleForUninstallDeletion(entry, home: home) else { continue }
                seen.insert(key)
                matches.append(Match(url: entry, category: root.category, reason: reason))
            }
        }

        // The hidden home folders the catalog names for this app (#228): a real
        // directory at exactly the listed path, never a parent such as
        // `~/.gemini`, never anything inside. The gate accepts only what the
        // catalog names, so this is checked the same way as the Library rows.
        for url in catalogFolders(for: app, home: home, catalog: catalog) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            guard AppUninstallScanPolicy.isEligibleForUninstallDeletion(
                url, home: home, dotFolderCatalog: catalog
            ) else { continue }
            seen.insert(key)
            matches.append(Match(url: url, category: .homeFolderData, reason: .dotFolderCatalog))
        }

        let sizes = FolderSizing.directorySizes(at: matches.map(\.url))

        for match in matches {
            if Task.isCancelled { break }
            let size = sizes[match.url.standardizedFileURL.path] ?? 0
            let safety = AppUninstallScanPolicy.safetyInfo(
                for: match.reason,
                category: match.category,
                url: match.url,
                appName: app.name
            )
            continuation.yield(
                UninstallItem(
                    path: match.url,
                    sizeBytes: size,
                    category: match.category,
                    safetyInfo: safety,
                    matchReason: match.reason,
                    // Uninstalling an app means taking its files with it, so every
                    // matched item starts checked. The user unticks anything they
                    // want to keep. A catalog dot folder is the exception: it holds
                    // settings and extensions, not a cache, so it starts unticked
                    // and the user opts in (#228).
                    isSelected: match.category != .homeFolderData
                )
            )
        }
        continuation.finish()
    }

    /// The catalog folders of `app` that exist as directories. A missing folder,
    /// a file, or a symbolic link in its place is left out, as in the Leftovers
    /// scan (`OrphanLeftoverScanPolicy.dotFolderCandidates`).
    static func catalogFolders(
        for app: InstalledApp,
        home: URL,
        catalog: AppDotFolderCatalog
    ) -> [URL] {
        guard let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty else { return [] }
        var result: [URL] = []
        for entry in catalog.entries where entry.bundleID.lowercased() == bundleID {
            for folder in entry.folders {
                guard let url = catalog.url(for: folder, home: home) else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                result.append(url)
            }
        }
        return result
    }
}

/// Fast first-pass bundle size from Spotlight's index (`kMDItemLogicalSize`).
/// Missing, unindexed, or zero values are treated as unknown so the store can
/// follow up with `du`.
enum InstalledAppBundleSizing {
    nonisolated static func spotlightLogicalSize(at url: URL) -> Int64? {
        let path = url.standardizedFileURL.path as CFString
        guard let item = MDItemCreate(nil, path) else { return nil }
        guard let raw = MDItemCopyAttribute(item, "kMDItemLogicalSize" as CFString) else {
            return nil
        }
        let bytes: Int64
        if let value = raw as? Int64 {
            bytes = value
        } else if let number = raw as? NSNumber {
            bytes = number.int64Value
        } else {
            return nil
        }
        return bytes > 0 ? bytes : nil
    }

    /// When the user last opened this app, according to Spotlight. Nil when the
    /// index has no last-used date — common for apps that were never launched,
    /// or when Spotlight has not indexed the volume. Callers still sort those
    /// apps; they just cannot show a day.
    nonisolated static func spotlightLastOpened(at url: URL) -> Date? {
        let path = url.standardizedFileURL.path as CFString
        guard let item = MDItemCreate(nil, path) else { return nil }
        guard let raw = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return raw as? Date
    }
}
