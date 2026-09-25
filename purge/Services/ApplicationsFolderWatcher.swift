import CoreServices
import Foundation

/// Watches the app roots for bundles leaving them (issue #65).
///
/// A removed bundle can no longer say which app it was, so the watcher keeps an
/// index of every bundle's identifier and name, re-lists the roots when their
/// top level changes, and reports what dropped out. A bundle that landed in the
/// Trash is reported at once. Anything else waits through
/// `RemovedAppWatchPolicy.settleDelay`, so an updater can put the new copy back
/// before Purge offers to remove its support files.
///
/// Directory-level FSEvents rather than per-file: only entries appearing and
/// disappearing near the top of each root matter, and per-file events would
/// deliver every write inside every bundle during an update.
///
/// The stream holds an unretained pointer to the watcher, so the owner must call
/// `stop()` before letting it go.
final class ApplicationsFolderWatcher {

    /// A bundle that left and stayed gone, with what the caller needs to decide
    /// whether it was really removed.
    struct Departure {
        let app: InstalledApp
        let bundleStillExists: Bool
        /// Lowercased identifiers of every bundle in the app roots after the settle.
        let installedBundleIDs: Set<String>
    }

    var onDeparture: ((Departure) -> Void)?

    /// Every bundle currently in the app roots, keyed by standardized path.
    private(set) var apps: [String: InstalledApp] = [:]

    private let roots: [URL]
    private let rootPaths: [String]
    private var stream: FSEventStreamRef?
    private var rescanTask: Task<Void, Never>?
    private var settleTasks: [String: Task<Void, Never>] = [:]
    /// Bumped by `start()` and `stop()` so work from an earlier run never lands.
    private var generation = 0
    private var isStarted = false

    init(roots: [URL] = RemovedAppWatchPolicy.installedAppRoots()) {
        self.roots = roots
        rootPaths = roots.map(Self.eventPath(for:))
    }

    /// The form FSEvents reports a root in. `realpath` rather than
    /// `resolvingSymlinksInPath()`, which strips `/private` back off and so never
    /// matches what the stream delivers for a root under `/var` or `/tmp`.
    private static func eventPath(for root: URL) -> String {
        let standardized = root.standardizedFileURL.path
        guard let resolved = realpath(standardized, nil) else {
            return RemovedAppWatchPolicy.normalizedPath(standardized)
        }
        defer { free(resolved) }
        return RemovedAppWatchPolicy.normalizedPath(String(cString: resolved))
    }

    var installedApps: [InstalledApp] { Array(apps.values) }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        generation += 1
        let current = generation
        Task {
            // Index before listening: a removal reported against an empty index
            // could never be named.
            let snapshot = await Self.snapshotOffMain(roots: roots, reusing: [:])
            guard generation == current else { return }
            apps = snapshot
            openStream()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation += 1
        rescanTask?.cancel()
        rescanTask = nil
        settleTasks.values.forEach { $0.cancel() }
        settleTasks.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        apps = [:]
    }

    private func openStream() {
        let watched = rootPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !watched.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            applicationsFolderWatcherCallback,
            &context,
            watched as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // No coalescing delay. A one-second latency is what made a Trash drag
            // feel late next to a watcher that reports the moment the bundle moves.
            0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let mustRescanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
        )
        let mustRescan = flags.contains { $0 & mustRescanMask != 0 }
        let relevant = paths.contains {
            RemovedAppWatchPolicy.isRelevantChange(atPath: $0, roots: rootPaths)
        }
        guard mustRescan || relevant else { return }
        scheduleRescan()
    }

    /// Coalesces a burst of events (a Finder move reports source and destination
    /// separately) into one re-list.
    private func scheduleRescan() {
        rescanTask?.cancel()
        let current = generation
        rescanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, let self, self.generation == current else { return }
            let previous = self.apps
            let snapshot = await Self.snapshotOffMain(roots: self.roots, reusing: previous)
            guard !Task.isCancelled, self.generation == current else { return }
            self.apps = snapshot
            for app in RemovedAppWatchPolicy.departedApps(previous: previous, current: snapshot) {
                self.scheduleSettleCheck(for: app)
            }
        }
    }

    private func scheduleSettleCheck(for app: InstalledApp) {
        settleTasks[app.id]?.cancel()
        let current = generation
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        // Already in the Trash: this is a delete, not an update swapping the bundle.
        if RemovedAppWatchPolicy.isTrashed(app: app, trashDirectory: trash) {
            settleTasks[app.id] = Task { [weak self] in
                await self?.reportDeparture(of: app, generation: current)
            }
            return
        }
        settleTasks[app.id] = Task { [weak self] in
            try? await Task.sleep(for: RemovedAppWatchPolicy.settleDelay)
            await self?.reportDeparture(of: app, generation: current)
        }
    }

    /// Re-reads the app roots, then reports `app`. A fresh read rather than `apps`:
    /// a replacement may have landed at a new path after the last re-list. It is
    /// not stored, so the next re-list still diffs against the index last published.
    private func reportDeparture(of app: InstalledApp, generation current: Int) async {
        guard !Task.isCancelled, generation == current else { return }
        let snapshot = await Self.snapshotOffMain(roots: roots, reusing: apps)
        guard !Task.isCancelled, generation == current else { return }
        settleTasks[app.id] = nil
        let installedIDs = Set(snapshot.values.compactMap { $0.bundleID?.lowercased() })
        onDeparture?(
            Departure(
                app: app,
                bundleStillExists: FileManager.default.fileExists(atPath: app.bundleURL.path),
                installedBundleIDs: installedIDs
            )
        )
    }

    // MARK: Snapshot

    private static func snapshotOffMain(
        roots: [URL],
        reusing previous: [String: InstalledApp]
    ) async -> [String: InstalledApp] {
        await Task.detached(priority: .utility) {
            snapshot(roots: roots, reusing: previous)
        }.value
    }

    /// Every `.app` directly inside each root or one folder down, the same reach as
    /// the uninstaller's picker. Entries already in `previous` are reused rather than
    /// re-read. A root that exists but cannot be listed keeps its previous entries:
    /// a failed read must not look like every app in it was deleted.
    nonisolated static func snapshot(
        roots: [URL],
        reusing previous: [String: InstalledApp]
    ) -> [String: InstalledApp] {
        let fm = FileManager.default
        var result: [String: InstalledApp] = [:]

        func consider(_ url: URL) {
            guard url.pathExtension == "app" else { return }
            let key = url.standardizedFileURL.path
            guard result[key] == nil else { return }
            result[key] = previous[key] ?? readApp(at: url)
        }

        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard fm.fileExists(atPath: rootPath) else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                for (key, app) in previous where key.hasPrefix(rootPath + "/") {
                    result[key] = app
                }
                continue
            }
            for entry in entries {
                if entry.pathExtension == "app" {
                    consider(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let nested = (try? fm.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    nested.forEach(consider)
                }
            }
        }
        return result
    }

    /// Reads `Info.plist` directly rather than through `Bundle(url:)`, which caches
    /// per path for the life of the process and would keep describing a bundle that
    /// has since been replaced.
    private nonisolated static func readApp(at url: URL) -> InstalledApp {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOf: plistURL) as? [String: Any] ?? [:]
        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = [info["CFBundleDisplayName"], info["CFBundleName"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(
            name: name,
            bundleURL: url,
            bundleID: bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )
    }
}

/// Scheduled on the main queue, so the hop into the main actor is only an assertion.
private nonisolated func applicationsFolderWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
    let flags = (0..<count).map { eventFlags[$0] }
    let watcher = Unmanaged<ApplicationsFolderWatcher>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated {
        watcher.handle(paths: paths, flags: flags)
    }
}
