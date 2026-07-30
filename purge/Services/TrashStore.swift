import AppKit
import Combine
import Foundation

/// Watches a directory for changes to its contents.
///
/// `nonisolated` on purpose: the project defaults to `MainActor` isolation, and this must
/// not hop to the main actor to report a file-system event.
private nonisolated final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    /// `nil` when the directory cannot be opened — which is the normal case before Full Disk
    /// Access is granted, so callers must be prepared to try again rather than treat a failed
    /// start as permanent.
    ///
    /// `onChange` receives the events that fired, because `.delete` and `.rename` mean this
    /// watcher's descriptor no longer points at the directory the caller cares about and the
    /// watcher has to be replaced.
    init?(url: URL, onChange: @escaping @Sendable (DispatchSource.FileSystemEvent) -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .link, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        // The handler holds `source` so it can report which events fired. That retain cycle
        // is what keeps the source alive between events, and `cancel()` in `deinit` breaks it.
        source.setEventHandler { onChange(source.data) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
    }
}

/// Whether the trash can be counted at all.
enum TrashAccess: Equatable {
    /// No size pass has landed yet. Sizing shells out to `du`, which takes real time on a
    /// large trash, and "0 bytes" during that window would claim the trash is empty when
    /// the truth is that we have not looked yet.
    case measuring
    case readable
    /// A trash directory is TCC protected and cannot be counted without Full Disk Access
    /// (`~/.Trash` is refused outright). This must stay distinct from an empty trash:
    /// reporting 0 here would be a claim about the user's trash that Purge is in no position
    /// to make.
    case unreadable
}

/// Owns the trash total and hands the user off to Finder to act on it.
///
/// Purge deliberately cannot empty the trash. Deleting for good is the user's decision
/// to make, in the app that owns the trash across every mounted volume, with its own
/// warning in front of it. That keeps "Purge never permanently deletes anything" true
/// without an asterisk, and costs nothing: Finder is one click away, and this needs no
/// automation permission at all.
///
/// The total comes from watching the trash directories rather than from refresh calls wired
/// into each clean path. Anything that changes the trash updates the number: Purge's own
/// cleans, emptying in Finder, or dragging a file in from somewhere else entirely.
///
/// "The trash" is plural, which is the whole reason this class counts a list of directories
/// (see `trashDirectories()`). Counting only `~/.Trash` is what made the total sit at a few
/// hundred KB — Purge's own cleaned caches, and nothing else — while Finder reported hundreds
/// of megabytes, and what made it ignore everything the user deleted in Finder.
@MainActor
final class TrashStore: ObservableObject {
    @Published private(set) var trashBytes: Int64 = 0
    @Published private(set) var access: TrashAccess = .measuring
    /// Trash total when the app last went to the background, so a drop can be compared
    /// against the volume's free space on return.
    private var trashBytesWhenBackgrounded: Int64?

    private let trashURLs: [URL]
    private var watchers: [URL: DirectoryWatcher] = [:]
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Guards against a slow size pass overwriting a newer one.
    private var latestPass = 0
    /// Directories whose watcher could not start, so the retry on each pass logs once rather
    /// than on every attempt.
    private var loggedWatcherFailures: Set<URL> = []

    /// Sizing the trash shells out to `du`, and emptying a large trash fires many events
    /// in a row, so coalesce them into one pass.
    private static let debounce = Duration.milliseconds(400)

    /// How long to wait before re-measuring after a size pass came back empty-handed on a
    /// non-empty trash. A scan or a deletion spawns many `du` processes at once, and a
    /// starved trash measurement returns 0; this lets the load clear before trying again.
    private static let retryDelay = Duration.milliseconds(1200)

    /// Backstop re-measure interval while Purge is the active app. The watcher and the
    /// foreground-return refresh are what normally keep the total current; this only exists
    /// so a watcher that never started — or one whose directory was replaced under it —
    /// cannot leave a stale number on screen for as long as the window stays frontmost.
    private static let activePollInterval = Duration.seconds(30)

    init() {
        trashURLs = Self.trashDirectories()
        TrashDebugLog.log(
            "=== TrashStore init pid=\(ProcessInfo.processInfo.processIdentifier) "
            + "trashURLs=\(trashURLs.map(\.path).joined(separator: " | ")) ==="
        )
        // Own the first read here rather than leaning on a view's onAppear, so the number
        // is right from launch no matter which screen mounts first.
        Task { await refresh(trigger: "init") }
        startWatchingIfNeeded()
        startPolling()
    }

    /// Every trash directory on this volume, because "the Trash" the user sees in Finder is
    /// not one directory.
    ///
    /// A file that lives in iCloud Drive is trashed to `~/Library/Mobile Documents/.Trash`,
    /// never to `~/.Trash` — and with "Desktop & Documents Folders" turned on in iCloud
    /// settings, that covers most of what a person deletes. On the machine this was traced
    /// on, `~/.Trash` held 15 items and 152 KB while the iCloud trash held 90 items and
    /// 749 MB, which is why "In trash" only ever moved when Purge itself cleaned something:
    /// Purge's targets are Library caches, and those do land in `~/.Trash`.
    ///
    /// Deliberately not included: `/Volumes/<name>/.Trashes/<uid>`, the trash of every other
    /// mounted volume. Those bytes are not on this volume, so adding them to a figure shown
    /// beside this volume's free space would overstate what emptying the trash frees here.
    nonisolated static func trashDirectories() -> [URL] {
        var urls: [URL] = []
        if let home = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            urls.append(home.standardizedFileURL)
        }
        // No domain mask names the iCloud trash, and it is absent when iCloud Drive is off —
        // handled as a missing directory rather than by probing here, so that turning iCloud
        // Drive on starts counting it without a relaunch.
        urls.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/.Trash", isDirectory: true)
                .standardizedFileURL
        )
        return urls
    }

    var hasTrashContents: Bool { access == .readable && trashBytes > 0 }

    /// Sums every trash directory, and treats a reading that proves nothing as a question
    /// rather than an answer.
    ///
    /// Three ways a pass can be wrong, all of them observed in the field:
    ///
    /// - `du` reports 0 both for an empty directory and for a run that was starved or
    ///   refused. `directoryByteSizeIfMeasurable` separates those: no reading at all is not
    ///   a measurement of zero.
    /// - A listing can fail transiently under the load of a scan or a clean. Only a
    ///   permission denial means "unreadable"; anything else keeps the last good total.
    /// - A trash directory that does not exist (the iCloud one, with iCloud Drive off)
    ///   contributes nothing and must not be mistaken for either of the above.
    func refresh(trigger: String = "direct") async {
        guard !trashURLs.isEmpty else { return }
        latestPass += 1
        let pass = latestPass
        TrashDebugLog.log(
            "pass=\(pass) start trigger=\(trigger) current access=\(access) trashBytes=\(trashBytes)"
        )

        let urls = trashURLs
        let reading: TrashReading = await Task.detached(priority: .utility) {
            Self.readTrash(at: urls, pass: pass)
        }.value

        // A newer pass started while `du` ran; its answer is the current one.
        guard pass == latestPass else {
            TrashDebugLog.log("pass=\(pass) DISCARDED (stale; latest=\(latestPass))")
            return
        }

        let resolution = Self.resolveMeasurement(reading)
        switch resolution {
        case .unreadable:
            retryTask?.cancel()
            access = .unreadable
            trashBytes = 0
        case .apply(let bytes):
            retryTask?.cancel()
            access = .readable
            trashBytes = bytes
        case .keepAndRetry:
            // Keep the last good total (staying in `.measuring` if none has ever landed, so
            // the UI never claims the trash is empty) and re-measure once the load clears.
            if trashBytes > 0 {
                access = .readable
            }
            scheduleRetry()
        }
        TrashDebugLog.log(
            "pass=\(pass) resolved \(resolution) -> published access=\(access) trashBytes=\(trashBytes)"
        )
        // A watcher cannot start on a directory that is unreadable or absent, which is the
        // state Purge launches in before Full Disk Access is granted and the state the iCloud
        // trash is in until something is deleted from iCloud Drive. Re-arming here is what
        // gets live updates going once that changes, without waiting for a relaunch.
        startWatchingIfNeeded()
    }

    /// Looks at every trash directory and folds the results into one reading, off the main
    /// actor. Sizes them in a single `du` invocation, so the cost does not scale with the
    /// number of directories.
    nonisolated private static func readTrash(at trashURLs: [URL], pass: Int) -> TrashReading {
        var listings: [(url: URL, listing: LocationListing)] = []
        for url in trashURLs {
            listings.append((url, listing(at: url, pass: pass)))
        }

        let toMeasure = listings.compactMap { entry -> URL? in
            guard case .entries(let contents) = entry.listing, !contents.isEmpty else { return nil }
            return entry.url
        }
        let duStart = Date()
        let measured = toMeasure.isEmpty ? [:] : FolderSizing.directorySizes(at: toMeasure)
        if !toMeasure.isEmpty {
            TrashDebugLog.log(
                "pass=\(pass) du measured "
                + toMeasure.map { "\(label(for: $0))=\(measured[$0.path].map(String.init) ?? "none")" }
                    .joined(separator: " ")
                + " in \(String(format: "%.2f", -duStart.timeIntervalSinceNow))s"
            )
        }

        return combine(
            listings.map { entry in
                switch entry.listing {
                case .missing: return .missing
                case .permissionDenied: return .permissionDenied
                case .failed: return .failed
                case .entries(let contents):
                    return .counted(
                        entries: contents.count,
                        bytes: contents.isEmpty ? 0 : measured[entry.url.path]
                    )
                }
            }
        )
    }

    /// Short log label for a trash directory. Every one of them is named `.Trash`, so the
    /// parent has to come along or the log cannot tell them apart.
    nonisolated private static func label(for url: URL) -> String {
        "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
    }

    /// One directory's listing, before it is sized.
    nonisolated private enum LocationListing {
        case missing
        case permissionDenied
        case failed
        case entries([URL])
    }

    nonisolated private static func listing(at url: URL, pass: Int) -> LocationListing {
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
            let preview = entries.prefix(4).map(\.lastPathComponent).joined(separator: ", ")
            TrashDebugLog.log(
                "pass=\(pass) \(url.path): \(entries.count) entries "
                + "[\(preview)\(entries.count > 4 ? ", …" : "")]"
            )
            return .entries(entries)
        } catch {
            // Absence is not a failure: the iCloud trash simply does not exist until iCloud
            // Drive does, and treating that as a failed pass would retry forever.
            if !FileManager.default.fileExists(atPath: url.path) {
                TrashDebugLog.log("pass=\(pass) \(url.path): absent")
                return .missing
            }
            let denial = isPermissionDenial(error)
            TrashDebugLog.log(
                "pass=\(pass) \(url.path): listing FAILED permissionDenial=\(denial) "
                + "error=\(String(reflecting: error))"
            )
            return denial ? .permissionDenied : .failed
        }
    }

    /// What one trash directory contributed to the pass.
    nonisolated enum LocationReading: Equatable, Sendable {
        /// The directory does not exist, so it holds nothing and hides nothing.
        case missing
        /// Listing was refused for lack of permission (no Full Disk Access).
        case permissionDenied
        /// Listing failed for some other, transient reason — descriptor exhaustion or
        /// interruption under the load of a scan or a clean. Says nothing about the contents.
        case failed
        /// Listed successfully. `bytes` is `nil` when `du` produced no reading for it, and 0
        /// only for a directory that listed empty or that `du` read and found empty.
        case counted(entries: Int, bytes: Int64?)
    }

    /// Folds the directories into one reading. Kept pure and separate so the awkward
    /// combinations — one trash refused while another counts fine, one absent, one measured
    /// and one starved — are testable without a real trash anywhere.
    ///
    /// A refusal or a failure anywhere outranks the successes: a total that silently omits
    /// one trash is a wrong number, and this store's whole job is to not report one.
    nonisolated static func combine(_ locations: [LocationReading]) -> TrashReading {
        if locations.contains(.permissionDenied) {
            return TrashReading(listing: .permissionDenied, measuredBytes: nil)
        }
        if locations.contains(.failed) {
            return TrashReading(listing: .failed, measuredBytes: nil)
        }
        var entries = 0
        var bytes: Int64 = 0
        var measurable = true
        for location in locations {
            guard case .counted(let count, let measured) = location else { continue }
            entries += count
            guard let measured else {
                measurable = false
                continue
            }
            bytes += measured
        }
        return TrashReading(
            listing: .counted(entries: entries),
            measuredBytes: measurable ? bytes : nil
        )
    }

    /// What one look at every trash directory found, before deciding what it means for the
    /// published state.
    nonisolated struct TrashReading: Equatable, Sendable {
        enum Listing: Equatable, Sendable {
            /// At least one trash was refused for lack of permission (no Full Disk Access).
            case permissionDenied
            /// At least one listing failed for some other, transient reason. Says nothing
            /// about what is in the trash.
            case failed
            /// Every trash that exists listed successfully; `entries` is their combined count.
            case counted(entries: Int)
        }

        let listing: Listing
        /// The combined size, or `nil` when any trash holding entries produced no `du`
        /// reading — refused, starved, or never run.
        let measuredBytes: Int64?
    }

    /// What a size pass means for the published state, computed purely so it can be tested
    /// without a real trash directory. The subtleties it captures: nothing the trash appears
    /// to contain counts unless protected content is provably readable (without the grant the
    /// listing is a filtered fiction, not an error), a 0-byte reading is only the truth for a
    /// directory `du` actually read and found empty, and a transient read failure is no
    /// evidence of a missing grant — reporting it as "unreadable" would zero a good total.
    enum TrashMeasurement: Equatable {
        /// Trash unreadable (no Full Disk Access); report as such.
        case unreadable
        /// A trustworthy readable total to publish; `bytes` is 0 only for a genuinely empty trash.
        case apply(bytes: Int64)
        /// The pass came back empty-handed — a failed listing, or `du` measuring nothing, or
        /// 0 on a non-empty trash. Keep the current total and re-measure rather than
        /// resetting to zero.
        case keepAndRetry
    }

    nonisolated static func resolveMeasurement(_ reading: TrashReading) -> TrashMeasurement {
        if case .permissionDenied = reading.listing {
            return .unreadable
        }
        if let bytes = reading.measuredBytes, bytes > 0 {
            return .apply(bytes: bytes)
        }
        // No measurement at all, or no listing to interpret: nothing was learned this pass.
        guard reading.measuredBytes != nil, case .counted(let count) = reading.listing else {
            return .keepAndRetry
        }
        // A non-empty trash that measured 0 is a starved `du`, not an empty trash.
        guard count == 0 else { return .keepAndRetry }
        // Nothing listed, and `du` read the directory and found nothing: an empty trash.
        return .apply(bytes: 0)
    }

    /// Whether a `contentsOfDirectory` failure means the trash is off limits (TCC / POSIX
    /// permission denial) as opposed to a transient failure under load. Walks the
    /// underlying-error chain because the permission code is often one level down.
    nonisolated static func isPermissionDenial(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.fileReadNoPermission.rawValue {
                return true
            }
            if nsError.domain == NSPOSIXErrorDomain,
               nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Snapshots the tally so a later foreground return can tell what changed while the
    /// user was away, e.g. emptying the trash in Finder.
    func markBackgrounded() {
        trashBytesWhenBackgrounded = access == .readable ? trashBytes : nil
        TrashDebugLog.log("markBackgrounded snapshot=\(trashBytesWhenBackgrounded.map(String.init) ?? "nil")")
    }

    /// How much the trash shrank while the app was in the background. `nil` when nothing
    /// was snapshotted, the trash is unreadable, or it did not shrink.
    func trashDropSinceBackgrounded() -> Int64? {
        guard access == .readable, let before = trashBytesWhenBackgrounded else { return nil }
        let drop = before - trashBytes
        return drop > 0 ? drop : nil
    }

    /// Opens the trash Finder shows, which is the one place all of these directories appear as
    /// a single list.
    func openTrashInFinder() {
        guard let first = trashURLs.first else { return }
        NSWorkspace.shared.open(first)
    }

    /// Arms a watcher on each trash directory, and re-arms any that could not start or lost
    /// its directory. Cheap enough to call on every pass: opening the descriptor fails
    /// immediately when a directory is off limits or absent.
    private func startWatchingIfNeeded() {
        for url in trashURLs where watchers[url] == nil {
            let watcher = DirectoryWatcher(url: url) { [weak self] event in
                TrashDebugLog.log("watcher event=\(event.rawValue) on \(Self.label(for: url))")
                Task { @MainActor in
                    guard let self else { return }
                    // The watched directory was deleted or moved out from under the descriptor,
                    // so it now watches nothing. Drop it; the refresh this event schedules
                    // re-arms on whatever is at that path now.
                    if event.contains(.delete) || event.contains(.rename) {
                        self.watchers[url] = nil
                    }
                    self.scheduleRefresh()
                }
            }
            guard let watcher else {
                // Expected for a trash that is off limits or does not exist yet, and retried on
                // every pass — log it once rather than on each attempt.
                if loggedWatcherFailures.insert(url).inserted {
                    TrashDebugLog.log(
                        "watcher FAILED to start on \(url.path) (will retry on later passes)"
                    )
                }
                continue
            }
            watchers[url] = watcher
            loggedWatcherFailures.remove(url)
            TrashDebugLog.log("watcher started on \(url.path)")
        }
    }

    /// Re-measures on a slow interval while Purge is frontmost.
    ///
    /// The watcher and the foreground-return refresh are the real mechanisms; this only
    /// covers the cases where neither can fire — a watcher that never started, or a window
    /// that stays frontmost while the trash changes underneath it — so the number cannot sit
    /// stale in front of the user indefinitely. Idle in the background, where nobody is
    /// looking and the next activation refreshes anyway.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.activePollInterval)
                guard let self else { return }
                guard !Task.isCancelled, NSApp?.isActive == true else { continue }
                await self.refresh(trigger: "active-poll")
            }
        }
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await refresh(trigger: "watcher-debounced")
        }
    }

    /// Re-measures after a starved size pass. Only one retry is ever pending; a later
    /// success (or a fresh watcher-driven refresh) cancels it. If the retry also comes
    /// back empty-handed, `refresh()` schedules another, so this self-terminates once the
    /// competing `du` load clears.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor in
            try? await Task.sleep(for: Self.retryDelay)
            guard !Task.isCancelled else { return }
            await refresh(trigger: "retry")
        }
    }
}
