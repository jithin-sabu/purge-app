import Foundation

/// Filters a leftover scan into the rows the removed-app review sheet shows
/// (issue #65). Lives outside `RemovedAppWatchPolicy` so the background agent
/// can share that policy file without compiling uninstall models.
enum RemovedAppReviewFiltering {
    /// Never the bundle (it has already left), never a leftover another installed
    /// app also claims. Only identifier-anchored matches start ticked.
    nonisolated static func reviewItems(
        from scanned: [UninstallItem],
        owner: InstalledApp,
        survivors: [InstalledApp]
    ) -> [UninstallItem] {
        scanned.compactMap { item in
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
            return reviewed
        }
    }
}
