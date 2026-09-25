import AppKit
import Foundation

/// Background agent that watches Applications folders when Purge itself is not
/// running (issue #65). Records each real removal and opens Purge to review
/// leftovers. Registered through `SMAppService.agent` when the Settings toggle
/// is on; launchd keeps it alive across logins.
@main
enum PurgeWatchMain {
    static func main() {
        let watcher = ApplicationsFolderWatcher()
        watcher.onDeparture = { departure in
            handle(departure)
        }
        watcher.start()
        RunLoop.main.run()
    }

    private static func handle(_ departure: ApplicationsFolderWatcher.Departure) {
        let removedByPurge = RemovedAppHandoff.isIgnored(path: departure.app.id)
        guard RemovedAppWatchPolicy.shouldOfferReview(
            for: departure.app,
            bundleStillExists: departure.bundleStillExists,
            installedBundleIDs: departure.installedBundleIDs,
            removedByPurge: removedByPurge
        ) else { return }
        guard let bundleID = departure.app.bundleID else { return }

        RemovedAppHandoff.enqueue(
            RemovedAppHandoff.Record(
                path: departure.app.id,
                bundleID: bundleID,
                name: departure.app.name
            )
        )
        // Prefer the running app when it is already open; otherwise launch it.
        NSWorkspace.shared.open(RemovedAppHandoff.launchURL)
    }
}
