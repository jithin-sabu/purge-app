import Foundation

/// Keeps `appSuiteGroups` in step with the app list (#155). Grouping is display
/// only: nothing here touches `installedApps`, which stays the full list the
/// shared-leftover checks read.
extension PurgeStore {
    func appSuiteInputsDidChange() {
        let live = Set(installedApps.map(\.bundleURL.path))
        let apps = installedApps + lastScanRows.installedApps.filter { !live.contains($0.bundleURL.path) }
        // A size or date update leaves the paths and folders alone, so it rebuilds nothing.
        let inputs = AppSuiteInputs(paths: apps.map(\.bundleURL.path).sorted(), roots: appFolderPaths.roots)
        guard inputs != appSuiteInputs else { return }
        appSuiteInputs = inputs

        appSuiteGroupingTask?.cancel()
        let roots = inputs.roots
        let known = appTeamIDByPath
        let reader = appTeamIDReader
        appSuiteGroupingTask = Task { [weak self] in
            let (groups, teams) = await Task.detached(priority: .utility) {
                Self.buildSuiteGroups(apps: apps, roots: roots, known: known, reader: reader)
            }.value
            guard !Task.isCancelled, let self else { return }
            appTeamIDByPath.merge(teams) { _, new in new }
            if groups != appSuiteGroups { appSuiteGroups = groups }
        }
    }

    /// Reads the team only for apps that sit in a folder, once per path.
    nonisolated private static func buildSuiteGroups(
        apps: [InstalledApp],
        roots: [String],
        known: [String: String],
        reader: @Sendable (URL) -> String?
    ) -> ([AppSuiteGroup], [String: String]) {
        var teams = known
        let groups = AppSuiteGrouping.groups(apps: apps, roots: roots) { url in
            if let team = teams[url.path] { return team.isEmpty ? nil : team }
            let team = reader(url) ?? ""
            teams[url.path] = team
            return team.isEmpty ? nil : team
        }
        return (groups, teams)
    }

    /// The groups' entries for `apps`, in the order given.
    func appListEntries(_ apps: [InstalledApp]) -> [AppListEntry] {
        AppSuiteGrouping.entries(apps: apps, groups: appSuiteGroups)
    }

    /// The groups that hold any of `appIDs`, and every listed app in them, for
    /// the review sheet's warning.
    func suiteContext(for appIDs: Set<String>) -> (groups: [AppSuiteGroup], apps: [InstalledApp]) {
        let groups = appSuiteGroups.filter { !appIDs.isDisjoint(with: $0.appIDs) }
        let members = Set(groups.flatMap(\.appIDs))
        return (groups, installedApps.filter { members.contains($0.id) })
    }

    /// Opens a suite's own uninstaller, closing the review sheet first when it
    /// was opened from there.
    func openSuiteUninstaller(at url: URL) {
        uninstallPlan = nil
        appLauncher(url)
    }
}

/// The bundle paths and folders `appSuiteGroups` was last built from.
nonisolated struct AppSuiteInputs: Equatable {
    var paths: [String] = []
    var roots: [String] = []
}
