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
        excludeFoldersFromScans([folder.url])
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
            commandLineTools: everythingElseMeasurement?.commandLineTools ?? [:]
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
