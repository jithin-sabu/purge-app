import Foundation

/// Apps from one vendor that share a folder under an app root, shown as one
/// entry in the App Uninstaller (#155), such as the four apps in
/// `/Applications/DaVinci Resolve`. Display only: every member stays in
/// `PurgeStore.installedApps`, which is also the list that holds back a
/// leftover another installed app still uses.
nonisolated struct AppSuiteGroup: Identifiable, Hashable, Sendable {
    /// The folder's path, such as `/Applications/DaVinci Resolve`.
    let id: String
    /// The folder's name, such as "DaVinci Resolve".
    let name: String
    /// Member app ids (`InstalledApp.id`), in path order.
    let appIDs: [String]
    /// The member that is the vendor's own uninstaller, such as
    /// `Uninstall Resolve.app`. Nil when the folder has none.
    let uninstallerID: String?

    var folderURL: URL { URL(fileURLWithPath: id) }
}

/// One entry in the uninstaller's app list: an app on its own, or a group with
/// its member apps.
nonisolated enum AppListEntry: Identifiable {
    case app(InstalledApp)
    case group(AppSuiteGroup, [InstalledApp])

    var id: String {
        switch self {
        case .app(let app): return app.id
        case .group(let group, _): return "group:" + group.id
        }
    }

    /// Every app this entry stands for.
    var apps: [InstalledApp] {
        switch self {
        case .app(let app): return [app]
        case .group(_, let apps): return apps
        }
    }

    /// The name the list sorts on: the app's, or the folder's.
    var sortName: String {
        switch self {
        case .app(let app): return app.name
        case .group(let group, _): return group.name
        }
    }
}

/// Decides which apps form a group (#155). The rule:
///
/// - The key is the first folder under the app's root, or the first folder
///   under `Utilities` when the app sits deeper inside `Utilities`. An app
///   directly in a root, or directly in `Utilities`, has no key.
/// - A key becomes a group only when it holds two or more apps and every one is
///   signed by the same team. A folder of apps from different developers, or of
///   unsigned apps, stays flat, and a team never joins two folders.
nonisolated enum AppSuiteGrouping {
    static let utilitiesFolderName = "Utilities"

    /// The folder an app would be grouped under, or nil when it is never grouped.
    /// - Parameters:
    ///   - appPath: the bundle path, as listed.
    ///   - roots: the app folders Purge reads. The longest one that holds the
    ///     app is its root, so an added folder inside a drive's folder wins.
    static func groupKey(appPath: String, roots: [String]) -> String? {
        guard let root = roots.filter({ appPath.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else {
            return nil
        }
        let relative = appPath.dropFirst(root.count + 1)
        // Folders between the root and the bundle; the last part is the bundle.
        let folders = relative.split(separator: "/").dropLast().map(String.init)
        guard let first = folders.first else { return nil }
        if first == utilitiesFolderName {
            guard folders.count >= 2 else { return nil }
            return root + "/" + first + "/" + folders[1]
        }
        return root + "/" + first
    }

    /// The groups among `apps`.
    /// - Parameter teamID: the signing team of a bundle, or nil when it is
    ///   unsigned or can't be read. Asked only for apps that have a key.
    static func groups(
        apps: [InstalledApp],
        roots: [String],
        teamID: (URL) -> String?
    ) -> [AppSuiteGroup] {
        var byKey: [String: [InstalledApp]] = [:]
        for app in apps {
            guard let key = groupKey(appPath: app.bundleURL.path, roots: roots) else { continue }
            byKey[key, default: []].append(app)
        }
        var groups: [AppSuiteGroup] = []
        for (key, members) in byKey where members.count >= 2 {
            let teams = members.map { teamID($0.bundleURL)?.uppercased() }
            guard let team = teams.first ?? nil, !team.isEmpty, teams.allSatisfy({ $0 == team }) else { continue }
            let sorted = members.sorted { $0.bundleURL.path < $1.bundleURL.path }
            groups.append(AppSuiteGroup(
                id: key,
                name: (key as NSString).lastPathComponent,
                appIDs: sorted.map(\.id),
                uninstallerID: uninstaller(in: sorted)?.id
            ))
        }
        return groups.sorted { $0.id < $1.id }
    }

    /// The vendor's own uninstaller among a group's apps: the first whose file
    /// name or bundle id contains "uninstall", such as `Uninstall Resolve.app`,
    /// `Creative Cloud Uninstaller.app`, or `Autodesk Uninstall Tool.app`.
    static func uninstaller(in apps: [InstalledApp]) -> InstalledApp? {
        apps
            .sorted { $0.bundleURL.path < $1.bundleURL.path }
            .first { app in
                app.bundleURL.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains("uninstall")
                    || (app.bundleID?.localizedCaseInsensitiveContains("uninstall") ?? false)
            }
    }

    /// `apps` as list entries: each group's members folded into one entry where
    /// the first member was, every other app on its own. Every app in `apps`
    /// appears exactly once, and a group whose members are not all in `apps`
    /// keeps only the ones that are; one left alone shows as a plain app.
    static func entries(apps: [InstalledApp], groups: [AppSuiteGroup]) -> [AppListEntry] {
        var groupByAppID: [String: AppSuiteGroup] = [:]
        for group in groups {
            for id in group.appIDs { groupByAppID[id] = group }
        }
        var membersByGroup: [String: [InstalledApp]] = [:]
        for app in apps {
            if let group = groupByAppID[app.id] { membersByGroup[group.id, default: []].append(app) }
        }
        var entries: [AppListEntry] = []
        var placed = Set<String>()
        for app in apps {
            guard let group = groupByAppID[app.id], let members = membersByGroup[group.id], members.count >= 2 else {
                entries.append(.app(app))
                continue
            }
            if placed.insert(group.id).inserted {
                entries.append(.group(group, members))
            }
        }
        return entries
    }
}

/// A removal the review sheet warns about (#155): it takes the vendor's own
/// uninstaller, or only some of a group's other apps while that uninstaller
/// stays. Removing parts by hand can stop the uninstaller from removing the
/// rest, and only it removes what the vendor installed outside the folder.
nonisolated struct PartialSuite: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// The removal takes the uninstaller itself.
        case uninstallerRemoved
        /// The removal takes some, not all, of the other apps.
        case someParts
    }

    let kind: Kind
    let groupName: String
    let uninstallerName: String
    let uninstallerURL: URL
    /// Apps other than the uninstaller that the removal takes.
    let pickedCount: Int
    /// Apps in the group other than the uninstaller.
    let totalCount: Int
}

extension AppSuiteGrouping {
    /// The groups with an uninstaller that a removal of `removingIDs` should
    /// warn about. The uninstaller never counts as one of the parts, and only
    /// apps in `apps`, the listed ones, count at all.
    static func partialSuites(
        removingIDs: Set<String>,
        groups: [AppSuiteGroup],
        apps: [InstalledApp]
    ) -> [PartialSuite] {
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.compactMap { group in
            guard let uninstallerID = group.uninstallerID, let uninstaller = byID[uninstallerID] else { return nil }
            // Only listed apps count: a saved row from the last scan can't be
            // ticked, so it never makes a full pick look partial.
            let parts = group.appIDs.filter { $0 != uninstallerID && byID[$0] != nil }
            let picked = parts.filter(removingIDs.contains).count
            let kind: PartialSuite.Kind
            if removingIDs.contains(uninstallerID) {
                kind = .uninstallerRemoved
            } else if picked > 0, picked < parts.count {
                kind = .someParts
            } else {
                return nil
            }
            return PartialSuite(
                kind: kind,
                groupName: group.name,
                uninstallerName: uninstaller.name,
                uninstallerURL: uninstaller.bundleURL,
                pickedCount: picked,
                totalCount: parts.count
            )
        }
    }
}
