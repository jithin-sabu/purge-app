import Foundation
import SwiftUI

/// Rows from the last scan's saved file (#283), shown dimmed while the new scan
/// runs, each until the scan finds it again.
///
/// Kept apart from the store's live lists on purpose. Every clean, the menu bar, the
/// Shortcuts, scheduled cleaning and `hasSessionResults` read only the live lists, so
/// a row in here can never be selected, counted as this session's result, or moved
/// anywhere. Views draw these rows with the live rows' views, read only.
nonisolated struct LastScanRows: Equatable {
    /// When the scan that found each section finished.
    var savedAt: [LastScanSection: Date] = [:]
    var cacheItems: [CacheItem] = []
    var devTools: [DevTool] = []
    var simulatorDevices: [SimulatorDevice] = []
    var simulatorRuntimes: [SimulatorRuntime] = []
    var projectGroups: [ProjectGroup] = []
    var installedApps: [InstalledApp] = []
    /// An app's measured total from the last scan, by bundle path, shown dimmed on
    /// its live row until this session's measurement lands.
    var removableBytesByAppPath: [String: Int64] = [:]
    var orphanLeftovers: [UninstallItem] = []

    func isEmpty(_ section: LastScanSection) -> Bool {
        switch section {
        case .appCaches: return cacheItems.isEmpty
        case .devTools: return devTools.isEmpty
        case .simulators: return simulatorDevices.isEmpty
        case .runtimes: return simulatorRuntimes.isEmpty
        case .projects: return projectGroups.isEmpty
        case .apps: return installedApps.isEmpty
        case .leftovers: return orphanLeftovers.isEmpty
        }
    }

    /// The date the tab's subtitle gives, for the sections it shows that still
    /// hold saved rows.
    func oldestSavedAt(showing sections: [LastScanSection]) -> Date? {
        sections.filter { !isEmpty($0) }.compactMap { savedAt[$0] }.min()
    }

    mutating func clear(_ section: LastScanSection) {
        switch section {
        case .appCaches: cacheItems = []
        case .devTools: devTools = []
        case .simulators: simulatorDevices = []
        case .runtimes: simulatorRuntimes = []
        case .projects: projectGroups = []
        case .apps: installedApps = []
        case .leftovers: orphanLeftovers = []
        }
    }

    /// Restores what `snapshot` holds for `sections`. Rows this build can't rebuild
    /// are left out.
    init(_ snapshot: LastScanSnapshot, sections: Set<LastScanSection>) {
        for section in sections {
            switch section {
            case .appCaches:
                guard let saved = snapshot.appCaches else { continue }
                cacheItems = saved.rows.compactMap(\.restored)
                savedAt[section] = saved.savedAt
            case .devTools:
                guard let saved = snapshot.devTools else { continue }
                devTools = saved.rows.compactMap(\.restored)
                savedAt[section] = saved.savedAt
            case .simulators:
                guard let saved = snapshot.simulators else { continue }
                simulatorDevices = saved.rows.compactMap(\.restored)
                savedAt[section] = saved.savedAt
            case .runtimes:
                guard let saved = snapshot.runtimes else { continue }
                simulatorRuntimes = saved.rows.compactMap(\.restored)
                savedAt[section] = saved.savedAt
            case .projects:
                guard let saved = snapshot.projects else { continue }
                projectGroups = saved.rows.compactMap(\.restored)
                savedAt[section] = saved.savedAt
            case .apps:
                guard let saved = snapshot.apps else { continue }
                installedApps = saved.rows.compactMap(\.restored)
                for row in saved.rows {
                    if let total = row.removableBytes {
                        removableBytesByAppPath[row.bundleURL.path] = total
                    }
                }
                savedAt[section] = saved.savedAt
            case .leftovers:
                guard let saved = snapshot.leftovers else { continue }
                orphanLeftovers = saved.rows.compactMap(\.restored)
                savedAt[section] = saved.savedAt
            }
        }
    }

    init() {}
}

extension PurgeStore {
    // MARK: Loading

    /// Reads the saved file and shows its rows for every list this session has
    /// not finished scanning. Reading, and the link checks that keep a limited
    /// launch out of protected folders, run off the main thread.
    func loadLastScan() async {
        guard let lastScanStore else { return }
        refreshPermission()
        let access: ScanAccess = hasFullDiskAccess ? .full : .limited
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.readableLastScan(lastScanStore.load(), access: access)
        }.value
        guard let snapshot else { return }
        let sections = Set(LastScanSection.allCases.filter { !lastScanSavable.contains($0) })
        var rows = LastScanRows(snapshot, sections: sections)
        rows.savedAt = rows.savedAt.filter { !rows.isEmpty($0.key) }
        lastScanRows = rows
        // A scan that started first may have found some of them already.
        for section in LastScanSection.allCases {
            confirmLastScanRows(section)
        }
    }

    /// Drops the rows a launch must not show: any in a protected folder (never
    /// written, checked again in case), any behind a link into one when Purge has
    /// no Full Disk Access, and any the user has excluded since.
    nonisolated static func readableLastScan(_ snapshot: LastScanSnapshot?, access: ScanAccess) -> LastScanSnapshot? {
        guard var snapshot else { return nil }
        snapshot.removeRows { url in
            ProtectedLocations.contains(url)
                || !ProtectedLocations.isReadable(url, access: access)
                || ExcludedPathsStore.isExcluded(url)
        }
        return snapshot
    }

    // MARK: Following the scan

    /// A live list changed. Saved rows the scan has found again give way to the
    /// live ones, and a finished list is written back.
    func lastScanListDidChange(_ section: LastScanSection) {
        confirmLastScanRows(section)
        guard lastScanStore != nil else { return }
        lastScanDirty.insert(section)
        scheduleLastScanWrite()
    }

    /// Takes out each saved row the live list now has, matched by path so a row
    /// whose id moved (a cache folder grouped under its app, a tool with a new
    /// folder) still gives way.
    func confirmLastScanRows(_ section: LastScanSection) {
        guard !lastScanRows.isEmpty(section) else { return }
        switch section {
        case .appCaches:
            let liveIDs = Set(cacheItems.map(\.id))
            let live = Set(cacheItems.flatMap(\.standardizedPaths))
            let kept = lastScanRows.cacheItems.filter {
                !liveIDs.contains($0.id) && !$0.standardizedPaths.contains(where: live.contains)
            }
            if kept.count != lastScanRows.cacheItems.count { lastScanRows.cacheItems = kept }
        case .devTools:
            let liveIDs = Set(devTools.map(\.id))
            let live = Set(devTools.flatMap(\.standardizedPaths))
            let kept = lastScanRows.devTools.filter {
                !liveIDs.contains($0.id) && !$0.standardizedPaths.contains(where: live.contains)
            }
            if kept.count != lastScanRows.devTools.count { lastScanRows.devTools = kept }
        case .simulators:
            let live = Set(simulatorDevices.map(\.id)).union(runningSimulatorDevices.map(\.id))
            let kept = lastScanRows.simulatorDevices.filter { !live.contains($0.id) }
            if kept.count != lastScanRows.simulatorDevices.count { lastScanRows.simulatorDevices = kept }
        case .runtimes:
            let live = Set(simulatorRuntimes.map(\.id))
            let kept = lastScanRows.simulatorRuntimes.filter { !live.contains($0.id) }
            if kept.count != lastScanRows.simulatorRuntimes.count { lastScanRows.simulatorRuntimes = kept }
        case .projects:
            let live = Set(projectGroups.map(\.id))
            let kept = lastScanRows.projectGroups.filter { !live.contains($0.id) }
            if kept.count != lastScanRows.projectGroups.count { lastScanRows.projectGroups = kept }
        case .apps:
            let live = Set(installedApps.map(\.bundleURL.path))
            let kept = lastScanRows.installedApps.filter { !live.contains($0.bundleURL.path) }
            if kept.count != lastScanRows.installedApps.count { lastScanRows.installedApps = kept }
        case .leftovers:
            let live = Set(orphanLeftovers.map(\.path.path))
            let kept = lastScanRows.orphanLeftovers.filter { !live.contains($0.path.path) }
            if kept.count != lastScanRows.orphanLeftovers.count { lastScanRows.orphanLeftovers = kept }
        }
    }

    /// A scan of these lists started. Until it finishes, what they hold is partial
    /// and must not replace the saved file.
    func lastScanListsStarted(_ sections: [LastScanSection]) {
        lastScanSavable.subtract(sections)
    }

    /// A scan of these lists reached its normal end. Saved rows it did not find are
    /// gone from the Mac, so they fade out, and the lists are saved from now on.
    func lastScanListsFinished(_ sections: [LastScanSection], savable: Bool = true) {
        var rows = lastScanRows
        for section in sections {
            rows.clear(section)
            rows.savedAt[section] = nil
        }
        if rows != lastScanRows {
            withAnimation(.easeInOut(duration: 0.25)) { lastScanRows = rows }
        }
        guard savable else { return }
        // Every app's own total is measured now, so the saved ones are done too.
        if sections.contains(.apps), !lastScanRows.removableBytesByAppPath.isEmpty {
            lastScanRows.removableBytesByAppPath = [:]
        }
        let finishedAt = Date()
        for section in sections {
            lastScanSavable.insert(section)
            lastScanFinishedAt[section] = finishedAt
            lastScanDirty.insert(section)
        }
        scheduleLastScanWrite()
    }

    /// Rows a clean, an exclusion or a lost permission took off the live lists go
    /// from the saved rows on screen too.
    func removeLastScanRows(where isRemoved: (URL) -> Bool) {
        var rows = lastScanRows
        rows.cacheItems = rows.cacheItems.compactMap { item in
            let remaining = item.locations.filter { !isRemoved($0.path) }
            guard !remaining.isEmpty else { return nil }
            guard remaining.count != item.locations.count else { return item }
            return item.withLocations(remaining)
        }
        rows.devTools.removeAll { $0.paths.contains(where: isRemoved) }
        rows.simulatorDevices.removeAll { isRemoved($0.folderURL) }
        rows.simulatorRuntimes.removeAll { isRemoved($0.locationURL) }
        rows.projectGroups = rows.projectGroups.compactMap { group in
            var group = group
            group.artifacts.removeAll { isRemoved($0.path) }
            return group.artifacts.isEmpty ? nil : group
        }
        rows.installedApps.removeAll { isRemoved($0.bundleURL) }
        rows.orphanLeftovers.removeAll { isRemoved($0.path) }
        if rows != lastScanRows { lastScanRows = rows }
    }

    /// Takes paths a clean removed out of the saved file, so a list this session
    /// has not finished scanning never brings them back at the next launch.
    func forgetInLastScanFile(paths: Set<String>) {
        guard let lastScanStore, !paths.isEmpty else { return }
        Task.detached(priority: .utility) { lastScanStore.forget(paths: paths) }
    }

    /// Whether every list behind the category's figure finished its latest scan.
    /// `hasSessionCacheScan` stays true through a rescan that is then cancelled
    /// (access granted mid-scan, a standalone pass replacing a full one), so
    /// `isSettled` alone would let the partial lists rewrite the saved total the
    /// next launch shows (#283).
    func hasFinishedLists(for category: OverviewCategory) -> Bool {
        switch category {
        case .appCaches: return lastScanSavable.contains(.appCaches)
        case .devTools: return lastScanSavable.isSuperset(of: [.devTools, .simulators, .runtimes, .projects])
        case .largeFiles, .apps, .leftovers: return true
        }
    }

    // MARK: Writing

    private func scheduleLastScanWrite() {
        guard lastScanWriteTask == nil, !lastScanDirty.isDisjoint(with: lastScanSavable) else { return }
        lastScanWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            self.lastScanWriteTask = nil
            let sections = self.lastScanDirty.intersection(self.lastScanSavable)
            self.lastScanDirty.subtract(sections)
            guard !sections.isEmpty, let store = self.lastScanStore else { return }
            let snapshot = self.makeLastScanSnapshot(sections)
            await Task.detached(priority: .utility) { store.save(sections, from: snapshot) }.value
            self.lastScanWritesFinished &+= 1
        }
    }

    /// The live lists for `sections`, less any row with a path in a protected
    /// folder. Dated by when each list's scan finished, not by this write, so a
    /// clean afterwards doesn't make the rows look newer than they are.
    func makeLastScanSnapshot(_ sections: Set<LastScanSection>) -> LastScanSnapshot {
        var snapshot = LastScanSnapshot(appBuild: LastScanSnapshot.currentAppBuild())
        for section in sections {
            let savedAt = lastScanFinishedAt[section] ?? Date()
            switch section {
            case .appCaches:
                snapshot.appCaches = .init(savedAt: savedAt, rows: cacheItems
                    .filter { LastScanSnapshot.isWritable($0.paths) }
                    .map(SavedCacheItem.init))
            case .devTools:
                snapshot.devTools = .init(savedAt: savedAt, rows: devTools
                    .filter { $0.isDetected && LastScanSnapshot.isWritable($0.paths) }
                    .map(SavedDevTool.init))
            case .simulators:
                snapshot.simulators = .init(savedAt: savedAt, rows: simulatorDevices
                    .filter { LastScanSnapshot.isWritable([$0.folderURL]) }
                    .map(SavedSimulatorDevice.init))
            case .runtimes:
                snapshot.runtimes = .init(savedAt: savedAt, rows: simulatorRuntimes
                    .filter { LastScanSnapshot.isWritable([$0.locationURL]) }
                    .map(SavedSimulatorRuntime.init))
            case .projects:
                snapshot.projects = .init(savedAt: savedAt, rows: projectGroups
                    .map { SavedProjectGroup($0) }
                    .filter { LastScanSnapshot.isWritable($0.urls) })
            case .apps:
                snapshot.apps = .init(savedAt: savedAt, rows: installedApps
                    .filter { LastScanSnapshot.isWritable([$0.bundleURL]) }
                    .map { app in SavedInstalledApp(app, removableBytes: removableBytesByAppID[app.id]) })
            case .leftovers:
                snapshot.leftovers = .init(savedAt: savedAt, rows: orphanLeftovers
                    .filter { LastScanSnapshot.isWritable([$0.path]) }
                    .map(SavedLeftover.init))
            }
        }
        return snapshot
    }
}
