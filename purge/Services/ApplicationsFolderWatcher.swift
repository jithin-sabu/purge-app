import CoreServices
import Foundation

/// Watches the app roots for bundles leaving them (issue #65).
///
/// A removed bundle can no longer say which app it was, so the watcher keeps an
/// index of every bundle's identifier, name, and file number, re-lists the roots
/// when their top level changes, and reports what dropped out. Whether a
/// departure is a real removal is the caller's call; see `RemovedAppWatchPolicy`.
///
/// With `tracksDestinations`, the watcher also holds an event-only handle on each
/// bundle. A handle follows its bundle through a move, so after a departure it
/// says where the bundle went without listing the destination: that matters for
/// `~/.Trash`, which the background agent may not be allowed to read. A bundle
/// that went to a Trash is reported at once. Anything else is followed under
/// `RemovedAppWatchPolicy.followDecision`: a deletion is reported once the roots
/// go quiet, a moved copy only if it is deleted or trashed within the follow
/// window, and neither if the app comes back. Without it (Purge's own presence
/// watch), departures are reported at once.
///
/// Directory-level FSEvents rather than per-file: only entries appearing and
/// disappearing near the top of each root matter, and per-file events would
/// deliver every write inside every bundle during an update.
///
/// Main-actor isolated. The app target already defaults to that, but the
/// background agent does not, and its startup task was mutating this state off
/// the actor the file-system callback uses. The stream holds an unretained
/// pointer to the watcher, so the owner must call `stop()` before letting it go.
@MainActor
final class ApplicationsFolderWatcher {

    /// Every bundle in the app roots, keyed by standardized path, with the file
    /// number each was indexed under.
    nonisolated struct Index: Sendable {
        var apps: [String: InstalledApp] = [:]
        var fileNumbers: [String: UInt64] = [:]

        /// Lowercased identifiers of every bundle in the index.
        var bundleIDs: Set<String> {
            Set(apps.values.compactMap { $0.bundleID?.lowercased() })
        }
    }

    /// A bundle that left, with what the caller needs to decide whether it was
    /// really removed.
    struct Departure {
        let app: InstalledApp
        /// The bundle's file number before it left, so its copy in the Trash can be
        /// found even under a new name.
        let fileNumber: UInt64?
        let bundleStillExists: Bool
        /// Lowercased identifiers of every bundle in the app roots right now.
        let installedBundleIDs: Set<String>
        /// Where the bundle went, when the watcher tracks destinations.
        let kind: RemovedAppWatchPolicy.DepartureKind?
    }

    var onDeparture: ((Departure) -> Void)?
    /// Called after every re-list with the new index, for callers that care about
    /// bundles arriving as well as leaving.
    var onChange: ((Index) -> Void)?

    private(set) var index = Index()

    private let roots: [URL]
    private let rootPaths: [String]
    private let tracksDestinations: Bool
    private let timing: RemovedAppWatchPolicy.FollowTiming
    /// The last time anything changed under the roots, for the quiet period.
    private var lastActivity = ContinuousClock.now
    /// Event-only descriptors on each indexed bundle, keyed like `index.apps`.
    private var handles: [String: Int32] = [:]
    /// Departures being followed, keyed by bundle path.
    private var followTasks: [String: Task<Void, Never>] = [:]
    private var stream: FSEventStreamRef?
    private var rescanTask: Task<Void, Never>?
    /// Watches the parent of each root that did not exist at start, so a
    /// `~/Applications` created later is picked up without watching all of home.
    private var parentSources: [DispatchSourceFileSystemObject] = []
    /// Bumped by `start()` and `stop()` so work from an earlier run never lands.
    private var generation = 0
    private var isStarted = false

    init(
        roots: [URL] = RemovedAppWatchPolicy.installedAppRoots(),
        tracksDestinations: Bool = false,
        timing: RemovedAppWatchPolicy.FollowTiming = .standard
    ) {
        self.roots = roots
        rootPaths = roots.map(Self.eventPath(for:))
        self.tracksDestinations = tracksDestinations
        self.timing = timing
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

    var installedApps: [InstalledApp] { Array(index.apps.values) }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        generation += 1
        let current = generation
        Task {
            // Index before listening: a removal reported against an empty index
            // could never be named.
            let snapshot = await Self.indexOffMain(roots: roots, reusing: Index())
            guard generation == current else { return }
            syncHandles(previous: Index(), current: snapshot)
            index = snapshot
            openStream()
            onChange?(snapshot)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation += 1
        rescanTask?.cancel()
        rescanTask = nil
        // Each follow task closes the handle it owns when it wakes cancelled.
        followTasks.values.forEach { $0.cancel() }
        followTasks.removeAll()
        handles.values.forEach { close($0) }
        handles.removeAll()
        closeStream()
        parentSources.forEach { $0.cancel() }
        parentSources.removeAll()
        index = Index()
    }

    private func openStream() {
        let watched = rootPaths.filter { FileManager.default.fileExists(atPath: $0) }
        watchParentsOfMissingRoots(watched: watched)
        guard !watched.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // `NoDefer` delivers the first event of a quiet spell at once, so a drag to
        // the Trash is still reported the moment it happens. The latency then only
        // batches the flood of directory events an update writes inside a bundle,
        // instead of waking this process for each one.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            applicationsFolderWatcherCallback,
            &context,
            watched as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func closeStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func watchParentsOfMissingRoots(watched: [String]) {
        parentSources.forEach { $0.cancel() }
        parentSources.removeAll()
        let missing = rootPaths.filter { !watched.contains($0) }
        let current = generation
        for root in missing {
            let parent = (root as NSString).deletingLastPathComponent
            let descriptor = open(parent, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: .write,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current,
                          FileManager.default.fileExists(atPath: root) else { return }
                    self.closeStream()
                    self.openStream()
                    self.scheduleRescan()
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            parentSources.append(source)
        }
    }

    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        // Any change counts as activity, including writes inside a bundle: an
        // installer filling in a new copy is exactly what the quiet period waits out.
        lastActivity = ContinuousClock.now
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
    /// separately) into one re-list, then reports every bundle that dropped out.
    private func scheduleRescan() {
        rescanTask?.cancel()
        let current = generation
        rescanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, let self, self.generation == current else { return }
            let previous = self.index
            let snapshot = await Self.indexOffMain(roots: self.roots, reusing: previous)
            guard !Task.isCancelled, self.generation == current else { return }
            let departed = RemovedAppWatchPolicy.departedApps(previous: previous.apps, current: snapshot.apps)
            // Take each departed bundle's handle before the sync closes it.
            let departedHandles = departed.reduce(into: [String: Int32]()) { taken, app in
                taken[app.id] = self.handles.removeValue(forKey: app.id)
            }
            self.syncHandles(previous: previous, current: snapshot)
            self.index = snapshot
            for app in departed {
                self.route(app, fileNumber: previous.fileNumbers[app.id], handle: departedHandles[app.id])
            }
            self.onChange?(snapshot)
        }
    }

    // MARK: Departures

    /// Reports a departure now when it went to the Trash (or when destinations are
    /// not tracked). Anything else is checked every `pollInterval` until
    /// `RemovedAppWatchPolicy.followDecision` reports or drops it.
    private func route(_ app: InstalledApp, fileNumber: UInt64?, handle: Int32?) {
        guard tracksDestinations else {
            report(app, fileNumber: fileNumber, kind: nil)
            return
        }
        let kind = RemovedAppWatchPolicy.departureKind(
            currentPath: handle.flatMap(Self.currentPath(of:)),
            fileNumber: fileNumber
        )
        if kind == .trashed {
            handle.map { _ = close($0) }
            report(app, fileNumber: fileNumber, kind: .trashed)
            return
        }
        followTasks[app.id]?.cancel()
        let current = generation
        let timing = timing
        followTasks[app.id] = Task { [weak self] in
            defer { handle.map { _ = close($0) } }
            let clock = ContinuousClock()
            let departedAt = clock.now
            var deletedAt: ContinuousClock.Instant?
            while true {
                try? await Task.sleep(for: timing.pollInterval)
                guard !Task.isCancelled, let self, self.generation == current else { return }
                let kind = RemovedAppWatchPolicy.departureKind(
                    currentPath: handle.flatMap(Self.currentPath(of:)),
                    fileNumber: fileNumber
                )
                if kind == .deleted, deletedAt == nil { deletedAt = clock.now }
                let now = clock.now
                let decision = RemovedAppWatchPolicy.followDecision(
                    kind: kind,
                    appIsBack: self.isBack(app),
                    sinceDeparture: now - departedAt,
                    sinceDeleted: deletedAt.map { now - $0 },
                    sinceActivity: now - self.lastActivity,
                    timing: timing
                )
                switch decision {
                case .keepFollowing:
                    continue
                case .drop:
                    self.followTasks[app.id] = nil
                    return
                case .report:
                    self.followTasks[app.id] = nil
                    self.report(app, fileNumber: fileNumber, kind: kind)
                    return
                }
            }
        }
    }

    /// Back at its path, or another bundle with its identifier is in the roots.
    private func isBack(_ app: InstalledApp) -> Bool {
        if FileManager.default.fileExists(atPath: app.bundleURL.path) { return true }
        guard let id = app.bundleID?.lowercased() else { return false }
        return index.bundleIDs.contains(id)
    }

    private func report(_ app: InstalledApp, fileNumber: UInt64?, kind: RemovedAppWatchPolicy.DepartureKind?) {
        onDeparture?(
            Departure(
                app: app,
                fileNumber: fileNumber,
                bundleStillExists: FileManager.default.fileExists(atPath: app.bundleURL.path),
                installedBundleIDs: index.bundleIDs,
                kind: kind
            )
        )
    }

    /// Opens a handle on each bundle that is new or was replaced in place, and
    /// closes handles on bundles no longer indexed. `O_EVTONLY` never stops a
    /// volume unmounting or a bundle being moved or deleted.
    private func syncHandles(previous: Index, current: Index) {
        guard tracksDestinations else { return }
        for (key, number) in current.fileNumbers
        where handles[key] == nil || previous.fileNumbers[key] != number {
            if let old = handles.removeValue(forKey: key) { close(old) }
            let descriptor = open(key, O_EVTONLY)
            if descriptor >= 0 { handles[key] = descriptor }
        }
        for key in handles.keys where current.apps[key] == nil {
            if let old = handles.removeValue(forKey: key) { close(old) }
        }
    }

    /// Where the item behind `descriptor` is now. Follows renames and moves on the
    /// same volume, including into `~/.Trash`, with no read access to the
    /// destination. A deleted item still reports its last path.
    private nonisolated static func currentPath(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Snapshot

    nonisolated static func indexOffMain(roots: [URL], reusing previous: Index) async -> Index {
        await Task.detached(priority: .utility) {
            index(roots: roots, reusing: previous)
        }.value
    }

    /// The app list alone, for callers that do not track file numbers.
    nonisolated static func snapshot(
        roots: [URL],
        reusing previous: [String: InstalledApp]
    ) -> [String: InstalledApp] {
        index(roots: roots, reusing: Index(apps: previous)).apps
    }

    /// Every `.app` directly inside each root or one folder down, the same reach as
    /// the uninstaller's picker. An entry is reused from `previous` only while its
    /// file number is unchanged, so a bundle an updater swapped in place is read
    /// again rather than described by the copy it replaced. A root that exists but
    /// cannot be listed keeps its previous entries: a failed read must not look like
    /// every app in it was deleted.
    nonisolated static func index(roots: [URL], reusing previous: Index) -> Index {
        let fm = FileManager.default
        var result = Index()

        func consider(_ url: URL) {
            guard url.pathExtension == "app" else { return }
            let key = url.standardizedFileURL.path
            guard result.apps[key] == nil else { return }
            let number = RemovedAppWatchPolicy.fileNumber(atPath: key)
            if let number, previous.fileNumbers[key] == number, let known = previous.apps[key] {
                result.apps[key] = known
            } else {
                // A plain path URL, not the listing's own: a URL from
                // `contentsOfDirectory` reports a different standardized path once
                // its item has moved (`/var` becomes `/private/var`), so the app's
                // `id` would stop matching its key, the ignore list, and its record.
                result.apps[key] = readApp(at: URL(fileURLWithPath: key, isDirectory: true))
            }
            result.fileNumbers[key] = number
        }

        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard fm.fileExists(atPath: rootPath) else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                for (key, app) in previous.apps where key.hasPrefix(rootPath + "/") {
                    result.apps[key] = app
                    result.fileNumbers[key] = previous.fileNumbers[key]
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
