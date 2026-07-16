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
    /// `false` until the first size pass lands. Sizing shells out to `du`, which takes
    /// real time on a large trash, and "0 bytes" during that window would claim the
    /// trash is empty when the truth is that we have not looked yet.
    @Published private(set) var hasMeasured = false

    private let trashURL: URL?
    private var watcher: DirectoryWatcher?
    private var debounceTask: Task<Void, Never>?
    /// Guards against a slow size pass overwriting a newer one.
    private var latestPass = 0

    /// Sizing the trash shells out to `du`, and emptying a large trash fires many events
    /// in a row, so coalesce them into one pass.
    private static let debounce = Duration.milliseconds(400)

    init() {
        trashURL = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        // Own the first read here rather than leaning on a view's onAppear, so the number
        // is right from launch no matter which screen mounts first.
        Task { await refresh() }
        startWatching()
    }

    var hasTrashContents: Bool { trashBytes > 0 }

    func refresh() async {
        guard let trashURL else { return }
        latestPass += 1
        let pass = latestPass

        let bytes = await Task.detached(priority: .utility) {
            FolderSizing.directoryByteSize(at: trashURL)
        }.value

        // A newer pass started while `du` ran; its answer is the current one.
        guard pass == latestPass else { return }
        trashBytes = bytes
        hasMeasured = true
    }

    func openTrashInFinder() {
        guard let trashURL else { return }
        NSWorkspace.shared.open(trashURL)
    }

    private func startWatching() {
        guard let trashURL else { return }
        watcher = DirectoryWatcher(url: trashURL) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }
}
