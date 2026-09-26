import AppKit
import Foundation
import Security

/// Background agent that watches Applications folders when Purge itself is not
/// running (issue #65). Records each real removal and opens Purge to review
/// leftovers: at once for an app dragged to the Trash, and for anything else once
/// `RemovedAppWatchPolicy.followDecision` says it really was removed. Registered
/// through `SMAppService.agent` when the Settings toggle is on; launchd keeps it
/// alive across logins.
///
/// launchd never restarts a running agent on its own, so the agent exits when it
/// is out of date and `KeepAlive` starts the current copy: when its executable is
/// replaced (an update), and when Purge launches from another copy and says so.
/// When its own Purge is trashed, moved, or deleted, it stops watching instead:
/// an agent left running from the Trash would keep opening that copy, and once
/// the Trash is emptied, macOS would ask the user what should open `purge://`.
@main
@MainActor
enum PurgeWatchMain {
    /// This process's executable and its file number, read at launch.
    private static var ownPath: String?
    private static var launchedFileNumber: UInt64?
    private static var lastFileNumber: UInt64?
    /// Checks spent waiting for a replaced Purge to finish landing.
    private static var replacedChecks = 0
    /// Nil while dormant.
    private static var watcher: ApplicationsFolderWatcher?

    static func main() {
        raiseOpenFileLimit()
        ownPath = executablePath()
        listenForOwner()
        // launchd starts the agent from wherever its bundle is, the Trash included.
        if let ownPath, RemovedAppWatchPolicy.isInTrash(path: ownPath) {
            RunLoop.main.run()
            return
        }
        startWatching()
        watchOwnExecutable()
        RunLoop.main.run()
    }

    private static func startWatching() {
        let watcher = ApplicationsFolderWatcher(tracksDestinations: true)
        watcher.onDeparture = { departure in
            handle(departure)
        }
        watcher.start()
        self.watcher = watcher
    }

    private static func handle(_ departure: ApplicationsFolderWatcher.Departure) {
        guard watcher != nil else { return }
        guard RemovedAppWatchPolicy.shouldOfferReview(
            for: departure.app,
            bundleStillExists: departure.bundleStillExists,
            installedBundleIDs: departure.installedBundleIDs,
            otherCopyExists: RemovedAppWatchPolicy.otherCopyExists(of: departure.app),
            removedByPurge: RemovedAppHandoff.isIgnored(path: departure.app.id)
        ) else { return }
        guard let bundleID = departure.app.bundleID, let appURL = containingApp() else { return }

        RemovedAppHandoff.enqueue(
            RemovedAppHandoff.Record(
                path: departure.app.id,
                bundleID: bundleID,
                name: departure.app.name,
                fileNumber: departure.fileNumber,
                removedAt: Date()
            )
        )
        openPurge(at: appURL)
    }

    /// Opens the Purge this agent ships in. Asking Launch Services for the URL
    /// scheme alone can pick any registered copy, such as an old Xcode build.
    ///
    /// A Purge that was not running starts without its window, shows it only for
    /// a review, and quits again when done (`RemovedAppHandoff.launchedForReviewKey`);
    /// one already running ignores the argument. The launch still activates:
    /// macOS can refuse an app in the background that asks to come forward later,
    /// which would leave the review behind the Finder window it came from.
    private static func openPurge(at appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-" + RemovedAppHandoff.launchedForReviewKey, "YES"]
        NSWorkspace.shared.open(
            [RemovedAppHandoff.launchURL],
            withApplicationAt: appURL,
            configuration: configuration
        )
    }

    // MARK: Staying current

    private static func watchOwnExecutable() {
        guard let ownPath else { return }
        launchedFileNumber = RemovedAppWatchPolicy.fileNumber(atPath: ownPath)
        lastFileNumber = launchedFileNumber
        // One `lstat` every ten seconds. A vnode source would not see a copy
        // finish landing, which is what the second matching check waits for.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { checkExecutable() }
        }
    }

    private static func listenForOwner() {
        DistributedNotificationCenter.default().addObserver(
            forName: RemovedAppHandoff.agentOwnerNotification,
            object: nil,
            queue: .main
        ) { note in
            let ownerPath = note.object as? String
            MainActor.assumeIsolated { ownerAnnounced(ownerPath) }
        }
    }

    private static func checkExecutable() {
        guard let ownPath else { return }
        let current = RemovedAppWatchPolicy.fileNumber(atPath: ownPath)
        defer { lastFileNumber = current }
        switch RemovedAppWatchPolicy.agentHome(
            launched: launchedFileNumber,
            previous: lastFileNumber,
            current: current
        ) {
        case .unchanged:
            // Put back after being trashed: start over from a clean state.
            if watcher == nil { exit(0) }
        case .settling:
            break
        case .replaced:
            replacedChecks += 1
            // A removal being followed is reported within a minute; wait for it.
            guard watcher?.isFollowing != true else { return }
            // Finder copies a bundle file by file, and launchd waits minutes
            // before retrying a start that failed on a half-copied one. A valid
            // signature means every file is in place. Five minutes covers a
            // copy that never validates, such as an unsigned local build.
            if newCopyIsComplete() || replacedChecks >= 30 { exit(0) }
        case .gone:
            watcher?.stop()
            watcher = nil
        }
    }

    private static func ownerAnnounced(_ ownerPath: String?) {
        guard let ownPath, let ownerPath else { return }
        let resolvedOwner = resolved(ownerPath)
        if RemovedAppWatchPolicy.agentIsStale(
            ownPath: ownPath,
            ownerPath: resolvedOwner,
            ownerExists: FileManager.default.fileExists(atPath: resolvedOwner)
        ) {
            exit(0)
        }
    }

    private static func newCopyIsComplete() -> Bool {
        guard let appURL = containingApp() else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    // MARK: Paths

    /// `argv[0]` is relative under launchd (`Contents/MacOS/...`), and
    /// `Bundle.main` is Purge's bundle, whose executable is Purge itself.
    private static func executablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return resolved(String(cString: buffer))
    }

    /// The `.app` that holds this executable, when it is in one.
    private static func containingApp() -> URL? {
        guard let ownPath else { return nil }
        let app = URL(fileURLWithPath: ownPath)
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()
        guard app.pathExtension == "app",
              FileManager.default.fileExists(atPath: app.path) else { return nil }
        return app
    }

    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// The watcher holds one handle per installed app, and launchd starts agents
    /// with a soft limit of 256 open files. A Mac with a few hundred apps would
    /// run out, and the bundles past the limit would lose Trash detection.
    private static func raiseOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(limit.rlim_max, rlim_t(8192))
        guard limit.rlim_cur < wanted else { return }
        limit.rlim_cur = wanted
        setrlimit(RLIMIT_NOFILE, &limit)
    }
}
