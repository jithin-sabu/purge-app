import Foundation

/// Filters a leftover scan into the rows the removed-app review sheet shows
/// (issue #65). Lives outside `RemovedAppWatchPolicy` so the background agent
/// can share that policy file without compiling uninstall models.
enum RemovedAppReviewFiltering {
    /// Never the bundle (it has already left), never a leftover another installed
    /// app also claims.
    ///
    /// Only identifier-anchored matches inside the home folder start ticked. This
    /// review opens unprompted from a record another process could have written, so
    /// anything outside home (`/Library/LaunchDaemons`, shared Application Support)
    /// is listed but left for the user to tick. Those are the paths that can need
    /// the administrator helper, and it must never act on a default choice here.
    nonisolated static func reviewItems(
        from scanned: [UninstallItem],
        owner: InstalledApp,
        survivors: [InstalledApp],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [UninstallItem] {
        let homePrefix = home.standardizedFileURL.path + "/"
        return scanned.compactMap { item in
            guard item.category != .bundle else { return nil }
            let sharedWith = AppUninstallScanPolicy.claimant(
                forLeftoverName: item.path.lastPathComponent,
                category: item.category,
                ownerID: owner.id,
                among: survivors
            )
            guard sharedWith == nil else { return nil }
            var reviewed = item
            reviewed.isSelected = item.matchReason.isHighConfidence
                && item.path.standardizedFileURL.path.hasPrefix(homePrefix)
            return reviewed
        }
    }
}
