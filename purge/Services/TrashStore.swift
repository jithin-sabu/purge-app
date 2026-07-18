import AppKit
import Combine
import Foundation

/// Watches a directory for changes to its contents.
///
/// `nonisolated` on purpose: the project defaults to `MainActor` isolation, and this must
/// not hop to the main actor to report a file-system event.
private nonisolated final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    /// `nil` when the directory cannot be opened, in which case the caller keeps working
    /// from its own refreshes and simply has no live updates.
    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .link, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
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
    /// `~/.Trash` is TCC protected and unreadable without Full Disk Access. This must stay
    /// distinct from an empty trash: reporting 0 here would be a claim about the user's
    /// trash that Purge is in no position to make.
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
/// The total comes from watching `~/.Trash` rather than from refresh calls wired into
/// each clean path. Anything that changes the trash updates the number: Purge's own
/// cleans, emptying in Finder, or dragging a file in from somewhere else entirely.
@MainActor
final class TrashStore: ObservableObject {
    @Published private(set) var trashBytes: Int64 = 0
    @Published private(set) var access: TrashAccess = .measuring
    /// Trash total when the app last went to the background, so a drop can be compared
    /// against the volume's free space on return.
    private var trashBytesWhenBackgrounded: Int64?

    private let trashURL: URL?
    private var watcher: DirectoryWatcher?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// Guards against a slow size pass overwriting a newer one.
    private var latestPass = 0

    /// Sizing the trash shells out to `du`, and emptying a large trash fires many events
    /// in a row, so coalesce them into one pass.
    private static let debounce = Duration.milliseconds(400)

    /// How long to wait before re-measuring after a size pass came back empty-handed on a
    /// non-empty trash. A scan or a deletion spawns many `du` processes at once, and a
    /// starved trash measurement returns 0; this lets the load clear before trying again.
    private static let retryDelay = Duration.milliseconds(1200)

    init() {
        trashURL = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        TrashDebugLog.log(
            "=== TrashStore init pid=\(ProcessInfo.processInfo.processIdentifier) trashURL=\(trashURL?.path ?? "nil") ==="
        )
        // Own the first read here rather than leaning on a view's onAppear, so the number
        // is right from launch no matter which screen mounts first.
        Task { await refresh(trigger: "init") }
        startWatching()
    }

    var hasTrashContents: Bool { access == .readable && trashBytes > 0 }

    /// Counts the trash only when it is actually readable. `du` reports 0 for a directory
    /// it is not permitted to enter, which is indistinguishable from an empty trash, so
    /// permission is probed first rather than inferred from the size.
    ///
    /// A 0-byte reading is only trusted when the trash directory is genuinely empty. `du`
    /// also reports 0 when it fails or is starved — which happens during scans and deletions,
    /// where many `du` processes run at once and the watcher fires a burst of refreshes. On
    /// a non-empty trash that measured 0, the old total is kept and a retry is scheduled,
    /// rather than flashing the count to zero. A directory listing that fails under the same
    /// load gets the identical treatment: only a permission denial means "unreadable".
    func refresh(trigger: String = "direct") async {
        guard let trashURL else { return }
        latestPass += 1
        let pass = latestPass
        TrashDebugLog.log(
            "pass=\(pass) start trigger=\(trigger) current access=\(access) trashBytes=\(trashBytes)"
        )

        let reading: TrashReading = await Task.detached(priority: .utility) {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: trashURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
            } catch {
                let denial = Self.isPermissionDenial(error)
                TrashDebugLog.log(
                    "pass=\(pass) listing FAILED permissionDenial=\(denial) error=\(String(reflecting: error))"
                )
                return denial ? .permissionDenied : .readFailed
            }
            if entries.isEmpty {
                TrashDebugLog.log("pass=\(pass) listing EMPTY (0 entries)")
                return .empty
            }
            let duStart = Date()
            let measured = FolderSizing.directoryByteSize(at: trashURL)
            let preview = entries.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
            TrashDebugLog.log(
                "pass=\(pass) listing \(entries.count) entries [\(preview)\(entries.count > 5 ? ", …" : "")] "
                + "du measured=\(measured) bytes in \(String(format: "%.2f", -duStart.timeIntervalSinceNow))s"
            )
            return .nonEmpty(measuredBytes: measured)
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
    }

    /// What one look at the trash directory found, before deciding what it means for the
    /// published state.
    nonisolated enum TrashReading: Equatable, Sendable {
        /// The directory listing was refused for lack of permission (no Full Disk Access).
        case permissionDenied
        /// The directory listing failed for some other, transient reason — file-descriptor
        /// exhaustion or interruption under the load of a scan or a clean. Says nothing
        /// about what is in the trash.
        case readFailed
        case empty
        case nonEmpty(measuredBytes: Int64)
    }

    /// What a size pass means for the published state, computed purely so it can be tested
    /// without a real trash directory. Two subtleties it captures: a 0-byte reading is only
    /// the truth when the trash is genuinely empty (`du` also reports 0 when it fails or is
    /// starved — routine during scans and deletions), and only a permission denial may be
    /// reported as "unreadable" — that state zeroes the total and claims the user lacks
    /// Full Disk Access, which a transient read failure under load is no evidence of.
    enum TrashMeasurement: Equatable {
        /// Trash unreadable (no Full Disk Access); report as such.
        case unreadable
        /// A trustworthy readable total to publish; `bytes` is 0 only for a genuinely empty trash.
        case apply(bytes: Int64)
        /// The pass came back empty-handed — a failed listing, or `du` measuring 0 on a
        /// non-empty trash. Keep the current total and re-measure rather than resetting to zero.
        case keepAndRetry
    }

    nonisolated static func resolveMeasurement(_ reading: TrashReading) -> TrashMeasurement {
        switch reading {
        case .permissionDenied:
            return .unreadable
        case .readFailed:
            return .keepAndRetry
        case .empty:
            return .apply(bytes: 0)
        case .nonEmpty(let measuredBytes):
            return measuredBytes > 0 ? .apply(bytes: measuredBytes) : .keepAndRetry
        }
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

    func openTrashInFinder() {
        guard let trashURL else { return }
        NSWorkspace.shared.open(trashURL)
    }

    private func startWatching() {
        guard let trashURL else { return }
        watcher = DirectoryWatcher(url: trashURL) { [weak self] in
            TrashDebugLog.log("watcher event")
            Task { @MainActor in self?.scheduleRefresh() }
        }
        TrashDebugLog.log("watcher \(watcher == nil ? "FAILED to start" : "started")")
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
