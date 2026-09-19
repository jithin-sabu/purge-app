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
        let bundleURLs = discoverAppBundleURLs()
        let runningIDs = runningBundleIDs()

        // Yield as soon as the bundle is identified. Spotlight's indexed size is
        // a cheap first figure so the list can paint without waiting on `du`;
        // `PurgeStore` walks each bundle afterwards and replaces the number.
        for bundleURL in bundleURLs {
            if Task.isCancelled { break }
            let bundle = Bundle(url: bundleURL)
            let bundleID = bundle?.bundleIdentifier
            guard !AppUninstallScanPolicy.isProtectedApp(bundleURL: bundleURL, bundleID: bundleID) else {
                continue
            }
            let name = displayName(for: bundleURL, bundle: bundle)
            let size = InstalledAppBundleSizing.spotlightLogicalSize(at: bundleURL) ?? 0
            let isRunning = bundleID.map { runningIDs.contains($0) } ?? false

            continuation.yield(
                InstalledApp(
                    name: name,
                    bundleURL: bundleURL,
                    bundleID: bundleID,
                    bundleSizeBytes: size,
                    isRunning: isRunning,
                    dateAdded: installDate(for: bundleURL)
                )
            )
        }
        continuation.finish()
    }

    /// Top-level `.app` bundles in each app root, plus those one folder deep
    /// (vendors that group their apps, e.g. `/Applications/Utilities/…`). Deeper
    /// nesting is not followed: it is rare for real apps and risks descending into
    /// bundle internals.
    private static func discoverAppBundleURLs() -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [URL] = []

        func consider(_ url: URL) {
            guard url.pathExtension == "app" else { return }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(url)
        }

        for root in AppUninstallScanPolicy.installedAppRoots() {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if entry.pathExtension == "app" {
                    consider(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    // One level down only.
                    let nested = (try? fm.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    for child in nested { consider(child) }
                }
            }
        }
        return result
    }

    private static func displayName(for bundleURL: URL, bundle: Bundle?) -> String {
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

    /// Closest proxy for when the app was installed: the bundle's creation date on
    /// this volume, falling back to its content modification date.
    private static func installDate(for bundleURL: URL) -> Date {
        let values = try? bundleURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }

    // MARK: Leftovers for a chosen app

    /// Streams the chosen app's bundle plus every leftover matched to it. Sizes
    /// are resolved in one pass before emitting, so the review list is complete
    /// and sortable when it appears.
    func leftoverStream(for app: InstalledApp) -> AsyncStream<UninstallItem> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                Self.runLeftoverScan(for: app, continuation: continuation)
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
        continuation: AsyncStream<UninstallItem>.Continuation
    ) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
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
                guard AppUninstallScanPolicy.isEligibleForUninstallDeletion(entry) else { continue }
                seen.insert(key)
                matches.append(Match(url: entry, category: root.category, reason: reason))
            }
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
                    // want to keep.
                    isSelected: true
                )
            )
        }
        continuation.finish()
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
}
