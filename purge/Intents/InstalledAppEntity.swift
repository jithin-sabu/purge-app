import AppIntents
import Foundation

/// An installed app, as the uninstaller lists it. The id is the bundle path,
/// the same value as `InstalledApp.id`, so it drops straight into the
/// uninstaller's selection.
struct InstalledAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let defaultQuery = InstalledAppQuery()

    let id: String
    let name: String
    let bundleID: String?

    init(_ app: AppUninstallScanner.DiscoveredApp) {
        id = app.bundleURL.standardizedFileURL.path
        name = app.name
        bundleID = app.bundleID
    }

    var displayRepresentation: DisplayRepresentation {
        if let bundleID {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(bundleID)")
        }
        return DisplayRepresentation(title: "\(name)")
    }
}

/// Finds apps for the picker and for Spotlight, from the uninstaller's own
/// index. `@concurrent` keeps the folder reads off the main thread.
struct InstalledAppQuery: EntityStringQuery {
    @concurrent
    func entities(for identifiers: [String]) async throws -> [InstalledAppEntity] {
        let wanted = Set(identifiers)
        return await InstalledAppIndex.shared.apps().filter { wanted.contains($0.id) }
    }

    @concurrent
    func entities(matching string: String) async throws -> [InstalledAppEntity] {
        InstalledAppIndex.matching(string, in: await InstalledAppIndex.shared.apps())
    }

    @concurrent
    func suggestedEntities() async throws -> [InstalledAppEntity] {
        await InstalledAppIndex.shared.apps()
    }
}

/// Holds the app list for a few seconds. Spotlight asks again on every
/// keystroke, and reading a couple of hundred Info.plists each time adds up.
actor InstalledAppIndex {
    static let shared = InstalledAppIndex()

    private var cached: [InstalledAppEntity] = []
    private var cachedAt: Date?
    private let lifetime: TimeInterval = 30

    func apps(now: Date = Date()) -> [InstalledAppEntity] {
        if let cachedAt, now.timeIntervalSince(cachedAt) < lifetime {
            return cached
        }
        cached = AppUninstallScanner.discoverInstalledApps()
            .map(InstalledAppEntity.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cachedAt = now
        return cached
    }

    /// Matches the way the uninstaller's search box does: name or bundle id.
    nonisolated static func matching(_ text: String, in apps: [InstalledAppEntity]) -> [InstalledAppEntity] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query)
                || ($0.bundleID?.lowercased().contains(query) ?? false)
        }
    }
}
