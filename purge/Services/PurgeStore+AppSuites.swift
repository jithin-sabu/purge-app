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

        // Rebuilds run one at a time: the new one waits for the one it replaces,
        // which stops at its next signature read and keeps what it read in the
        // cache, so no signature is read twice or by two builds at once.
        let previous = appSuiteGroupingTask
        previous?.cancel()
        let roots = inputs.roots
        appSuiteGroupingTask = Task { [weak self] in
            await previous?.value
            // A scan lists apps a few at a time; wait for a pause so one build
            // covers the burst instead of one per app.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let known = self?.appTeamIDByPath, let reader = self?.appTeamIDReader else { return }
            let (groups, teams) = await Self.buildSuiteGroups(apps: apps, roots: roots, known: known, reader: reader)
            guard let self else { return }
            // Teams read before a newer build took over still go in the cache.
            appTeamIDByPath.merge(teams) { _, new in new }
            guard !Task.isCancelled, let groups else { return }
            if groups != appSuiteGroups { appSuiteGroups = groups }
        }
    }

    /// Reads the team only for apps that sit in a folder, once per path. Stops
    /// reading once a newer build cancels it, and then returns no groups.
    @concurrent
    nonisolated private static func buildSuiteGroups(
        apps: [InstalledApp],
        roots: [String],
        known: [String: String],
        reader: @Sendable (URL) -> String?
    ) async -> ([AppSuiteGroup]?, [String: String]) {
        var teams = known
        var stopped = false
        let groups = AppSuiteGrouping.groups(apps: apps, roots: roots) { url in
            if let team = teams[url.path] { return team.isEmpty ? nil : team }
            if stopped || Task.isCancelled {
                stopped = true
                return nil
            }
            let team = reader(url) ?? ""
            teams[url.path] = team
            return team.isEmpty ? nil : team
        }
        return (stopped ? nil : groups, teams)
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
