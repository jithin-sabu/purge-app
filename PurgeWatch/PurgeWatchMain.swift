import AppKit
import Foundation

/// Background agent that watches Applications folders when Purge itself is not
/// running (issue #65). Records each real removal and opens Purge to review
/// leftovers: at once for an app dragged to the Trash, and for anything else once
/// `RemovedAppWatchPolicy.followDecision` says it really was removed. Registered
/// through `SMAppService.agent` when the Settings toggle is on; launchd keeps it
/// alive across logins.
@main
@MainActor
enum PurgeWatchMain {
    static func main() {
        raiseOpenFileLimit()
        let watcher = ApplicationsFolderWatcher(tracksDestinations: true)
        watcher.onDeparture = { departure in
            handle(departure)
        }
        watcher.start()
        RunLoop.main.run()
    }

    private static func handle(_ departure: ApplicationsFolderWatcher.Departure) {
        guard RemovedAppWatchPolicy.shouldOfferReview(
            for: departure.app,
            bundleStillExists: departure.bundleStillExists,
            installedBundleIDs: departure.installedBundleIDs,
            otherCopyExists: RemovedAppWatchPolicy.otherCopyExists(of: departure.app),
            removedByPurge: RemovedAppHandoff.isIgnored(path: departure.app.id)
        ) else { return }
        guard let bundleID = departure.app.bundleID else { return }

        RemovedAppHandoff.enqueue(
            RemovedAppHandoff.Record(
                path: departure.app.id,
                bundleID: bundleID,
                name: departure.app.name,
                fileNumber: departure.fileNumber,
                removedAt: Date()
            )
        )
        // Prefer the running app when it is already open; otherwise launch it.
        NSWorkspace.shared.open(RemovedAppHandoff.launchURL)
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
