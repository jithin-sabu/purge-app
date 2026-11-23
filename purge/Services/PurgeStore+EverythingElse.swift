import AppKit
import Foundation

/// Which page the Overview tab shows.
nonisolated enum OverviewPage: Equatable, Sendable {
    case summary
    /// Everything else opened as its own page: the map above the list (#159).
    case everythingElse
}

/// Where the Everything else walk stands right now.
nonisolated enum EverythingElsePhase: Equatable, Sendable {
    case notMeasured
    /// Waiting in the scan queue behind another step.
    case waiting
    case measuring
    case ready
}

/// Everything the Everything else breakdown is computed from, so it is rebuilt
/// only when one of these changes rather than on every render.
struct EverythingElseBreakdownKey: Equatable {
    let inputsRevision: Int
    let measurementRevision: Int
    let everythingElseBytes: Int64
    let trashBytes: Int64?
    let excludedPaths: Set<String>
}

/// A folder opened on the map being sized, and how far along, 0...1 (#437).
nonisolated struct EverythingElseFolderSizing: Equatable, Sendable {
    let path: String
    let name: String
    var fraction: Double
}

/// Everything an opened folder's tiles are computed from.
struct EverythingElseLevelKey: Equatable {
    let openPaths: [String]
    let contentsRevision: Int
    let inputsRevision: Int
    let measurementRevision: Int
    let excludedPaths: Set<String>
}

/// The Everything else walk (#159, #220): measuring on demand, and the read-only
/// breakdown the drill-in shows. There is no delete path in this file, and the
/// views built on it have none either; the only ways out of these screens are
/// Show in Finder, Copy Path, opening another app or tab, and excluding a folder
/// from scans.
extension PurgeStore {
    var everythingElsePhase: EverythingElsePhase {
        if scanQueue.active == .everythingElse || isMeasuringEverythingElse {
            return .measuring
        }
        if scanQueue.isQueued(.everythingElse) {
            return .waiting
        }
        return everythingElseMeasurement?.isComplete == true ? .ready : .notMeasured
    }

    /// The Overview row was clicked: Everything else as its own page, measured
    /// if this session has no result yet.
    func showEverythingElsePage() {
        closeEverythingElseFolders(keeping: 0)
        overviewPage = .everythingElse
        selectedTab = .overview
        requestScanIfNeeded(.everythingElse)
    }

    func showOverviewSummary() {
        overviewPage = .summary
    }

    /// Measure again, ahead of anything waiting in the queue.
    func measureEverythingElseAgain() {
        requestScan(.everythingElse)
    }

    /// Stops the walk, running or waiting, and leaves the rest of the queue alone.
    /// The page goes back to the last walk that finished, or to "Not measured".
    func stopEverythingElse() {
        scanQueue.remove(.everythingElse)
        scanQueueForcedSteps.remove(.everythingElse)
        guard scanQueue.active == .everythingElse else { return }
        // The runner awaits this step, then moves on to whatever is waiting.
        scanQueueStepTask?.cancel()
    }

    /// The scan queue's Everything else step. Groups fill in as their roots
    /// finish. A walk that is stopped leaves nothing half-measured behind: the
    /// last finished walk comes back, or none.
    func measureEverythingElse() async {
        refreshPermission()
        everythingElseMeasureGeneration += 1
        let generation = everythingElseMeasureGeneration
        let previous = everythingElseMeasurement?.isComplete == true ? everythingElseMeasurement : nil
        isMeasuringEverythingElse = true
        // Opened folders were claimed against the last walk's figures.
        closeEverythingElseFolders(keeping: 0)
        everythingElseFolderContents = [:]
        everythingElsePassedThrough = []
        everythingElseFolderContentsRevision &+= 1
        let access: ScanAccess = hasFullDiskAccess ? .full : .limited
        var measurement = EverythingElseMeasurement(access: access)
        everythingElseMeasurement = measurement
        everythingElseMeasurementRevision &+= 1
        defer {
            if everythingElseMeasureGeneration == generation {
                isMeasuringEverythingElse = false
            }
        }

        for await event in scanSources.everythingElse(access) {
            guard everythingElseMeasureGeneration == generation else { return }
            guard !Task.isCancelled else { break }
            measurement.apply(event)
            everythingElseMeasurement = measurement
            // Progress inside a root changes no figure, so the breakdown and
            // the map stay cached; only the ring moves.
            if case .progress = event { continue }
            everythingElseMeasurementRevision &+= 1
        }
        guard everythingElseMeasureGeneration == generation else { return }
        if Task.isCancelled {
            everythingElseMeasurement = previous
            everythingElseMeasurementRevision &+= 1
            return
        }
        measurement.isComplete = true
        measurement.completedAt = Date()
        everythingElseMeasurement = measurement
        everythingElseMeasurementRevision &+= 1
    }

    /// The unsorted space split into groups, or nil before the first measure.
    /// Claims against the five categories as they stand now, so a rescan of App
    /// Caches moves bytes between App Data and App Caches without a new walk.
    /// `trashBytes` is `TrashStore`'s figure, nil when the Trash can't be read.
    func everythingElseBreakdown(totalBytes: Int64, freeBytes: Int64, trashBytes: Int64?) -> EverythingElseBreakdown? {
        guard let measurement = everythingElseMeasurement else { return nil }
        let overview = overviewBreakdown(totalBytes: totalBytes, freeBytes: freeBytes)
        let key = EverythingElseBreakdownKey(
            inputsRevision: categoryInputsRevision,
            measurementRevision: everythingElseMeasurementRevision,
            everythingElseBytes: overview.everythingElseBytes,
            trashBytes: trashBytes,
            excludedPaths: excludedPaths
        )
        if let cached = everythingElseBreakdownCache, cached.key == key {
            return cached.breakdown
        }
        // Keys are symlink-resolved, which spells `/var` where the walk says
        // `/private/var`; both go through the same normalization first.
        let exclusions = ScanExclusions(keys: Set(excludedPaths.map(OverviewSizedItem.normalized)))
        let breakdown = EverythingElseBreakdown(
            measurement: measurement.droppingFolders { exclusions.covers(path: $0) },
            claimedFirst: overviewLiveItemsInClaimOrder(),
            everythingElseBytes: overview.everythingElseBytes,
            trashBytes: trashBytes,
            includesRecordedFigures: overviewShowsRecordedFigures()
        )
        everythingElseBreakdownCache = (key, breakdown)
        return breakdown
    }

    /// "Exclude from Scans" on an Everything else row: the folder joins the
    /// Excluded Paths list in Settings, where it can be put back, and every tab's
    /// rows under it go too, so nothing excluded stays ready to clean. Nothing
    /// is deleted; the remainder absorbs its bytes.
    func hideFromEverythingElse(_ folder: EverythingElseFolder) {
        // An opened folder at or under the excluded one closes with it.
        if let index = everythingElseOpenFolders.firstIndex(where: { PathContainment.isSameOrInside($0.path, folder.path) }) {
            closeEverythingElseFolders(keeping: index)
        }
        excludeFoldersFromScans([folder.url])
    }

    // MARK: Opening a folder (#437)

    /// Whether a folder tile can be opened to show the folders inside it. A
    /// folder inside an opened one can when its sizing found it could; a tile
    /// on the whole map, by its group and the access the scan has now.
    func everythingElseCanOpen(_ folder: EverythingElseFolder) -> Bool {
        let path = OverviewSizedItem.normalized(folder.path)
        if let open = everythingElseOpenFolders.last,
           let contents = everythingElseFolderContents[OverviewSizedItem.normalized(open.path)],
           contents.folders.contains(where: { $0.path == path }) {
            return contents.openablePaths.contains(path)
        }
        // Asked for every tile on every render, so string work only: a URL
        // made without `isDirectory` would stat the disk to find out.
        return EverythingElseFolderOpening.canOpen(
            URL(fileURLWithPath: path, isDirectory: true),
            group: folder.group,
            access: hasFullDiskAccess ? .full : .limited,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// How long an open waits for the folder's sizing before the map moves. A
    /// folder sized within it zooms straight into its tiles; a slower one zooms
    /// into its own tile and is measured under the glass.
    static let everythingElseOpenGrace: UInt64 = 250_000_000

    /// A folder that holds only one folder opens through to it, this many
    /// steps at most, so a chain like `Metadata/CoreSpotlight` is one click.
    static let everythingElsePassThroughLimit = 8
    /// Passed through when everything beside that one folder is under this
    /// share of the level: a few loose files or an empty folder would
    /// otherwise stop it, and the map would show one tile anyway.
    static let everythingElsePassThroughShare = 0.01

    /// Opens a folder on the map: its folders replace the map, sized now unless
    /// this walk already sized them. Only a folder on the map as it stands can
    /// be opened, so the path always runs down from a tile. The map waits
    /// `everythingElseOpenGrace` for the sizing before it moves, and a folder
    /// whose only content is one folder that opens is passed through.
    func openEverythingElseFolder(_ folder: EverythingElseFolder) {
        guard everythingElsePhase == .ready, everythingElseCanOpen(folder) else { return }
        everythingElseOpenGeneration += 1
        let generation = everythingElseOpenGeneration
        everythingElsePendingFolders = [folder]
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.everythingElseOpenGrace)
            guard let self, self.everythingElseOpenGeneration == generation else { return }
            self.showPendingEverythingElseFolders()
        }
        continueOpeningEverythingElseFolder(folder)
    }

    /// Goes back up the path: `count` folders stay open, 0 shows the whole map.
    /// A folder that was passed through closes too, since its level is one
    /// tile filling the map, with nothing to zoom back out to. An open still
    /// waiting to show is dropped, and a sizing for a folder that closes stops.
    func closeEverythingElseFolders(keeping count: Int) {
        everythingElseOpenGeneration += 1
        everythingElsePendingFolders = []
        var kept = max(0, min(count, everythingElseOpenFolders.count))
        while kept > 0, kept < everythingElseOpenFolders.count,
              everythingElsePassedThrough.contains(OverviewSizedItem.normalized(everythingElseOpenFolders[kept - 1].path)) {
            kept -= 1
        }
        if kept < everythingElseOpenFolders.count {
            everythingElseOpenFolders.removeSubrange(kept...)
        }
        if let sizing = everythingElseFolderSizing,
           !everythingElseOpenFolders.contains(where: { OverviewSizedItem.normalized($0.path) == sizing.path }) {
            cancelEverythingElseFolderSizing()
        }
    }

    /// The tiles for the folder open now, or nil on the whole map and while its
    /// sizing runs. Claimed against the categories and the groups before the
    /// outermost open folder, as the breakdown claims, so the tiles add up to it.
    func everythingElseOpenLevel() -> EverythingElseFolderLevel? {
        guard let top = everythingElseOpenFolders.first, let open = everythingElseOpenFolders.last else { return nil }
        let key = EverythingElseLevelKey(
            openPaths: everythingElseOpenFolders.map(\.path),
            contentsRevision: everythingElseFolderContentsRevision,
            inputsRevision: categoryInputsRevision,
            measurementRevision: everythingElseMeasurementRevision,
            excludedPaths: excludedPaths
        )
        if let cached = everythingElseLevelCache, cached.key == key {
            return cached.level
        }
        let level = everythingElseLevel(for: open, top: top)
        everythingElseLevelCache = (key, level)
        return level
    }

    /// The tiles for `folder` once it is sized, counted below `top`, the
    /// outermost folder on its path.
    private func everythingElseLevel(for folder: EverythingElseFolder, top: EverythingElseFolder) -> EverythingElseFolderLevel? {
        guard let measurement = everythingElseMeasurement,
              let contents = everythingElseFolderContents[OverviewSizedItem.normalized(folder.path)]
        else { return nil }
        let exclusions = ScanExclusions(keys: Set(excludedPaths.map(OverviewSizedItem.normalized)))
        let claims = measurement
            .droppingFolders { exclusions.covers(path: $0) }
            .claims(before: top.path, claimedFirst: overviewLiveItemsInClaimOrder())
        return EverythingElseFolderLevel(
            folder: folder,
            contents: contents.droppingFolders { exclusions.covers(path: $0) },
            claims: claims
        )
    }

    /// The folders opened but not shown yet join the path, so the map moves.
    private func showPendingEverythingElseFolders() {
        guard !everythingElsePendingFolders.isEmpty else { return }
        everythingElseOpenFolders.append(contentsOf: everythingElsePendingFolders)
        everythingElsePendingFolders = []
    }

    /// Sizes `folder` unless this walk already did, then lands it.
    private func continueOpeningEverythingElseFolder(_ folder: EverythingElseFolder) {
        if everythingElseFolderContents[OverviewSizedItem.normalized(folder.path)] != nil {
            cancelEverythingElseFolderSizing()
            everythingElseFolderLanded(folder)
        } else {
            sizeEverythingElseFolder(folder)
        }
    }

    /// `folder` is sized. If nearly all it holds is one folder that opens,
    /// that one opens too: still waiting with it if the map has not moved yet, on the
    /// map at once if it has. Otherwise whatever is waiting is shown.
    private func everythingElseFolderLanded(_ folder: EverythingElseFolder) {
        let opened = everythingElseOpenFolders + everythingElsePendingFolders
        if opened.count < Self.everythingElsePassThroughLimit,
           let top = opened.first,
           let level = everythingElseLevel(for: folder, top: top),
           let biggest = level.items.first,
           case .folder(let only) = biggest.kind,
           level.openablePaths.contains(OverviewSizedItem.normalized(only.path)),
           Double(level.bytes - biggest.bytes) < Self.everythingElsePassThroughShare * Double(level.bytes) {
            everythingElsePassedThrough.insert(OverviewSizedItem.normalized(folder.path))
            if everythingElsePendingFolders.isEmpty {
                everythingElseOpenFolders.append(only)
            } else {
                everythingElsePendingFolders.append(only)
            }
            continueOpeningEverythingElseFolder(only)
            return
        }
        everythingElseOpenGeneration += 1
        showPendingEverythingElseFolders()
    }

    private func sizeEverythingElseFolder(_ folder: EverythingElseFolder) {
        cancelEverythingElseFolderSizing()
        everythingElseFolderGeneration += 1
        let generation = everythingElseFolderGeneration
        let path = OverviewSizedItem.normalized(folder.path)
        everythingElseFolderSizing = EverythingElseFolderSizing(path: path, name: folder.displayName, fraction: 0)
        let access: ScanAccess = hasFullDiskAccess ? .full : .limited
        let sources = scanSources
        // Called on a sizing thread. The store outlives any sizing, so holding
        // it here until the sizing ends costs nothing.
        let onProgress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in
                guard self.everythingElseFolderGeneration == generation,
                      var sizing = self.everythingElseFolderSizing, sizing.path == path
                else { return }
                // Folders finish on their own threads; the figure only moves forward.
                sizing.fraction = max(sizing.fraction, min(1, fraction))
                self.everythingElseFolderSizing = sizing
            }
        }
        everythingElseFolderTask = Task { [weak self] in
            let contents = await sources.everythingElseFolder(folder.url, folder.group, access, onProgress)
            guard let self, self.everythingElseFolderGeneration == generation, !Task.isCancelled else { return }
            self.everythingElseFolderSizing = nil
            self.everythingElseFolderTask = nil
            guard let contents else {
                // A folder that can't be read closes again rather than showing
                // an empty map that would read as an empty folder. One still
                // waiting goes, and the folders above it show.
                if let index = self.everythingElsePendingFolders.firstIndex(where: { OverviewSizedItem.normalized($0.path) == path }) {
                    self.everythingElsePendingFolders.removeSubrange(index...)
                    self.everythingElseOpenGeneration += 1
                    self.showPendingEverythingElseFolders()
                } else if let index = self.everythingElseOpenFolders.firstIndex(where: { OverviewSizedItem.normalized($0.path) == path }) {
                    self.closeEverythingElseFolders(keeping: index)
                }
                return
            }
            self.everythingElseFolderContents[path] = contents
            self.everythingElseFolderContentsRevision &+= 1
            self.everythingElseFolderLanded(folder)
        }
    }

    private func cancelEverythingElseFolderSizing() {
        everythingElseFolderGeneration += 1
        everythingElseFolderTask?.cancel()
        everythingElseFolderTask = nil
        everythingElseFolderSizing = nil
    }

    /// The app that owns a folder, when its name is a bundle id (a container) and
    /// the app is installed. Asked on right-click only: it is a LaunchServices call.
    func everythingElseOwningApp(for folder: EverythingElseFolder) -> (bundleID: String, name: String)? {
        let name = folder.name
        guard name.contains("."), !name.hasPrefix("."),
              let appName = appDisplayName(forBundleID: name)
        else { return nil }
        return (name, appName)
    }

    func everythingElseFolderHint(for folder: EverythingElseFolder) -> EverythingElseFolderHint? {
        EverythingElseFolderHint.hint(
            for: folder.path,
            group: folder.group,
            home: FileManager.default.homeDirectoryForCurrentUser,
            steamGames: everythingElseMeasurement?.steamGames ?? [:],
            // The uninstaller is locked without Full Disk Access, so the link
            // would land on the lock page.
            commandLineTools: hasFullDiskAccess ? (everythingElseMeasurement?.commandLineTools ?? [:]) : [:]
        )
    }

    /// Opens an app, a link the app handles, or another tab. Nothing here
    /// touches a file.
    func performEverythingElseHint(_ action: EverythingElseFolderHint.Action) {
        switch action {
        case .openApp(let bundleID, _):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .openURL(let url, _):
            NSWorkspace.shared.open(url)
        case .showInLargeFiles:
            selectedTab = .largeFiles
        case .showInDevTools:
            selectedTab = .devTools
        case .showInCommandLineTools:
            uninstallSection = .commandLineTools
            selectedTab = .uninstaller
            requestScanIfNeeded(.commandLineTools)
        }
    }
}

extension EverythingElseMeasurement {
    /// The measurement with every folder the user excluded taken out. An excluded
    /// root loses its whole figure; an excluded folder inside a root leaves the
    /// root's other folders alone.
    func droppingFolders(where isHidden: (String) -> Bool) -> EverythingElseMeasurement {
        var copy = self
        copy.measuredRoots = measuredRoots.compactMap { measured in
            if isHidden(measured.root.path) { return nil }
            let kept = measured.folders.filter { !isHidden($0.path) }
            guard kept.count != measured.folders.count else { return measured }
            return EverythingElseMeasuredRoot(root: measured.root, folders: kept, looseFileBytes: measured.looseFileBytes)
        }
        return copy
    }
}
